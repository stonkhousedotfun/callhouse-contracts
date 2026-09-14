// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy} from "../../src/Policy.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockSeaport} from "../../src/mocks/MockSeaport.sol";
import {MockFeed} from "../../src/mocks/MockFeed.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {OrderComponents, OfferItem, ConsiderationItem, ItemType, OrderType} from "../../src/interfaces/ISeaport.sol";

/// @notice Drives the vault through random but LEGAL sequences: deposits, mints, instant
///         redemptions, share transfers, the redeem queue, USDG claims, and full roll cycles
///         (arm, list, partial fills that WRITE, a third party writing into and exercising the
///         same bucket, partial assignment, lock, close) across many weeks.
/// @dev Every action is guarded by the same preconditions the vault enforces, so a run is a
///      sequence of calls a real user or keeper could actually make. Actions that cannot
///      legally run right now count as SKIPPED rather than reverting, and everything that does
///      run is wrapped in try/catch so an unexpected revert is counted instead of silently
///      swallowed. {VaultInvariantTest.afterInvariant} then refuses to accept a run that was
///      mostly no-ops, which is the only defence against an invariant suite that passes because
///      it never did anything.
///
///      TIME IS PART OF THE FUZZ. The weekly cycle is a state machine gated on timestamps, so
///      the handler warps: freely in `warpAhead`, and deliberately into the exercise window or
///      past expiry in the actions that need it. Without that, a run never gets past `Listed`
///      and the settlement half of the contract is never tested.
contract VaultHandler is Test {
    uint256 internal constant LOT = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev Addresses that can EVER hold shares, and therefore ever accrue USDG: the three
    ///      actors plus the queue escrow at the vault. The buyer is deliberately not counted —
    ///      nothing in the handler can give it shares, and
    ///      {VaultInvariantTest.invariant_shareAccounting} pins that so this bound stays true.
    uint256 internal constant HOLDER_SLOTS = 4;

    Vault internal immutable vault;
    MockStockToken internal immutable nvda;
    MockERC20 internal immutable usdg;
    MockClear internal immutable clear;
    MockSeaport internal immutable seaport;
    MockFeed internal immutable feed;
    address internal immutable buyer;
    /// @dev A third-party writer and exerciser on the SAME option id (AUDIT-FINDINGS F-01). It writes
    ///      into the vault's bucket before any exercise and exercises whenever it likes; under write on
    ///      fill it can only ever assign the vault on contracts the vault sold.
    address internal immutable mallory;
    address internal immutable admin;
    address internal immutable guardian;

    address[3] internal actors;

    /*//////////////////////////////////////////////////////////////
                        GHOST STATE FOR INVARIANT 1
    //////////////////////////////////////////////////////////////*/

    /// @notice Asset base units users have put in.
    uint256 public totalDeposited;
    /// @notice Asset base units users have taken out, instant redemptions and the queue alike.
    uint256 public totalWithdrawn;
    /// @notice Asset base units the vault's claim gave up to exercisers, MEASURED as the drop in
    ///         `lockedAssets()` across each exercise (the vault's pro-rata share of a bucket, not the
    ///         exerciser's size: other writers share the bucket). Gone for good.
    uint256 public totalAssignedOut;
    /// @notice Asset base units the issuer has burnt out of the vault with `adminBurn`. Gone for good.
    uint256 public totalBurned;
    /// @notice Contracts the vault has SOLD over the whole run, every cycle summed: the fill sizes of
    ///         every successful `fill`. Under write on fill this is also everything it ever wrote.
    /// @dev The other side of {totalAssignedOut}: the vault can only be assigned on collateral it
    ///      put behind a contract it sold, so the lifetime assignment is bounded by the lifetime
    ///      sale ({VaultInvariantTest.invariant_assignedNeverExceedsSold}). Stated in contracts;
    ///      the bound multiplies by the lot.
    uint256 public totalSold;
    /// @dev Every option id the vault has ever armed, in order, so the option-token supply of each
    ///      can be tied back to its holders and its unexercised buckets after the cycle is over as
    ///      well as during it ({VaultInvariantTest.invariant_longSupplyIsUnexercisedCollateral}).
    uint256[] internal armedIds;
    /// @notice The part of every burn that landed on `reservedAssets` rather than on live shares:
    ///         `max(reserved - balanceAfter, 0) - max(reserved - balanceBefore, 0)`, summed over burns.
    /// @dev A shortfall of the balance below the reserve can ORIGINATE only in a burn. Payouts
    ///      (with their haircut), settlements and returning collateral can only shrink it, so the
    ///      live shortfall is bounded by this ghost at every step; see
    ///      {VaultInvariantTest.invariant_reservesAreReal}.
    uint256 public burnReserveShortfall;

    /*//////////////////////////////////////////////////////////////
                  GHOST STATE FOR THE PROTOCOL FEE BOUND
    //////////////////////////////////////////////////////////////*/

    /// @notice Every fee-bearing USDG base unit that ever reached the vault: the premium of each
    ///         successful fill, MEASURED as the vault's USDG balance delta across the `fulfil` call
    ///         rather than recomputed from the order.
    /// @dev The protocol fee may only ever be charged on this. Strike proceeds are deliberately
    ///      NOT counted: they arrive inside `rollClose` when the Valorem claim is redeemed, and
    ///      they are the assigned depositors' own principal. The handler never donates USDG to
    ///      the vault (a donation would be fee-bearing exactly like premium, and would have to be
    ///      added here as a measured delta the day an action that donates exists).
    ///      {VaultInvariantTest.invariant_feeNeverTouchesStrikeProceeds} bounds the fee by it.
    uint256 public ghostPremiumToVault;

    /*//////////////////////////////////////////////////////////////
                              CALL STATS
    //////////////////////////////////////////////////////////////*/

    uint256 public attempted;
    uint256 public skipped;
    uint256 public succeeded;
    uint256 public revertedCalls;

    /// @dev Kept so a broken guard reports itself instead of hiding inside a revert count.
    string public firstRevertAction;
    bytes public firstRevertData;

    /// @notice Claims the vault could not fund in full, and the worst shortfall seen.
    /// @dev A DIAGNOSTIC, NOT A TOLERATED FAILURE. {Distributor}'s index credits a floor once
    ///      PER DISTRIBUTION, while a holder's pending accrual floors ONCE over the combined
    ///      index delta since they last settled, and floor(b*(d1+d2)) >= floor(b*d1) +
    ///      floor(b*d2). The sum of what accounts can see therefore sits up to a base unit per
    ///      account per distribution above the sum that was ever credited. Every USDG payout is
    ///      clamped to {Vault._usdgAvailableForHolders}, so that surplus is simply left unpaid
    ///      instead of reverting or being taken out of the redeem queue's money. {claimUsdg}
    ///      records how large the unpayable remainder got and
    ///      {VaultInvariantTest.afterInvariant} fails the run the moment it exceeds
    ///      {maxIndexRoundingDrift}: anything bigger than the rounding bound is a real leak.
    uint256 public unfundedClaims;
    uint256 public maxClaimShortfall;

    uint256 public cDeposit;
    uint256 public cMint;
    uint256 public cRedeem;
    uint256 public cWithdraw;
    uint256 public cTransfer;
    uint256 public cQueue;
    uint256 public cComplete;
    uint256 public cClaim;
    uint256 public cOpen;
    uint256 public cList;
    uint256 public cCancel;
    uint256 public cFill;
    uint256 public cExercise;
    uint256 public cLock;
    uint256 public cClose;
    uint256 public cSettleQueue;
    /// @notice Third-party writes into the vault's option id, and exercises by that writer.
    uint256 public cThirdPartyWrite;
    uint256 public cThirdPartyExercise;
    uint256 public cBurn;
    /// @notice Burns that took the balance below `reservedAssets`.
    uint256 public cBurnShortfalls;
    /// @dev Per-run budget for each burn shape; see {adminBurn}.
    uint256 internal ordinaryBurns;
    uint256 internal aimedBurns;
    /// @notice Completed redemptions that were paid less than booked (the reserve haircut).
    uint256 public cHaircuts;
    /// @notice Completed redemptions whose USDG leg could not move and stayed booked (F-03).
    uint256 public cDeferredUsdgLegs;
    /// @notice Closes that could not redeem the claim and stranded it (F-02).
    uint256 public cStrands;
    /// @notice Stranded claims redeemed by `retryStrandedClaim`, and retries refused `StillStranded`.
    uint256 public cRetries;
    uint256 public cRetriesRefused;
    /// @notice Issuer actions: USDG pause flips, USDG freeze flips (vault or Clear), NVDA blocklist flips.
    uint256 public cUsdgPauseToggles;
    uint256 public cUsdgFreezeToggles;
    uint256 public cNvdaBlockToggles;

    /// @notice Cycles that ended with at least one contract assigned.
    uint256 public cAssignedCycles;
    /// @notice Fills that opened the cycle's claim, and fills that topped an existing claim up.
    uint256 public cFirstFills;
    uint256 public cTopUpFills;

    /*//////////////////////////////////////////////////////////////
                             CYCLE FIXTURE
    //////////////////////////////////////////////////////////////*/

    uint96[] internal strikes;
    uint256[] internal cycleOptionIds;
    uint40 internal cycleExercise;
    uint40 internal cycleExpiry;
    uint256 internal cycleSeq;

    /// @dev The listing the handler last authorised, kept so it can be rebuilt byte-for-byte
    ///      for a fill or a cancel. Rebuilding beats storing the nested struct and keeps the
    ///      Seaport order hash identical to the one the vault recorded.
    struct Live {
        uint256 optionId;
        uint256 amount;
        uint256 unitPrice;
        uint40 endTime;
        uint256 counter;
        uint256 salt;
        bool active;
    }

    Live internal live;

    /// @dev A cancelled order hash is dead on Seaport for ever, so every listing gets its own
    ///      salt. Reusing one would republish a hash Seaport has already buried.
    uint256 internal listingNonce;

    constructor(
        Vault vault_,
        MockStockToken nvda_,
        MockERC20 usdg_,
        MockClear clear_,
        MockSeaport seaport_,
        MockFeed feed_,
        address buyer_,
        address mallory_,
        address admin_,
        address guardian_,
        address[3] memory actors_
    ) {
        vault = vault_;
        nvda = nvda_;
        usdg = usdg_;
        clear = clear_;
        seaport = seaport_;
        feed = feed_;
        buyer = buyer_;
        mallory = mallory_;
        admin = admin_;
        guardian = guardian_;
        actors = actors_;

        strikes.push(226_000_000);
        strikes.push(231_000_000);
        strikes.push(236_000_000);
        strikes.push(241_000_000);
        strikes.push(246_000_000);

        // Standing approvals for the buyer so a fill or an exercise is never blocked on one, and for
        // the third-party writer so a write or an exercise is not either.
        vm.startPrank(buyer_);
        usdg_.approve(address(seaport_), type(uint256).max);
        usdg_.approve(address(clear_), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(mallory_);
        nvda_.approve(address(clear_), type(uint256).max);
        usdg_.approve(address(clear_), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        attempted++;
        if (!_canDeposit() || _vaultBlockedOnNvda()) {
            _skip();
            return;
        }

        address who = _actor(actorSeed);
        uint256 room = vault.maxDeposit(who);
        if (room < 1e15) {
            _skip();
            return;
        }

        uint256 amount = bound(amountSeed, 1e15, room > 6e18 ? 6e18 : room);
        uint256 quoted = vault.previewDeposit(amount);
        if (quoted == 0) {
            _skip();
            return;
        }
        _fundAsset(who, amount);

        uint256 before = nvda.balanceOf(address(vault));
        vm.startPrank(who);
        nvda.approve(address(vault), amount);
        try vault.deposit(amount, who) returns (uint256 shares) {
            // THE GHOST IS THE AMOUNT ASKED FOR, never the balance delta it produced. Deriving
            // the ghost from `nvda.balanceOf(vault)` would make {invariant_assetConservation}
            // compare the vault's balance with itself, which passes whatever the vault does.
            totalDeposited += amount;
            assertEq(nvda.balanceOf(address(vault)) - before, amount, "deposit moved the wrong amount of asset");
            assertEq(shares, quoted, "previewDeposit quoted shares deposit did not mint");
            succeeded++;
            cDeposit++;
        } catch (bytes memory err) {
            _reverted("deposit", err);
        }
        vm.stopPrank();
    }

    function mintShares(uint256 actorSeed, uint256 sharesSeed) external {
        attempted++;
        if (!_canDeposit() || _vaultBlockedOnNvda()) {
            _skip();
            return;
        }

        address who = _actor(actorSeed);
        uint256 shares = bound(sharesSeed, 1e15, 6e18);
        uint256 cost = vault.previewMint(shares);
        if (cost == 0 || cost > vault.maxDeposit(who)) {
            _skip();
            return;
        }
        _fundAsset(who, cost);

        uint256 before = nvda.balanceOf(address(vault));
        vm.startPrank(who);
        nvda.approve(address(vault), cost);
        try vault.mint(shares, who) returns (uint256 assetsPaid) {
            totalDeposited += assetsPaid;
            assertEq(assetsPaid, cost, "previewMint quoted a price mint did not charge");
            assertEq(nvda.balanceOf(address(vault)) - before, assetsPaid, "mint moved the wrong amount of asset");
            assertGe(vault.balanceOf(who), shares, "mint did not deliver the shares");
            succeeded++;
            cMint++;
        } catch (bytes memory err) {
            _reverted("mint", err);
        }
        vm.stopPrank();
    }

    function instantRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        attempted++;
        // A Stock Token blocklist of the vault stops the payout and nothing else; that revert is honest.
        if (!vault.canRedeemInstantly() || _vaultBlockedOnNvda()) {
            _skip();
            return;
        }

        address who = _actor(actorSeed);
        uint256 free = _freeShares(who);
        if (free == 0) {
            _skip();
            return;
        }

        uint256 shares = bound(sharesSeed, 1, free);
        // previewRedeem is the quote the caller was given; it must be exactly what they get.
        uint256 quoted = vault.previewRedeem(shares);
        if (quoted == 0) {
            _skip();
            return;
        }

        uint256 before = nvda.balanceOf(address(vault));
        vm.prank(who);
        try vault.redeem(shares, who, who) returns (uint256 assets) {
            totalWithdrawn += assets;
            assertEq(assets, quoted, "previewRedeem quoted assets redeem did not pay");
            assertEq(before - nvda.balanceOf(address(vault)), assets, "redeem moved the wrong amount of asset");
            succeeded++;
            cRedeem++;
        } catch (bytes memory err) {
            _reverted("redeem", err);
        }
    }

    function instantWithdraw(uint256 actorSeed, uint256 assetsSeed) external {
        attempted++;
        if (!vault.canRedeemInstantly() || _vaultBlockedOnNvda()) {
            _skip();
            return;
        }

        address who = _actor(actorSeed);
        uint256 free = _freeShares(who);
        if (free == 0) {
            _skip();
            return;
        }

        uint256 ceiling = vault.convertToAssets(free);
        if (ceiling == 0) {
            _skip();
            return;
        }
        uint256 assets = bound(assetsSeed, 1, ceiling);
        // withdraw() rounds the share cost UP, so the last wei of the conversion can ask for
        // one share more than the caller has free. Step down rather than fire a doomed call.
        if (vault.previewWithdraw(assets) > free) {
            if (assets == 1) {
                _skip();
                return;
            }
            assets -= 1;
            if (vault.previewWithdraw(assets) > free) {
                _skip();
                return;
            }
        }

        uint256 quotedShares = vault.previewWithdraw(assets);
        uint256 before = nvda.balanceOf(address(vault));
        vm.prank(who);
        try vault.withdraw(assets, who, who) returns (uint256 sharesBurned) {
            // The ghost is the asset figure the CALLER named, so the conservation invariant is
            // checking the vault against the request rather than against its own bookkeeping.
            totalWithdrawn += assets;
            assertEq(sharesBurned, quotedShares, "previewWithdraw quoted a share cost withdraw did not charge");
            assertEq(
                before - nvda.balanceOf(address(vault)), assets, "withdraw paid an amount other than the one asked for"
            );
            succeeded++;
            cWithdraw++;
        } catch (bytes memory err) {
            _reverted("withdraw", err);
        }
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 sharesSeed) external {
        attempted++;
        uint256 fi = fromSeed % actors.length;
        uint256 ti = toSeed % actors.length;
        if (ti == fi) ti = (ti + 1) % actors.length; // index arithmetic, never seed arithmetic
        address from = actors[fi];
        address to = actors[ti];

        uint256 free = _freeShares(from);
        if (free == 0) {
            _skip();
            return;
        }

        uint256 shares = bound(sharesSeed, 1, free);
        vm.prank(from);
        try vault.transfer(to, shares) {
            succeeded++;
            cTransfer++;
        } catch (bytes memory err) {
            _reverted("transfer", err);
        }
    }

    function queueRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        attempted++;
        address who = _actor(actorSeed);
        uint256 queueable = _freeShares(who);
        if (queueable == 0) {
            _skip();
            return;
        }

        uint256 shares = bound(sharesSeed, 1, queueable);

        // Queueing MOVES NO MONEY. An older settled entry is folded into `owedAssets` /
        // `owedQueueUsdg` rather than paid out, precisely so a frozen Stock Token cannot stop a
        // holder from queueing. Both halves are worth pinning: nothing may leave the vault here,
        // and the entry that was folded in must still be worth exactly what it was worth before
        // — an off-by-one in `_settleEpochEntry` would quietly evaporate a redemption.
        (uint256 dueAssets, uint256 dueUsdg) = vault.previewCompleteRedeem(who);
        uint256 epochNow = vault.epochId();
        uint256 before = nvda.balanceOf(address(vault));
        uint256 usdgBefore = usdg.balanceOf(address(vault));
        vm.prank(who);
        try vault.queueRedeem(shares) returns (uint256 queuedEpoch) {
            assertEq(nvda.balanceOf(address(vault)), before, "queueRedeem moved asset out of the vault");
            assertEq(usdg.balanceOf(address(vault)), usdgBefore, "queueRedeem moved USDG out of the vault");
            assertEq(queuedEpoch, epochNow, "queued into an epoch other than the live one");
            (uint256 dueAfterAssets, uint256 dueAfterUsdg) = vault.previewCompleteRedeem(who);
            assertEq(dueAfterAssets, dueAssets, "queueRedeem changed what an uncollected epoch entry is worth");
            assertEq(dueAfterUsdg, dueUsdg, "queueRedeem changed the USDG owed on an uncollected entry");
            succeeded++;
            cQueue++;
        } catch (bytes memory err) {
            _reverted("queueRedeem", err);
        }
    }

    function completeRedeem(uint256 actorSeed) external {
        attempted++;
        address who = _actor(actorSeed);
        // Collectable either as a settled queue entry or as a balance already folded into
        // `owed*` by an earlier `queueRedeem`. Checking only the first would stop exercising the
        // staging layer the moment a holder re-queued.
        uint256 q = vault.queuedSharesOf(who);
        uint256 e = vault.queuedEpochOf(who);
        bool settledEntry = q != 0 && e < vault.epochId();
        // A share of a stranded claim is collectable only once that claim has been redeemed; until
        // then it is owed but nothing can be paid for it, and the vault says `StillStranded`.
        bool strandReady = vault.owedStrandWad(who) != 0 && vault.owedStrandGen(who) <= vault.lastResolvedGen();
        bool staged = vault.owedAssets(who) != 0 || vault.owedQueueUsdg(who) != 0 || strandReady;
        // A live (unsettled) entry does NOT block collection of a staged balance; see
        // {VaultInvariantTest.test_reQueuingDoesNotLockAlreadySettledMoney}.
        if (!settledEntry && !staged) {
            _skip();
            return;
        }
        // Only a USDG leg left and USDG cannot leave the vault: the vault reverts `UsdgLegBlocked`
        // rather than pretend nothing was queued, so do not fire the doomed call.
        bool usdgBlocked = _usdgOutBlocked();
        if (!settledEntry && !strandReady && vault.owedAssets(who) == 0 && usdgBlocked) {
            _skip();
            return;
        }

        (uint256 dueAssets, uint256 dueUsdg) = vault.previewCompleteRedeem(who);
        // The Stock Token leg is paid with `safeTransfer`, and a blocklist of the vault reverts it
        // honestly: there is nothing to pay principal with. Only fired when a leg would move.
        if (dueAssets != 0 && _vaultBlockedOnNvda()) {
            _skip();
            return;
        }
        // What is BOOKED to the account, before any haircut: the staged balance plus its share of
        // the settled epoch, plus whatever share of a redeemed stranded claim is folded in by this
        // call (measured as the drop in the generations' `assetsLeft`). The preview quotes this
        // after the haircut, so the two differ exactly when the balance sits below the reserve.
        uint256 booked = vault.owedAssets(who);
        if (settledEntry) {
            (uint256 sharesR, uint256 assetsR,) = vault.epochs(e);
            booked += (assetsR * q) / sharesR;
        }
        uint256 strandLeftBefore = strandAssetsLeft();
        uint256 reservedBefore = vault.reservedAssets();
        uint256 before = nvda.balanceOf(address(vault));
        uint256 usdgBefore = usdg.balanceOf(address(vault));
        vm.prank(who);
        try vault.completeRedeem(who) returns (uint256 assets, uint256 usdgOut) {
            totalWithdrawn += assets;
            booked += strandLeftBefore - strandAssetsLeft();
            assertEq(assets, dueAssets, "previewCompleteRedeem quoted assets completeRedeem did not pay");
            // The reserve is released by what was BOOKED, whatever was paid: a haircut is a loss
            // taken by the claimant, never a base unit left promised in the reserve.
            assertEq(
                reservedBefore - vault.reservedAssets(),
                booked,
                "reservedAssets released something other than the booked amount"
            );
            if (assets < booked) {
                cHaircuts++;
                assertLt(before, reservedBefore, "a haircut was applied while the balance backed the reserve");
            } else {
                assertEq(assets, booked, "paid more than was booked");
            }
            // The USDG leg is best-effort (F-03): while USDG cannot leave the vault it stays booked
            // to the owner, to the base unit, and nothing else about the call changes.
            if (usdgBlocked) {
                assertEq(usdgOut, 0, "USDG left the vault while it was paused or the vault frozen");
                assertEq(vault.owedQueueUsdg(who), dueUsdg, "a deferred USDG leg was not kept booked in full");
                if (dueUsdg != 0) cDeferredUsdgLegs++;
            } else {
                assertEq(usdgOut, dueUsdg, "previewCompleteRedeem quoted USDG completeRedeem did not pay");
                assertEq(vault.owedQueueUsdg(who), 0, "staged USDG survived a completed redemption");
            }
            assertEq(before - nvda.balanceOf(address(vault)), assets, "completeRedeem moved the wrong amount of asset");
            assertEq(usdgBefore - usdg.balanceOf(address(vault)), usdgOut, "completeRedeem moved the wrong USDG");
            // Nothing collectable may survive: no staged balance, no SETTLED queue entry, and no
            // share of a REDEEMED stranded claim. A live entry for an epoch that has not closed
            // yet is allowed to remain — that is the whole point of
            // {VaultInvariantTest.test_reQueuingDoesNotLockAlreadySettledMoney} — and so is a
            // share of a claim that is still stranded.
            assertEq(vault.owedAssets(who), 0, "staged assets survived a completed redemption");
            if (vault.owedStrandWad(who) != 0) {
                assertGt(
                    vault.owedStrandGen(who),
                    vault.lastResolvedGen(),
                    "a share of a redeemed stranded claim survived a completed redemption"
                );
            }
            if (vault.queuedSharesOf(who) != 0) {
                assertGe(
                    vault.queuedEpochOf(who), vault.epochId(), "a settled queue entry survived a completed redemption"
                );
            }
            succeeded++;
            cComplete++;
        } catch (bytes memory err) {
            _reverted("completeRedeem", err);
        }
    }

    /// @dev THE GUARD HAS TO MIRROR THE VAULT'S CLAMP, not just `claimableUsdg`. A claim pays
    ///      `min(accrual, _usdgAvailableForHolders())`, i.e. the balance less the settled queue's
    ///      reserve and the accrued protocol fee, and reverts {NothingToClaim} when that minimum
    ///      is zero. That is not a wrong revert: it is the index's floor drift (see
    ///      {unfundedClaims}) asking for a base unit the vault has already promised to a settled
    ///      redeemer, and refusing it is exactly right. Guarding on `claimableUsdg` alone fired
    ///      a doomed call in roughly one run in fifty and reported it as a broken guard.
    function claimUsdg(uint256 actorSeed) external {
        attempted++;
        address who = _actor(actorSeed);
        uint256 claimable = vault.claimableUsdg(who);
        // `claimUsdg` is a hard `safeTransfer`: a paused USDG or a frozen vault reverts it, honestly.
        if (claimable == 0 || _usdgOutBlocked()) {
            _skip();
            return;
        }

        uint256 backing = usdgPayableToHolders();
        if (claimable > backing) {
            // Record the gap whether or not anything is payable; {afterInvariant} refuses the
            // run if it ever grows past what the index can over-promise by rounding.
            unfundedClaims++;
            if (claimable - backing > maxClaimShortfall) maxClaimShortfall = claimable - backing;
        }
        if (backing == 0) {
            _skip();
            return;
        }

        uint256 expected = claimable < backing ? claimable : backing;
        vm.prank(who);
        try vault.claimUsdg() returns (uint256 paid) {
            assertEq(paid, expected, "claimUsdg paid something other than the clamped accrual");
            succeeded++;
            cClaim++;
        } catch (bytes memory err) {
            _reverted("claimUsdg", err);
        }
    }

    /// @notice USDG the vault may hand to share holders: everything it holds that is not already
    ///         promised to the settled redeem queue or accrued as protocol fee.
    /// @dev Mirrors {Vault._usdgAvailableForHolders}, which is internal. Saturating for the same
    ///      reason the vault's version is.
    function usdgPayableToHolders() public view returns (uint256) {
        uint256 bal = usdg.balanceOf(address(vault));
        uint256 spokenFor = vault.usdgReservedForQueue() + vault.pendingFeeUsdg();
        return bal > spokenFor ? bal - spokenFor : 0;
    }

    /// @notice Asset base units of redeemed stranded claims still sitting in `reservedAssets` for
    ///         owners who have not collected their share yet, summed over every generation.
    function strandAssetsLeft() public view returns (uint256 left) {
        for (uint256 g = 1; g <= vault.strandGen(); g++) {
            (,,, uint256 assetsLeft,) = vault.strands(g);
            left += assetsLeft;
        }
    }

    /// @notice The USDG counterpart of {strandAssetsLeft}, inside `usdgReservedForQueue`.
    /// @notice Every option id the vault has armed this run, oldest first.
    function armedOptionIds() external view returns (uint256[] memory) {
        return armedIds;
    }

    function strandUsdgLeft() public view returns (uint256 left) {
        for (uint256 g = 1; g <= vault.strandGen(); g++) {
            (,,,, uint256 usdgLeft) = vault.strands(g);
            left += usdgLeft;
        }
    }

    /*//////////////////////////////////////////////////////////////
                              THE WEEKLY ROLL
    //////////////////////////////////////////////////////////////*/

    /// @dev ARM a cycle on a freshly created in-band option type. Writes nothing (decision D1): the
    ///      collateral moves only inside `fill`. No idle collateral is needed to arm, and none is
    ///      required here, so the fill guard is the one place capacity is judged.
    function rollOpen(uint256 spotSeed, uint256 rungSeed) external {
        attempted++;
        // Idle, not halted, not stranded (`rollOpen` refuses `StillStranded`). Arming moves no token,
        // so a Stock Token blocklist of the vault does not stop it: the fills are what it stops.
        if (uint8(vault.phase()) != 0 || vault.writesHalted() || vault.isStranded()) {
            _skip();
            return;
        }

        // A fresh cycle every week, as the keeper does it with `newOptionType`. New timestamps mean
        // new Valorem option ids, which keeps each cycle's claim isolated from the last one's.
        _installFreshCycle();

        uint256 spot = _refreshSpot(spotSeed);
        uint256 optionId = _pickRung(spot, rungSeed);
        if (optionId == 0) {
            _skip();
            return;
        }

        uint256 number = vault.cycleNumber();
        try vault.rollOpen(optionId) {
            assertEq(vault.contractsWritten(), 0, "arming wrote something");
            assertEq(vault.claimKey(), 0, "arming opened a claim");
            assertEq(vault.optionId(), optionId, "armed the wrong type");
            assertEq(vault.cycleNumber(), number + 1, "the vault's own counter did not advance");
            armedIds.push(optionId);
            succeeded++;
            cOpen++;
        } catch (bytes memory err) {
            _reverted("rollOpen", err);
        }
    }

    function approveListing(uint256 amountSeed, uint256 priceSeed, uint256 spotSeed) external {
        attempted++;
        if (uint8(vault.phase()) != 1) {
            _skip();
            return;
        }
        // A halt blocks a new listing as well as a new write, so respect it here too.
        if (vault.writesHalted()) {
            _skip();
            return;
        }
        if (vault.listingHash() != bytes32(0)) {
            _skip();
            return;
        }

        uint40 endTime = vault.cycleExerciseTs();
        if (block.timestamp >= endTime) {
            _skip();
            return;
        }

        uint256 optionId = vault.optionId();
        // CAPACITY, NOT INVENTORY: what the size gate would still admit this cycle.
        uint256 available = _capacityLeft();
        if (available == 0) {
            _skip();
            return;
        }

        // approveListing re-checks the band's lower bound at live spot, so keep spot at or below
        // the highest price whose band floor still admits the armed strike.
        (uint16 minOtmBps,, uint16 minPremiumBps,,,) = vault.policy();
        uint256 maxSpot = (vault.cycleStrikeUsdg() * BPS) / (BPS + minOtmBps);
        if (maxSpot > 232_000_000) maxSpot = 232_000_000;
        uint256 spot = bound(spotSeed, maxSpot < 215_000_000 ? maxSpot : 215_000_000, maxSpot);
        feed.setAnswer(int256(spot * 100));
        uint256 amount = bound(amountSeed, 1, available);
        // Clear the 0.40%-of-spot floor per contract, and stay under the strike.
        uint256 floorUnit = (spot * minPremiumBps) / BPS + 1;
        uint256 unitPrice = bound(priceSeed, floorUnit, floorUnit * 6);
        // Three authorisations a cycle, cancelled or not.
        if (vault.listingsThisCycle() >= 3) {
            _skip();
            return;
        }

        listingNonce += 1;
        OrderComponents memory c = _buildOrder(optionId, amount, unitPrice, endTime, listingNonce);
        try vault.approveListing(c) {
            live = Live({
                optionId: optionId,
                amount: amount,
                unitPrice: unitPrice,
                endTime: endTime,
                counter: c.counter,
                salt: listingNonce,
                active: true
            });
            succeeded++;
            cList++;
        } catch (bytes memory err) {
            _reverted("approveListing", err);
        }
    }

    /// @dev Anyone may settle a queue made while flat. It must pay the instant-redeem price of
    ///      the escrow (virtual share included) and move no tokens.
    function settleQueue(uint256 whoSeed) external {
        attempted++;
        uint256 q = vault.queuedShares();
        if (uint8(vault.phase()) != 0 || q == 0) {
            _skip();
            return;
        }

        uint256 e = vault.epochId();
        // Priced like instant redeem, virtual share included (`_settleQueue`).
        uint256 expected = (q * (vault.idleAssets() + 1)) / (vault.totalSupply() + 1);
        // While a claim is stranded the epoch also takes q/supply of what live shares still own of it.
        bool stranded = vault.isStranded();
        uint256 expectedWad = stranded ? (vault.strandedRemainingWad() * q) / vault.totalSupply() : 0;
        uint256 remainingBefore = vault.strandedRemainingWad();
        uint256 before = nvda.balanceOf(address(vault));
        vm.prank(address(uint160(uint256(keccak256(abi.encode(whoSeed, "settler"))))));
        try vault.settleQueue() {
            (uint256 sharesR, uint256 assetsR,) = vault.epochs(e);
            assertEq(sharesR, q, "the whole queue settled");
            assertEq(assetsR, expected, "settled at something other than the flat pro-rata slice");
            assertEq(vault.queuedShares(), 0, "queue not emptied");
            assertEq(nvda.balanceOf(address(vault)), before, "settleQueue moved asset");
            assertEq(vault.epochStrandWad(e), expectedWad, "the epoch's share of the stranded claim is not q/supply");
            assertEq(
                vault.strandedRemainingWad(),
                remainingBefore - expectedWad,
                "live shares' share of the claim not reduced"
            );
            if (expectedWad != 0) {
                assertEq(vault.epochStrandGen(e), vault.strandGen(), "epoch tagged with the wrong gen");
            }
            succeeded++;
            cSettleQueue++;
        } catch (bytes memory err) {
            _reverted("settleQueue", err);
        }
    }

    /// @dev THE F-01 ADVERSARY. A third party writes into the vault's option id. Before any exercise
    ///      every write lands in the vault's bucket (upstream `_addOrUpdateBucket`), so later
    ///      exercises are assigned pro rata across the vault and this writer. Under write on fill the
    ///      vault's share of that assignment can never exceed what it sold.
    function thirdPartyWrite(uint256 sizeSeed) external {
        attempted++;
        uint8 p = uint8(vault.phase());
        uint256 optionId = vault.optionId();
        if ((p != 1 && p != 2) || optionId == 0 || block.timestamp >= vault.cycleExpiryTs()) {
            _skip();
            return;
        }
        uint112 n = uint112(bound(sizeSeed, 1, 40));
        _fundAsset(mallory, uint256(n) * LOT);

        uint256 locked = vault.lockedAssets();
        uint256 nav = vault.totalAssets();
        vm.prank(mallory);
        try clear.write(optionId, n) {
            assertEq(vault.lockedAssets(), locked, "a stranger's write moved the vault's collateral");
            assertEq(vault.totalAssets(), nav, "a stranger's write moved NAV");
            assertEq(clear.balanceOf(address(vault), optionId), 0, "a stranger's write put inventory in the vault");
            succeeded++;
            cThirdPartyWrite++;
        } catch (bytes memory err) {
            _reverted("thirdPartyWrite", err);
        }
    }

    /// @dev The adversary exercises what it wrote (or bought). Warps into the window like {exercise}.
    ///      Whatever the bucket maths does, the vault's claim gives up at most what it sold.
    function thirdPartyExercise(uint256 amountSeed, uint256 whenSeed) external {
        attempted++;
        uint8 p = uint8(vault.phase());
        uint256 optionId = vault.optionId();
        if ((p != 1 && p != 2) || optionId == 0) {
            _skip();
            return;
        }
        // The exerciser pays the strike into Clear: a paused USDG or a frozen Clear refuses it.
        if (usdg.paused() || usdg.isFrozen(address(clear))) {
            _skip();
            return;
        }
        uint40 exerciseTs = vault.cycleExerciseTs();
        uint40 expiryTs = vault.cycleExpiryTs();
        if (block.timestamp >= expiryTs) {
            _skip();
            return;
        }
        uint256 held = clear.balanceOf(mallory, optionId);
        if (held == 0) {
            _skip();
            return;
        }
        if (block.timestamp < exerciseTs) vm.warp(bound(whenSeed, exerciseTs, expiryTs - 1));

        uint112 n = uint112(bound(amountSeed, 1, held));
        usdg.mint(mallory, uint256(n) * vault.cycleStrikeUsdg());

        uint256 lockedBefore = vault.lockedAssets();
        vm.prank(mallory);
        try clear.exercise(optionId, n) {
            uint256 lockedAfter = vault.lockedAssets();
            totalAssignedOut += lockedBefore - lockedAfter;
            _assertVaultAssignedOnlyWhatItSold();
            succeeded++;
            cThirdPartyExercise++;
        } catch (bytes memory err) {
            _reverted("thirdPartyExercise", err);
        }
    }

    /// @dev The F-01 bound, checked after every exercise: the vault's claim is assigned on at most
    ///      `contractsWritten`, which under write on fill is exactly what it sold.
    function _assertVaultAssignedOnlyWhatItSold() internal view {
        uint256 key = vault.claimKey();
        if (key == 0) return;
        IValoremClear.Claim memory c = clear.claim(key);
        uint256 written = uint256(vault.contractsWritten()) * 1e18;
        assertEq(c.amountWritten, written, "Valorem's amount written disagrees with contractsWritten");
        assertLe(c.amountExercised, written, "the vault was assigned on more than it wrote (and sold)");
        // Valorem floors the underlying and the exercised WAD per claim index separately, so the two
        // can disagree by a wei of dust (which stays in Clear for ever, Zellic 2022 §4.1). One index
        // under "no writes after the first exercise", so one wei.
        assertApproxEqAbs(vault.lockedAssets(), written - c.amountExercised, 1, "locked != written - exercised");
    }

    /// @dev A keeper repricing mid-week is real, but cancelling every listing on sight would
    ///      starve the fill and assignment paths, so it only fires on one seed in four.
    function cancelListing(uint256 seed) external {
        attempted++;
        if (seed % 4 != 0) {
            _skip();
            return;
        }
        if (!live.active || vault.listingHash() == bytes32(0)) {
            _skip();
            return;
        }

        OrderComponents memory c = _rebuildLive();
        try vault.cancelListing(c) {
            live.active = false;
            succeeded++;
            cCancel++;
        } catch (bytes memory err) {
            _reverted("cancelListing", err);
        }
    }

    /// @dev Partial fills are the norm, so the fill size is fuzzed against what is left of the order,
    ///      capped at the capacity the fill gate would still admit. THIS IS WHERE THE VAULT WRITES:
    ///      Seaport calls `authorizeOrder` before moving anything, the hook writes exactly the fill
    ///      into Valorem, and `validateOrder` afterwards asserts nothing stayed behind.
    function fill(uint256 fillSeed) external {
        attempted++;
        if (!live.active || vault.listingHash() == bytes32(0)) {
            _skip();
            return;
        }
        // The hook's own gates, mirrored: Listed, not halted, before the exercise window.
        if (uint8(vault.phase()) != 1 || vault.writesHalted() || block.timestamp >= vault.cycleExerciseTs()) {
            _skip();
            return;
        }
        // The issuers' gates: the buyer's USDG cannot reach a paused token or a frozen vault, and the
        // write inside the hook cannot move the vault's Stock Token into Valorem while the vault is
        // blocklisted. Either makes Seaport (honestly) revert the whole fill.
        if (_usdgOutBlocked() || _vaultBlockedOnNvda()) {
            _skip();
            return;
        }

        OrderComponents memory c = _rebuildLive();
        bytes32 h = seaport.getOrderHash(c);
        uint256 remaining = live.amount - seaport.filled(h);
        uint256 capacity = _capacityLeft();
        if (remaining == 0 || capacity == 0) {
            _skip();
            return;
        }
        uint256 maxFill = remaining < capacity ? remaining : capacity;
        uint256 fillAmount = bound(fillSeed, 1, maxFill);
        usdg.mint(buyer, live.unitPrice * fillAmount + 1e6);

        // A live feed keeps ticking: re-stamp `updatedAt` at the SAME answer, so the fill gate's
        // staleness check sees a fresh price and the band/premium floors the listing was priced
        // against are unchanged.
        (, int256 answer,,,) = feed.latestRoundData();
        feed.setAnswer(answer);

        uint256 vaultUsdgBefore = usdg.balanceOf(address(vault));
        uint256 writtenBefore = vault.contractsWritten();
        uint256 keyBefore = vault.claimKey();
        uint256 navBefore = vault.totalAssets();
        vm.prank(buyer);
        try seaport.fulfil(c, fillAmount) {
            // The ghost is the MEASURED inflow, cross-checked against the order's unit price.
            uint256 premiumIn = usdg.balanceOf(address(vault)) - vaultUsdgBefore;
            assertEq(premiumIn, live.unitPrice * fillAmount, "a fill paid the vault something other than its premium");
            ghostPremiumToVault += premiumIn;

            // WRITTEN == SOLD, BY CONSTRUCTION.
            assertEq(vault.contractsWritten(), writtenBefore + fillAmount, "the fill did not write exactly its size");
            totalSold += fillAmount;
            assertEq(clear.balanceOf(address(vault), live.optionId), 0, "option tokens stayed in the vault");
            assertEq(clear.balanceOf(address(vault), vault.claimKey()), 1, "the vault does not hold its claim");
            if (keyBefore == 0) {
                cFirstFills++;
            } else {
                assertEq(vault.claimKey(), keyBefore, "a top-up opened a second claim");
                cTopUpFills++;
            }
            assertEq(vault.totalAssets(), navBefore, "a fill moved the share price");
            _assertVaultAssignedOnlyWhatItSold();
            succeeded++;
            cFill++;
        } catch (bytes memory err) {
            _reverted("fill", err);
        }
    }

    /// @dev Warps into the exercise window if it has not opened yet: assignment is the single
    ///      most consequential thing that can happen to the vault's collateral, and leaving it
    ///      to a lucky random warp would mean testing it almost never.
    function exercise(uint256 amountSeed, uint256 whenSeed) external {
        attempted++;
        uint8 p = uint8(vault.phase());
        if (p != 1 && p != 2) {
            _skip();
            return;
        }
        if (vault.claimKey() == 0) {
            _skip();
            return;
        }
        // The buyer pays the strike into Clear: a paused USDG or a frozen Clear refuses it.
        if (usdg.paused() || usdg.isFrozen(address(clear))) {
            _skip();
            return;
        }

        uint40 exerciseTs = vault.cycleExerciseTs();
        uint40 expiryTs = vault.cycleExpiryTs();
        if (block.timestamp >= expiryTs) {
            _skip();
            return;
        }

        // Check the inventory BEFORE touching the clock. Warping into the exercise window when
        // nobody bought anything would burn the whole listing window and starve the fill path.
        uint256 optionId = vault.optionId();
        uint256 held = clear.balanceOf(buyer, optionId);
        if (held == 0) {
            _skip();
            return;
        }

        if (block.timestamp < exerciseTs) vm.warp(bound(whenSeed, exerciseTs, expiryTs - 1));

        uint112 n = uint112(bound(amountSeed, 1, held));
        usdg.mint(buyer, uint256(n) * vault.cycleStrikeUsdg());

        uint256 lockedBefore = vault.lockedAssets();
        vm.prank(buyer);
        try clear.exercise(optionId, n) {
            // With a third-party writer in the bucket the vault gives up its pro-rata share, not
            // `n` lots: measure what actually left the claim.
            totalAssignedOut += lockedBefore - vault.lockedAssets();
            _assertVaultAssignedOnlyWhatItSold();
            succeeded++;
            cExercise++;
        } catch (bytes memory err) {
            _reverted("exercise", err);
        }
    }

    function lockBook(uint256 whenSeed) external {
        attempted++;
        if (uint8(vault.phase()) != 1) {
            _skip();
            return;
        }
        if (block.timestamp < vault.cycleExerciseTs()) {
            _skip();
            return;
        }

        // Permissionless by design, so call it as a nobody.
        vm.prank(address(uint160(uint256(keccak256(abi.encode(whenSeed))))));
        try vault.lockBook() {
            live.active = false;
            succeeded++;
            cLock++;
        } catch (bytes memory err) {
            _reverted("lockBook", err);
        }
    }

    /// @dev Half the time the keeper closes at expiry, half the time a stranger closes an hour
    ///      later. Both must work; the vault must never need the hot key to give money back.
    function rollClose(uint256 whoSeed) external {
        attempted++;
        uint8 p = uint8(vault.phase());
        if (p != 1 && p != 2) {
            _skip();
            return;
        }

        uint40 expiryTs = vault.cycleExpiryTs();
        bool asKeeper = whoSeed % 2 == 0;
        uint256 openAt = asKeeper ? expiryTs : uint256(expiryTs) + 1 hours;
        // Deliberately does NOT warp. If closing jumped the clock to expiry the Listed phase
        // would end within a call or two of opening and the listing, fill and assignment paths
        // would almost never be reached.
        if (block.timestamp < openAt) {
            _skip();
            return;
        }

        uint256 assignedBefore = vault.contractsAssigned();
        // Whether Valorem's redeem can go through right now: its USDG leg (Clear -> vault) is refused
        // by a pause or a freeze of either end, its NVDA leg by a blocklist of the vault, each only
        // when non-zero. The close must reach Idle EITHER WAY (F-02); this decides which way.
        bool redeemBlocked = (vault.claimedExerciseProceeds() != 0 && _redeemUsdgLegBlocked())
            || (vault.lockedAssets() != 0 && _vaultBlockedOnNvda());
        uint256 key = vault.claimKey();
        uint256 gen = vault.strandGen();
        if (!asKeeper) vm.prank(address(uint160(uint256(keccak256(abi.encode(whoSeed, "closer"))))));
        try vault.rollClose() {
            if (assignedBefore != 0) cAssignedCycles++;
            assertEq(uint8(vault.phase()), 0, "rollClose did not reach Idle");
            if (redeemBlocked) {
                assertTrue(vault.isStranded(), "a close whose redeem was blocked did not strand");
                assertEq(vault.claimKey(), key, "the stranded claim was not kept");
                assertEq(vault.strandGen(), gen + 1, "stranding did not open a new generation");
                assertFalse(vault.canRedeemInstantly(), "instant redemption open over a stranded claim");
                cStrands++;
            } else {
                assertFalse(vault.isStranded(), "a close whose redeem was possible stranded anyway");
                assertEq(vault.claimKey(), 0, "the claim was not redeemed");
            }
            live.active = false;
            succeeded++;
            cClose++;
        } catch (bytes memory err) {
            _reverted("rollClose", err);
        }
    }

    /// @notice Anyone retries a stranded claim. Refused `StillStranded` while the cause persists, and
    ///         on success the redeem's two legs are split between the settled epochs' share (into the
    ///         reserves, to the base unit) and live shares.
    function retryStrandedClaim(uint256 whoSeed) external {
        attempted++;
        if (!vault.isStranded()) {
            _skip();
            return;
        }
        uint256 usdgLeg = vault.claimedExerciseProceeds();
        uint256 nvdaLeg = vault.lockedAssets();
        bool refused = (usdgLeg != 0 && _redeemUsdgLegBlocked()) || (nvdaLeg != 0 && _vaultBlockedOnNvda());
        uint256 gen = vault.strandGen();
        uint256 queueWad = 1e18 - vault.strandedRemainingWad();
        uint256 reservedBefore = vault.reservedAssets();
        uint256 usdgReservedBefore = vault.usdgReservedForQueue();
        uint256 before = nvda.balanceOf(address(vault));
        uint256 usdgBefore = usdg.balanceOf(address(vault));
        uint256 pendingFeeBefore = vault.pendingFeeUsdg();

        vm.prank(address(uint160(uint256(keccak256(abi.encode(whoSeed, "retrier"))))));
        try vault.retryStrandedClaim() {
            assertFalse(refused, "retryStrandedClaim succeeded while a redeem leg was blocked");
            assertEq(vault.claimKey(), 0, "the claim was not redeemed");
            assertFalse(vault.isStranded(), "still stranded after a successful retry");
            assertEq(vault.lastResolvedGen(), gen, "generation not marked resolved");
            assertTrue(vault.canRedeemInstantly(), "flat again but instant redemption refused");
            assertEq(nvda.balanceOf(address(vault)) - before, nvdaLeg, "the redeem returned other than the locked NVDA");
            // The retry's harvest also sweeps a protocol fee the stranded close could not push, so
            // the USDG that arrived is the balance delta plus whatever fee left in the same call. No
            // fee is charged INSIDE the retry: the claim's USDG is fee-free like any strike proceeds.
            uint256 feeSwept = pendingFeeBefore - vault.pendingFeeUsdg();
            assertEq(
                usdg.balanceOf(address(vault)) + feeSwept - usdgBefore,
                usdgLeg,
                "the redeem returned other than the claim USDG"
            );
            (uint256 assetsIn, uint256 usdgIn, uint256 wadLeft, uint256 assetsLeft, uint256 usdgLeft) =
                vault.strands(gen);
            assertEq(assetsIn, nvdaLeg, "generation recorded the wrong NVDA");
            assertEq(usdgIn, usdgLeg, "generation recorded the wrong USDG");
            assertEq(wadLeft, queueWad, "the queue's share of the claim is not what the epochs took");
            assertEq(assetsLeft, (nvdaLeg * queueWad) / 1e18, "queue NVDA is not its pro-rata floor");
            assertEq(usdgLeft, (usdgLeg * queueWad) / 1e18, "queue USDG is not its pro-rata floor");
            assertEq(vault.reservedAssets() - reservedBefore, assetsLeft, "reserve did not grow by the queue's NVDA");
            assertEq(
                vault.usdgReservedForQueue() - usdgReservedBefore,
                usdgLeft,
                "USDG reserve did not grow by the queue's USDG"
            );
            succeeded++;
            cRetries++;
        } catch (bytes memory err) {
            if (refused && bytes4(err) == Vault.StillStranded.selector) {
                succeeded++;
                cRetriesRefused++;
            } else {
                _reverted("retryStrandedClaim", err);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ISSUER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev WHY THE ISSUER ACTIONS ROLL A HASH, NOT THE RAW SEED. The fuzzer's seeds are dictionary-
    ///      biased towards round numbers, so `seed % 10 == 0` fired on a third of the calls rather than a
    ///      tenth and left the vault blocklisted or USDG paused for most of a run: no deposit, no open,
    ///      no fill, and the anti-vacuity floors in {VaultInvariantTest.afterInvariant} fired (observed:
    ///      10 blocklist flips in 600 calls, 0 cycles opened). Hashing the seed with a salt makes the
    ///      rate what it says.
    ///
    ///      THE RATES ARE ASYMMETRIC AND STATE-AWARE. An issuer action switches ON rarely and OFF
    ///      readily, so a run spends roughly a tenth of its time under each restriction: enough for a
    ///      close to strand and a payout to defer its USDG leg in a good share of runs, without starving
    ///      the fill, exercise, deposit and open paths the other invariants need (with symmetric rates
    ///      a run with 25 actions opened no cycle at all about once in six hundred sequences). And while
    ///      a claim is stranded the restriction that strands it lifts on the NEXT call of its toggle:
    ///      the stranded interval still lasts a couple of dozen handler calls of settlements,
    ///      collections, refused retries and refused deposits, but a run cannot spend its second half
    ///      unable to open a cycle because the fuzzer never rolled the unpause.
    function _roll(uint256 seed, string memory salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    /// @dev One in `onEvery` calls switches the restriction on; one in two switches it off, or every
    ///      call while a claim is stranded.
    function _flip(uint256 r, bool on, uint256 onEvery) internal view returns (bool) {
        if (!on) return r % onEvery == 0;
        return vault.isStranded() || r % 2 == 0;
    }

    /// @notice Paxos pauses or unpauses USDG. Blocks `transfer`, `transferFrom` and `approve` for
    ///         everyone; the vault must keep closing, settling and paying its Stock Token leg through it.
    function toggleUsdgPause(uint256 seed) external {
        attempted++;
        bool on = usdg.paused();
        if (!_flip(_roll(seed, "usdg-pause"), on, 12)) {
            _skip();
            return;
        }
        if (on) usdg.unpause();
        else usdg.pause();
        succeeded++;
        cUsdgPauseToggles++;
    }

    /// @notice Paxos freezes or unfreezes the vault (the redeem's USDG recipient, every payout's sender)
    ///         or Clear (the redeem's USDG sender) on USDG.
    function toggleUsdgFreeze(uint256 seed) external {
        attempted++;
        uint256 r = _roll(seed, "usdg-freeze");
        address target = r % 2 == 0 ? address(vault) : address(clear);
        bool on = usdg.isFrozen(target);
        if (!_flip(r >> 1, on, 12)) {
            _skip();
            return;
        }
        if (on) usdg.unfreeze(target);
        else usdg.freeze(target);
        succeeded++;
        cUsdgFreezeToggles++;
    }

    /// @notice The Stock Token issuer blocklists or unblocks the vault. Stops every NVDA transfer to or
    ///         from it, including the redeem's NVDA leg in any week that is not fully assigned. Rarer
    ///         still to switch on: while it holds nothing can be deposited, written or paid out.
    function toggleNvdaBlock(uint256 seed) external {
        attempted++;
        bool on = nvda.isBlocked(address(vault));
        if (!_flip(_roll(seed, "nvda-block"), on, 20)) {
            _skip();
            return;
        }
        if (on) nvda.unblockAccount(address(vault));
        else nvda.blockAccount(address(vault));
        succeeded++;
        cNvdaBlockToggles++;
    }

    /// @notice The issuer seizes Stock Tokens straight out of the vault. `adminBurn` on the live token
    ///         is a bare `_burn` that ignores pause and blocklist, and it is the one action here that
    ///         destroys collateral rather than moving it.
    /// @dev Rare and bounded on purpose: one seed in twelve, at most four burns a run. A seizure is a
    ///      rare event, and an unbounded one wrecks the run rather than testing it: a burn of the whole
    ///      balance leaves NAV at zero with shares outstanding, after which every mint costs one base
    ///      unit, no lot is ever idle again and no cycle can open, and the anti-vacuity gate in
    ///      {VaultInvariantTest.afterInvariant} rightly refuses the run. Two shapes, two a run each:
    ///        - a seizure AIMED AT THE RESERVE, taken whenever the reserve is non-zero and backed: it
    ///          leaves the balance between half the reserve and one base unit below it, so the
    ///          shortfall path (deposits shut, pro-rata haircut on collection) is reached in ordinary
    ///          runs and not only in {VaultInvariantTest.test_handlerReachesABurnShortfallAndTheHaircut};
    ///        - otherwise an ordinary seizure of up to a quarter of the balance, absorbed by live
    ///          shares through NAV.
    ///      The aimed shape has priority because the reserve is non-zero only between a settlement and
    ///      its collection, and the fuzzer's seeds are dictionary-biased towards round numbers, so
    ///      selecting the shape by seed parity almost never landed an aimed burn on a live reserve.
    ///
    ///      NO BURN BEFORE THE FIRST CLOSE. A reserve seizure leaves the vault Idle at NAV zero with
    ///      shares outstanding; from there every mint costs one base unit and only fresh deposits can
    ///      bring a lot back idle, so a run seized early spends most of its 600 calls unable to open a
    ///      cycle and trips the "no cycle was ever closed" floor in {VaultInvariantTest.afterInvariant}
    ///      (observed: one open at call ~450, locked, never closed). Waiting for the first close keeps
    ///      the floors honest — a run has proven it can deposit, open, queue and close before the
    ///      issuer is allowed to wreck it — and every later cycle is still exposed to burns in every
    ///      phase. The ghosts record what was destroyed and how much of it fell on the reserve, which
    ///      is what {VaultInvariantTest.invariant_assetConservation} and
    ///      {VaultInvariantTest.invariant_reservesAreReal} are stated against.
    function adminBurn(uint256 seed, uint256 amountSeed) external {
        attempted++;
        if (seed % 12 != 0 || cClose == 0) {
            _skip();
            return;
        }
        uint256 bal = nvda.balanceOf(address(vault));
        uint256 reserved = vault.reservedAssets();
        uint256 amount;
        if (reserved >= 2 && bal >= reserved && aimedBurns < 2) {
            aimedBurns++;
            amount = bound(amountSeed, bal - reserved + 1, bal - reserved / 2);
        } else {
            if (bal < 4 || ordinaryBurns >= 2) {
                _skip();
                return;
            }
            ordinaryBurns++;
            amount = bound(amountSeed, 1, bal / 4);
        }
        uint256 shortBefore = reserved > bal ? reserved - bal : 0;
        uint256 navBefore = vault.totalAssets();
        // The part of the locked collateral NAV counts: all of it, or the live shares' share of a
        // stranded claim ({Vault.totalAssets}).
        uint256 lockedBefore = navLocked();

        try nvda.adminBurn(address(vault), amount) {
            totalBurned += amount;
            uint256 after_ = bal - amount;
            uint256 shortAfter = reserved > after_ ? reserved - after_ : 0;
            burnReserveShortfall += shortAfter - shortBefore;
            if (shortAfter != 0) cBurnShortfalls++;

            // NAV falls by exactly the part of the burn that live shares absorb, and saturates at
            // zero: the reserve comes off the whole book, never off the idle part alone (F-05).
            uint256 gross = after_ + lockedBefore;
            uint256 navExpected = gross > reserved ? gross - reserved : 0;
            assertEq(vault.totalAssets(), navExpected, "NAV after a burn is not max(balance + locked - reserved, 0)");
            assertLe(vault.totalAssets(), navBefore, "a burn raised NAV");
            // Deposits shut the instant the reserve is unbacked, whatever the phase says.
            if (shortAfter != 0) {
                assertEq(vault.maxDeposit(actors[0]), 0, "maxDeposit quoted room while the reserve is unbacked");
                assertEq(vault.maxMint(actors[0]), 0, "maxMint quoted shares while the reserve is unbacked");
            }
            succeeded++;
            cBurn++;
        } catch (bytes memory err) {
            _reverted("adminBurn", err);
        }
    }

    /// @notice Free-running time, so phases are not always entered at the same instant.
    /// @dev THE RANGE IS THE RUN'S TIME BUDGET. Nothing else moves the clock towards expiry on an
    ///      unfilled week (`exercise` warps only when the buyer holds inventory, and `rollClose`
    ///      deliberately never warps), so a 600-call run sees about `600 / actions` warps and
    ///      exactly as many cycles as their sum covers. The four issuer actions added for F-02
    ///      took the handler to 25 actions (26 after the write-on-fill merge added the third-party
    ///      writer, its exerciser and a second fill slot), a sixth fewer warps a run, and the first
    ///      full-depth run with a late first open and only eight warps left never reached
    ///      `cycleExerciseTs` and tripped the "no cycle was ever closed" floor in
    ///      {VaultInvariantTest.afterInvariant}. Three days rather than two puts the budget back
    ///      at roughly five weekly cycles a run; the seed is hashed ({_roll}) so the mean is
    ///      really the middle of the range rather than whatever the dictionary favours. The one
    ///      seed kept raw is `type(uint256).max`, which `bound` pins to the top of the range: the
    ///      deterministic self-checks below use it to walk the clock to expiry in a known number
    ///      of calls.
    function warpAhead(uint256 seed) external {
        attempted++;
        uint256 r = seed == type(uint256).max ? seed : _roll(seed, "warp");
        vm.warp(block.timestamp + bound(r, 1 hours, 3 days));
        succeeded++;
    }

    /// @notice Halting must never block a redemption, a claim or a close. Flip it often enough
    ///         that a run spends real time halted, but leave writing possible most of the time.
    /// @dev One call in four asks for a halt, three in four for a lift, so a run is halted about a
    ///      quarter of the time. Hashed ({_roll}) for the same reason the issuer toggles are: on
    ///      the raw seed, `% 4 == 0` fired on about half the calls (0, 8_000_000, 1e11 and every
    ///      other round number the dictionary likes), and a run spent half its length unable to
    ///      open a cycle, which is how the vacuity floor first fired after the F-02 actions landed.
    function toggleHalt(uint256 seed) external {
        attempted++;
        bool halt = _roll(seed, "halt") % 4 == 0;
        if (halt == vault.writesHalted()) {
            _skip();
            return;
        }

        if (halt) {
            vm.prank(guardian);
            try vault.haltWrites() {
                succeeded++;
            } catch (bytes memory err) {
                _reverted("haltWrites", err);
            }
        } else {
            vm.prank(admin);
            try vault.unhaltWrites() {
                succeeded++;
            } catch (bytes memory err) {
                _reverted("unhaltWrites", err);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Worst-case USDG the accrual index can over-promise, in base units.
    /// @dev {Distributor} credits `totalUsdgDistributed` with a PER-DISTRIBUTION floor, while a
    ///      holder's `_pending` floors ONCE over the combined index delta since their last
    ///      settle. floor(b*(d1+d2)/A) can exceed floor(b*d1/A) + floor(b*d2/A) by one base
    ///      unit, so each account can out-accrue the credited total by at most one unit per
    ///      distribution it sits through.
    ///
    ///      Only `deposit`, `mint` and `rollClose` move the index, and a close can distribute
    ///      twice (the harvest itself, then a second pass to place any `usdgUnallocated` that
    ///      had been carried), hence the factor of two. That makes this a hard ceiling on the
    ///      drift, and it is measured in millionths of a dollar: any real leak dwarfs it
    ///      instantly. {VaultInvariantTest.afterInvariant} refuses a run where it grows past a
    ///      dollar, so it can never quietly become a hiding place.
    ///
    ///      Two things are allowed to lean on it, and nothing else:
    ///      {VaultInvariantTest.invariant_usdgHolderSolvency}, because it sums per-ACCOUNT
    ///      figures that each carry the drift, and {VaultInvariantTest.invariant_usdgBooksBalance},
    ///      because `usdgOwed()` saturates at zero once lifetime claims pass lifetime credits
    ///      and the saturated figure overstates the liability by exactly that deficit. The hard
    ///      obligations — the settled queue's reserve and the accrued protocol fee — are
    ///      asserted with NO allowance at all in
    ///      {VaultInvariantTest.invariant_reservesAreReal}.
    function maxIndexRoundingDrift() external view returns (uint256) {
        // A `retryStrandedClaim` harvests exactly as a close does, so it can distribute twice too.
        return (cDeposit + cMint + 2 * cClose + 2 * cRetries) * HOLDER_SLOTS;
    }

    /// @notice The locked collateral as NAV counts it: the raw claim figure in an ordinary cycle, the
    ///         live shares' `strandedRemainingWad` of it while a claim is stranded.
    function navLocked() public view returns (uint256) {
        uint256 locked = vault.lockedAssets();
        if (locked == 0 || !vault.isStranded()) return locked;
        return (locked * vault.strandedRemainingWad()) / 1e18;
    }

    function _skip() internal {
        skipped++;
    }

    /// @dev The issuer states that decide which vault calls can move a token right now. Mirrors the
    ///      tokens' own gates (src/mocks/MockERC20.sol, src/mocks/MockStockToken.sol), which mirror
    ///      the live USDG and Stock Token (integrations/usdg.md, integrations/robinhood-chain.md).
    function _vaultBlockedOnNvda() internal view returns (bool) {
        return nvda.isBlocked(address(vault));
    }

    /// @dev USDG cannot leave the vault: pause, or the vault frozen as the sender.
    function _usdgOutBlocked() internal view returns (bool) {
        return usdg.paused() || usdg.isFrozen(address(vault));
    }

    /// @dev The redeem's USDG leg (Clear -> vault) cannot move: pause, or either end frozen.
    function _redeemUsdgLegBlocked() internal view returns (bool) {
        return usdg.paused() || usdg.isFrozen(address(vault)) || usdg.isFrozen(address(clear));
    }

    /// @dev A guarded call that still reverted, which always means a guard is wrong.
    ///
    ///      THERE IS NO TOLERATED REVERT HERE ANY MORE, AND THAT IS THE POINT. An earlier
    ///      revision waved through arithmetic panics and short ERC-20 transfers because
    ///      `usdgOwed()` was a raw subtraction that underflowed the moment the index's floor
    ///      drift bit, bricking `deposit`, `mint` and `rollClose` for the rest of a run. That
    ///      defect is gone: `usdgOwed()` saturates and is informational only, nothing in the
    ///      money path reads it, and every USDG payout is clamped to what the vault can actually
    ///      back. So a panic or a failed transfer is now a NEW bug and must be reported as one
    ///      rather than counted and forgiven.
    function _reverted(string memory action, bytes memory err) internal {
        revertedCalls++;
        if (bytes(firstRevertAction).length == 0) {
            firstRevertAction = action;
            firstRevertData = err;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _canDeposit() internal view returns (bool) {
        uint8 p = uint8(vault.phase());
        if (p != 0 && p != 1) return false;
        // A DEAD VAULT IS NOT DEPOSITED INTO. Full assignment of everything sold (which the third-party
        // exerciser reaches routinely) plus an issuer burn can leave NAV at zero, or a few wei, with the
        // whole supply still outstanding and `balance == reservedAssets` keeping the gate open. A deposit
        // then mints `assets x (supply + 1)` shares at one wei each; two of those in a row put the supply
        // near 1e58 and `shares x accUsdgPerShare` (1e27-scaled) past uint256 in the queue's per-entry
        // maths, so `previewCompleteRedeem` panics for that owner. That is a numeric edge of a book that
        // has lost everything, not a fill or settlement defect, and no front end would quote a deposit
        // into it: the handler stops where a UI would, at a share price under 1e-6 token per share, and
        // the edge is recorded in the stage report rather than papered over in the vault.
        uint256 supply = vault.totalSupply();
        if (supply != 0 && vault.totalAssets() * 1e6 < supply) return false;
        return true;
    }

    /// @dev Queued shares have already moved into escrow at the vault, so a holder's own
    ///      balance is exactly what they can still move or queue.
    function _freeShares(address who) internal view returns (uint256) {
        return vault.balanceOf(who);
    }

    function _fundAsset(address who, uint256 amount) internal {
        uint256 bal = nvda.balanceOf(who);
        if (bal < amount) nvda.mint(who, amount - bal);
    }

    function _refreshSpot(uint256 seed) internal returns (uint256 spotUsdg) {
        int256 answer = int256(bound(seed, 215_00000000, 232_00000000));
        feed.setAnswer(answer); // also stamps updatedAt = now, so the write is never stale
        spotUsdg = uint256(answer) / 100;
    }

    function _installFreshCycle() internal {
        cycleSeq += 1;
        // The seq offset guarantees a distinct option-type hash even if two cycles are
        // installed in the same block, so a new cycle can never reuse a live claim key.
        cycleExercise = uint40(block.timestamp + 6 days + cycleSeq);
        cycleExpiry = uint40(block.timestamp + 7 days + cycleSeq);

        delete cycleOptionIds;
        for (uint256 i; i < strikes.length; i++) {
            cycleOptionIds.push(
                clear.newOptionType(address(nvda), uint96(LOT), address(usdg), strikes[i], cycleExercise, cycleExpiry)
            );
        }
    }

    /// @dev Pick a rung inside the policy's OTM band for this spot, or 0 if none qualifies.
    function _pickRung(uint256 spot, uint256 seed) internal view returns (uint256) {
        (uint16 minOtmBps, uint16 maxOtmBps,,,,) = vault.policy();
        uint256 lo = (spot * (BPS + minOtmBps)) / BPS;
        uint256 hi = (spot * (BPS + maxOtmBps)) / BPS;

        uint256[] memory eligible = new uint256[](strikes.length);
        uint256 count;
        for (uint256 i; i < strikes.length; i++) {
            if (strikes[i] >= lo && strikes[i] <= hi) {
                eligible[count++] = cycleOptionIds[i];
            }
        }
        if (count == 0) return 0;
        return eligible[seed % count];
    }

    /// @dev Contracts the fill gate would still admit this cycle: `Policy.maxContracts(totalAssets())`
    ///      less what is already written. Sized on `totalAssets()` exactly as the gate is.
    function _capacityLeft() internal view returns (uint256) {
        (,,, uint16 maxUtilizationBps,, uint64 cap) = vault.policy();
        uint256 byUtilization = (vault.totalAssets() * maxUtilizationBps) / BPS / LOT;
        uint256 maxTotal = byUtilization < cap ? byUtilization : cap;
        uint256 written = vault.contractsWritten();
        return maxTotal > written ? maxTotal - written : 0;
    }

    function _rebuildLive() internal view returns (OrderComponents memory) {
        return _buildOrderWithCounter(live.optionId, live.amount, live.unitPrice, live.endTime, live.counter, live.salt);
    }

    function _buildOrder(uint256 optionId, uint256 amount, uint256 unitPrice, uint40 endTime, uint256 salt)
        internal
        view
        returns (OrderComponents memory)
    {
        return _buildOrderWithCounter(optionId, amount, unitPrice, endTime, seaport.getCounter(address(vault)), salt);
    }

    /// @dev The vault's order shape: offerer AND zone the vault, PARTIAL_RESTRICTED, one USDG
    ///      consideration item of `unitPrice x amount` to the vault, so every fraction is exact.
    function _buildOrderWithCounter(
        uint256 optionId,
        uint256 amount,
        uint256 unitPrice,
        uint40 endTime,
        uint256 counter,
        uint256 salt
    ) internal view returns (OrderComponents memory c) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155,
            token: address(clear),
            identifierOrCriteria: optionId,
            startAmount: amount,
            endAmount: amount
        });

        ConsiderationItem[] memory consid = new ConsiderationItem[](1);
        consid[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(usdg),
            identifierOrCriteria: 0,
            startAmount: unitPrice * amount,
            endAmount: unitPrice * amount,
            recipient: payable(address(vault))
        });

        c = OrderComponents({
            offerer: address(vault),
            zone: address(vault),
            offer: offer,
            consideration: consid,
            orderType: OrderType.PARTIAL_RESTRICTED,
            startTime: 0,
            endTime: endTime,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: bytes32(0),
            counter: counter
        });
    }
}

/// @notice Stateful invariants for {Vault} (tasks I-01, I-02).
/// @dev The thirteen properties below are the ones that, if they ever stop holding, mean someone
///      cannot be paid or the vault has written what it did not sell. They are checked after every
///      single handler call, in every phase, with
///      collateral locked, orders half filled, buyers assigned, redeemers queued, USDG paused or
///      frozen, the vault blocklisted on its Stock Token and claims stranded (F-02).
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 600
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.shrink-run-limit = 2000
contract VaultInvariantTest is BaseTest {
    /// @dev Must match the `invariant.depth` configured above. {afterInvariant} judges a run's
    ///      productivity only when `attempted` reaches exactly this, so that a shrunk replay
    ///      cannot trip the vacuity gate instead of reporting the failure it was shrinking.
    uint256 internal constant DEPTH = 600;

    VaultHandler internal handler;

    /// @dev Every address that can hold shares or accrue USDG, including the vault itself:
    ///      queued shares sit in escrow AT the vault and keep accruing until settlement, so
    ///      leaving it out of the solvency sum would understate what the vault owes.
    address[5] internal holders;
    /// @dev The third-party writer and exerciser, the only address besides the buyer that can ever
    ///      hold an option token of an id the vault armed.
    address internal mallory;

    function setUp() public override {
        super.setUp();

        mallory = makeAddr("mallory");
        handler = new VaultHandler(
            vault, nvda, usdg, mockClear, mockSeaport, feed, buyer, mallory, admin, guardian, [alice, bob, carol]
        );

        // Hoisted: reading KEEPER_ROLE is itself an external call and would eat the prank.
        bytes32 keeperRole = vault.KEEPER_ROLE();
        vm.prank(admin);
        vault.grantRole(keeperRole, address(handler));

        holders = [alice, bob, carol, buyer, address(vault)];

        bytes4[] memory selectors = new bytes4[](26);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.mintShares.selector;
        selectors[2] = VaultHandler.instantRedeem.selector;
        selectors[3] = VaultHandler.instantWithdraw.selector;
        selectors[4] = VaultHandler.transferShares.selector;
        selectors[5] = VaultHandler.queueRedeem.selector;
        selectors[6] = VaultHandler.completeRedeem.selector;
        selectors[7] = VaultHandler.claimUsdg.selector;
        selectors[8] = VaultHandler.rollOpen.selector;
        selectors[9] = VaultHandler.approveListing.selector;
        selectors[10] = VaultHandler.cancelListing.selector;
        selectors[11] = VaultHandler.fill.selector;
        selectors[12] = VaultHandler.exercise.selector;
        selectors[13] = VaultHandler.rollClose.selector;
        selectors[14] = VaultHandler.lockBook.selector;
        selectors[15] = VaultHandler.warpAhead.selector;
        selectors[16] = VaultHandler.toggleHalt.selector;
        selectors[17] = VaultHandler.settleQueue.selector;
        selectors[18] = VaultHandler.adminBurn.selector;
        selectors[19] = VaultHandler.thirdPartyWrite.selector;
        selectors[20] = VaultHandler.thirdPartyExercise.selector;
        // A second chance for the fill path every round: fills are where the vault writes, and the
        // listing window is short next to the settlement half of a cycle.
        selectors[21] = VaultHandler.fill.selector;
        selectors[22] = VaultHandler.retryStrandedClaim.selector;
        selectors[23] = VaultHandler.toggleUsdgPause.selector;
        selectors[24] = VaultHandler.toggleUsdgFreeze.selector;
        selectors[25] = VaultHandler.toggleNvdaBlock.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice I-01. Every asset base unit is either in the vault, locked behind the live
    ///         Valorem claim, already paid out, or was handed to an assigned buyer. Nothing
    ///         appears from nowhere and nothing evaporates.
    /// @dev The ghosts are built from what the caller ASKED FOR and what the vault's own return
    ///      values PROMISED, never from the balance the vault ended up with. That is what makes
    ///      this a comparison of two independent accounts rather than of a balance with itself.
    function invariant_assetConservation() public view {
        uint256 inflow = handler.totalDeposited();
        // Three ways out and no fourth: paid to a redeemer, taken by an assigned buyer, or
        // destroyed by the issuer's `adminBurn`.
        uint256 outflow = handler.totalWithdrawn() + handler.totalAssignedOut() + handler.totalBurned();
        // Checked separately so a leak reports as a leak instead of an underflow panic.
        assertGe(inflow, outflow, "asset conservation: more asset left the vault than ever entered");

        uint256 accountedFor = nvda.balanceOf(address(vault)) + vault.lockedAssets();
        assertEq(accountedFor, inflow - outflow, "asset conservation: idle + locked != in - out - assigned - burned");
    }

    /// @notice I-02, aggregate half. The vault's own books account for every USDG base unit it
    ///         holds, and never promise more than that.
    /// @dev Everything in this sum is money the vault has already promised to somebody: holders
    ///      (through the index), settled redeemers, the carried remainder, unattributed receipts
    ///      and the accrued protocol fee. If the balance ever dropped below it, some claimant
    ///      could not be paid — and the next harvest would hand out money that is already
    ///      spoken for.
    ///
    ///      WHY THIS ONE CARRIES THE DRIFT ALLOWANCE, AND WHY IT IS NOT A HOLE. An earlier
    ///      revision wrote `distributed - claimed` and bailed out with a bare `return` whenever
    ///      claims had outrun credits — which is exactly the state worth checking, so the
    ///      property went silently vacuous at the only interesting moment. Claims CAN outrun
    ///      credits: the index floors once per distribution while an account's pending accrual
    ///      floors once over the combined delta, so a holder who sits still can claim a base
    ///      unit more than was recorded as credited (pinned in
    ///      {test_accrualIndexCanPromiseMoreUsdgThanItCredited}). `usdgOwed()` saturates at zero
    ///      rather than reporting that deficit, so the saturated figure OVERSTATES the liability
    ///      by precisely the amount of the deficit. The allowance below covers that and nothing
    ///      else; it is bounded by {VaultHandler.maxIndexRoundingDrift}, measured in millionths
    ///      of a dollar, and {afterInvariant} refuses the run if it ever reaches a dollar. The
    ///      obligations that must be backed to the base unit — the queue reserve and the
    ///      pending fee — are asserted with no allowance at all in {invariant_reservesAreReal}.
    function invariant_usdgBooksBalance() public view {
        uint256 balance = usdg.balanceOf(address(vault));

        uint256 committed = vault.usdgOwed() + vault.usdgReservedForQueue() + vault.usdgDust() + vault.usdgUnallocated()
            + vault.pendingFeeUsdg();
        assertLe(
            committed,
            balance + handler.maxIndexRoundingDrift(),
            "USDG books: the vault has committed more than it holds"
        );

        // `usdgAccounted` is the harvest's anchor: new premium is detected as
        // `balance - usdgAccounted`. If it ever ran ahead of the balance, real premium would
        // become invisible to the harvest and silently belong to nobody. No allowance: this one
        // is a measured checkpoint, not an inferred figure, so nothing rounds.
        assertLe(vault.usdgAccounted(), balance, "usdgAccounted has run ahead of the USDG actually held");

        // THE QUEUE'S BOOKS, DECOMPOSED EXACTLY. Settlement is split in two: `_settleEpochEntry`
        // moves a share of the epoch into `owedQueueUsdg` without touching a token, and
        // `_payoutOwed` is the only leg that transfers. The reserve therefore has to be the sum
        // of what is still sitting in the epochs and what has been staged against accounts. If
        // those ever diverged, either the staging step would be minting an obligation out of
        // nothing or the payout leg would be drawing the reserve down twice. Stated as an
        // equality, with no allowance, because every term here is moved by whole assignments.
        uint256 inEpochs;
        uint256 staged;
        for (uint256 e = 1; e <= vault.epochId(); e++) {
            (,, uint256 usdgRemaining) = vault.epochs(e);
            inEpochs += usdgRemaining;
        }
        for (uint256 i; i < holders.length; i++) {
            staged += vault.owedQueueUsdg(holders[i]);
        }
        // Plus the settled epochs' USDG share of every redeemed stranded claim not yet folded in
        // (`strands[gen].usdgLeft`, F-02); see the asset leg in {invariant_reservesAreReal}.
        assertEq(
            vault.usdgReservedForQueue(),
            inEpochs + staged + handler.strandUsdgLeft(),
            "queue USDG reserve != unsettled epochs + staged balances + uncollected stranded-claim shares"
        );
    }

    /// @notice I-02, per-holder half. Every account can be paid what it can see, right now.
    /// @dev Everything the USDG balance stands behind: what holders can claim, what settled
    ///      redeemers are owed, the indexing remainder, money received while nobody held
    ///      shares, and the protocol fee accrued but not yet swept.
    ///
    ///      THE ALLOWANCE IS NOT SLOPPINESS. {Distributor} genuinely over-promises by up to one
    ///      base unit per account per distribution; see {handler.maxIndexRoundingDrift} and
    ///      {test_accrualIndexCanPromiseMoreUsdgThanItCredited}. The bound is exact and tiny
    ///      (millionths of a dollar, and {afterInvariant} refuses a run where it grows past a
    ///      dollar), so a real leak still trips this instantly. Remove the allowance the day the
    ///      index rounding is fixed.
    function invariant_usdgHolderSolvency() public view {
        uint256 owed;
        for (uint256 i; i < holders.length; i++) {
            owed += vault.claimableUsdg(holders[i]);
        }
        owed += vault.usdgReservedForQueue();
        owed += vault.usdgDust();
        owed += vault.usdgUnallocated();
        owed += vault.pendingFeeUsdg();

        assertLe(
            owed,
            usdg.balanceOf(address(vault)) + handler.maxIndexRoundingDrift(),
            "USDG solvency: vault owes more than it holds"
        );
    }

    /// @notice Share supply is exactly the shares people hold plus the shares in queue escrow.
    function invariant_shareAccounting() public view {
        uint256 sum;
        for (uint256 i; i < holders.length; i++) {
            sum += vault.balanceOf(holders[i]);
        }
        assertEq(vault.totalSupply(), sum, "share accounting: supply != sum of balances");

        // The option buyer is not a shareholder. This is load-bearing, not decorative: the
        // holder set above has to be CLOSED for the sum to mean anything, and
        // {VaultHandler.HOLDER_SLOTS} bounds the rounding allowance by the same count.
        assertEq(vault.balanceOf(buyer), 0, "the option buyer must never hold shares");

        // rollClose settles atomically, so the escrow is never observably out of step.
        assertEq(vault.queuedShares(), vault.balanceOf(address(vault)), "queuedShares != escrow balance");
    }

    /// @notice Nobody can redeem more than the vault actually has. Premium lives outside the
    ///         share price, so the whole supply must always convert to at most `totalAssets`.
    function invariant_noFreeShares() public view {
        if (vault.totalSupply() == 0) return;
        assertLe(
            vault.convertToAssets(vault.totalSupply()),
            vault.totalAssets(),
            "share price over-quotes the assets behind it"
        );

        // The version with teeth. The line above is close to an identity of `mulDiv`; this one
        // ties three independent numbers together — the live share price, the reserve carved
        // out for settled redeemers, and the collateral sitting inside Valorem. If settlement
        // ever reserved assets it did not first remove from the share price, or a cycle closed
        // without the collateral coming back, the standing holders would be quoted a redemption
        // value that eats a settled redeemer's money, and this is where that shows up.
        uint256 owedToHolders;
        for (uint256 i; i < holders.length; i++) {
            owedToHolders += vault.convertToAssets(vault.balanceOf(holders[i]));
        }
        // The reserve's REAL claim is `min(reservedAssets, balance)`: after an issuer burn takes the
        // balance below it, every uncollected claimant is paid the same `balance / reserved` fraction
        // ({Vault._payoutOwed}), so together they take exactly the balance and not a base unit
        // more. With no burn in the run this is the plain `reservedAssets`.
        uint256 balance = nvda.balanceOf(address(vault));
        uint256 reserved = vault.reservedAssets();
        uint256 reserveClaim = reserved < balance ? reserved : balance;
        assertLe(
            owedToHolders + reserveClaim,
            balance + vault.lockedAssets(),
            "holders plus settled redeemers are owed more asset than exists"
        );
        // And NAV is the formula, not a paraphrase of it: the reserve comes off the whole book and
        // only the final figure saturates (F-05). Stated here because a burn is the only action that
        // can make `balance + locked < reserved`, and this is where the two formulas diverged. While
        // a claim is stranded only the live shares' `strandedRemainingWad` of the locked collateral
        // counts: the rest is owed to epochs that settled while it was stranded (F-02).
        uint256 gross = balance + handler.navLocked();
        assertEq(
            vault.totalAssets(),
            gross > reserved ? gross - reserved : 0,
            "totalAssets != max(balance + locked x live share - reserved, 0)"
        );
    }

    /// @notice Deposits are shut, and quoted shut, for exactly as long as the reserve is unbacked.
    /// @dev The one `_depositRefused()` predicate serves `maxDeposit`/`maxMint` and `deposit`/`mint`
    ///      alike. An earlier draft kept two copies with no reserve check in either, so after an
    ///      issuer burn a newcomer's deposit was quoted at the full cap and paid straight out to
    ///      earlier settled redeemers (F-05). Here: whenever `balance < reservedAssets`, both quotes
    ///      are zero; and whenever a quote is non-zero, the reserve is backed and the phase is one
    ///      that accepts deposits.
    function invariant_depositGateTracksTheReserve() public view {
        uint256 balance = nvda.balanceOf(address(vault));
        uint256 room = vault.maxDeposit(alice);
        if (balance < vault.reservedAssets()) {
            assertEq(room, 0, "maxDeposit quoted room while the balance is below the reserve");
            assertEq(vault.maxMint(alice), 0, "maxMint quoted shares while the balance is below the reserve");
        }
        // Nobody buys in over a stranded claim: its strike USDG is owed to the holders of record.
        if (vault.isStranded()) {
            assertEq(room, 0, "maxDeposit quoted room while a claim is stranded");
            assertEq(vault.maxMint(alice), 0, "maxMint quoted shares while a claim is stranded");
        }
        if (room != 0) {
            assertGe(balance, vault.reservedAssets(), "deposits quoted open over an unbacked reserve");
            uint8 p = uint8(vault.phase());
            assertTrue(p == 0 || p == 1, "deposits quoted open outside Idle and Listed");
            assertFalse(vault.isStranded(), "deposits quoted open over a stranded claim");
            assertEq(room, vault.depositCap() - vault.totalAssets(), "maxDeposit is not cap minus NAV");
        }
    }

    /// @notice A settled redeemer's money is really there. Reserves are carved out of the
    ///         balance, never out of the locked collateral or out of thin air.
    function invariant_reservesAreReal() public view {
        // The asset leg is strict up to what the issuer has destroyed. `reservedAssets` is set from
        // a real balance at settlement and drawn down by real transfers, so nothing the VAULT does
        // can put it above the balance; only an `adminBurn` can, and the handler measures exactly
        // how much of each burn landed on the reserve. A shortfall above that ghost would mean the
        // vault itself had promised money it never had. With no burn in the run the bound is the
        // plain `reservedAssets <= balance`.
        assertLe(
            vault.reservedAssets(),
            nvda.balanceOf(address(vault)) + handler.burnReserveShortfall(),
            "reservedAssets exceeds the asset balance by more than the issuer burnt out of the reserve"
        );

        // The USDG leg is STRICT, and it deliberately carries no allowance even though
        // {invariant_usdgHolderSolvency} needs one. It used to need one too: `_settleQueue`
        // reserves the escrow's accrual straight out of the over-promising index, and before
        // `_takeAccrued` clamped to what the vault can back, `usdgReservedForQueue` came out one
        // base unit ABOVE the balance. That is not a rounding curiosity — `_payoutOwed` moves
        // the asset leg and the USDG leg in one call, so the short transfer reverted the whole
        // redemption and stranded 6.6e18 of principal. Replayed in
        // {test_settledRedeemerIsAlwaysPayable}. Never soften this back into an allowance; the
        // clamp is what makes it hold.
        assertLe(
            vault.usdgReservedForQueue(),
            usdg.balanceOf(address(vault)),
            "usdgReservedForQueue exceeds the USDG balance"
        );

        // The two HARD obligations together. `pendingFeeUsdg` exists because the harvest is now
        // checkpointed on every deposit and a checkpoint must not make an external call, so the
        // protocol fee piles up in storage and is swept once, at `rollClose`. Between those
        // points it is money the vault owes and must not lend to a claimant, which is why
        // {Vault._usdgAvailableForHolders} subtracts it. Stated with no allowance because both
        // terms are only ever moved by whole, measured amounts.
        assertLe(
            vault.usdgReservedForQueue() + vault.pendingFeeUsdg(),
            usdg.balanceOf(address(vault)),
            "the queue reserve plus the accrued protocol fee is more than the vault holds"
        );

        // The asset leg of the same split-settlement decomposition {invariant_usdgBooksBalance}
        // states for USDG: the reserve is exactly what is still owed inside the open epochs, plus
        // what has been staged against accounts by an earlier `queueRedeem`, plus the settled
        // epochs' share of every REDEEMED stranded claim that its owners have not folded in yet
        // (`strands[gen].assetsLeft`, F-02). Stated as an equality with no allowance: the last owner
        // of a generation takes exactly what is left of it, so no dust ever stays in the reserve.
        uint256 inEpochs;
        uint256 staged;
        for (uint256 e = 1; e <= vault.epochId(); e++) {
            (, uint256 assetsRemaining,) = vault.epochs(e);
            inEpochs += assetsRemaining;
        }
        for (uint256 i; i < holders.length; i++) {
            staged += vault.owedAssets(holders[i]);
        }
        assertEq(
            vault.reservedAssets(),
            inEpochs + staged + handler.strandAssetsLeft(),
            "asset reserve != unsettled epochs + staged balances + uncollected stranded-claim shares"
        );

        // `lockedAssets()` is read straight out of Valorem's position; `contractsWritten` comes from
        // the vault's own counter and the exercised amount from the claim. If those ever disagree,
        // the vault's idea of its collateral has drifted from the clearinghouse's and `totalAssets`
        // — and therefore the share price — is wrong. Assignment is a WAD figure here: with a third
        // party in the bucket the vault's share is fractional, so the identity is stated against
        // Valorem's `amountExercised`, and `contractsAssigned()` (its floor) is bounded by written.
        uint256 written = vault.contractsWritten();
        uint256 key = vault.claimKey();
        if (key != 0) {
            IValoremClear.Claim memory c = mockClear.claim(key);
            assertEq(c.amountWritten, written * 1e18, "Valorem's amount written != contractsWritten");
            assertLe(c.amountExercised, c.amountWritten, "more assigned than was ever written (and sold)");
            // Floored per claim index on both sides in Valorem: a wei of dust, one index (see the handler).
            assertApproxEqAbs(
                vault.lockedAssets(), c.amountWritten - c.amountExercised, 1, "locked != written - exercised"
            );
        } else {
            assertEq(vault.lockedAssets(), 0, "locked collateral with no claim");
        }
        assertLe(vault.contractsAssigned(), written, "more contracts assigned than were ever written");
    }

    /// @notice THE F-01 CLOSURE (decision D1). The vault never holds an unsold option token: outside
    ///         a fill its balance of the armed id is zero, so there is nothing for a third-party
    ///         writer to be assigned against beyond what the vault sold, and `written == sold`.
    /// @dev The handler's third-party writer shares the vault's bucket and exercises at will; this
    ///      is checked after every single call, in every phase.
    function invariant_vaultHoldsNoOptionTokens() public view {
        uint256 id = vault.optionId();
        if (id != 0) {
            assertEq(mockClear.balanceOf(address(vault), id), 0, "the vault holds unsold option tokens");
        }
        uint256 key = vault.claimKey();
        if (key != 0) {
            assertEq(mockClear.balanceOf(address(vault), key), 1, "the vault does not hold its own claim");
        }
    }

    /// @notice THE F-01 BOUND, LIFETIME FORM. Over the whole run, every asset base unit the vault's
    ///         claims ever gave up to an exerciser is backed by a contract the vault SOLD; and the
    ///         live claim is never assigned on more than `contractsWritten`, which under write on
    ///         fill is what this cycle sold.
    /// @dev {invariant_reservesAreReal} states the per-claim identity against Valorem's WAD figures.
    ///      This one is the cumulative statement across cycles, which is the number a depositor
    ///      cares about: with a third-party writer steering the bucket, exercising far more than the
    ///      vault sold, the vault's lifetime assignment still never exceeds `totalSold` lots. Before
    ///      the redesign the same handler (pre-writing at arm) would have failed it in the first
    ///      in-the-money week.
    function invariant_assignedNeverExceedsSold() public view {
        assertLe(
            handler.totalAssignedOut(),
            handler.totalSold() * 1e18,
            "the vault has been assigned on more collateral than it ever sold contracts for"
        );
        uint256 written = vault.contractsWritten();
        assertLe(vault.contractsAssigned(), written, "this cycle: assigned on more than it sold");
        uint256 key = vault.claimKey();
        if (key != 0) {
            IValoremClear.Claim memory c = mockClear.claim(key);
            assertLe(c.amountExercised, written * 1e18, "Valorem assigned the vault on more than it wrote (and sold)");
        }
    }

    /// @notice Long supply is unexercised collateral, for every option id the vault ever armed. Every
    ///         option token outstanding is held by a buyer or the third-party writer, never the
    ///         vault, and their number equals the contracts still unexercised across the id's
    ///         buckets, whose collateral sits in the clearinghouse.
    /// @dev Upstream Clear keeps this implicitly: `write` mints exactly what it collateralises and
    ///      `exercise` burns exactly what it assigns. {MockClear} tracks the supply so the suite can
    ///      say it out loud, on the armed id and on every earlier one (an expired id's longs are
    ///      never burnt, and its buckets never move again, so the identity has to survive the
    ///      close). It is what makes {invariant_vaultHoldsNoOptionTokens} mean "the vault wrote
    ///      nothing it did not sell" rather than only "the vault's balance is zero": if a write ever
    ///      minted more than it collateralised, or an exercise burnt less than it assigned, the
    ///      supply would stop matching the buckets here.
    function invariant_longSupplyIsUnexercisedCollateral() public view {
        uint256[] memory ids = handler.armedOptionIds();
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 supply = mockClear.optionSupply(id);
            assertEq(supply, mockClear.unexercisedContracts(id), "option tokens outstanding != unexercised contracts");
            assertEq(
                supply,
                mockClear.balanceOf(buyer, id) + mockClear.balanceOf(mallory, id)
                    + mockClear.balanceOf(address(vault), id),
                "option tokens outstanding are not all in the buyer's and the third-party writer's hands"
            );
            assertEq(
                mockClear.balanceOf(address(vault), id), 0, "the vault holds an option token of a past or live cycle"
            );
        }
    }

    /// @notice Idle means flat. If it does not, instant redemption would pay out collateral
    ///         that is still collateralising somebody's short call.
    ///
    ///      THE ONE EXCEPTION IS A STRANDED CLAIM (F-02). `rollClose` reaches Idle even when Valorem's
    ///      redeem reverts, keeping `claimKey` and `contractsWritten`; that is `isStranded()`, and it
    ///      is the only way Idle can coexist with an open claim. While it holds the instant path must
    ///      be shut (the kept `contractsWritten` is what shuts it), deposits must be shut, exactly one
    ///      generation must be open, and live shares' share of the claim must be a fraction of one.
    function invariant_phaseSanity() public view {
        bool stranded = vault.isStranded();
        if (vault.contractsWritten() > 0) {
            assertTrue(uint8(vault.phase()) != 0 || stranded, "contracts written while Idle and not stranded");
        }
        if (uint8(vault.phase()) == 0) {
            if (stranded) {
                assertTrue(vault.claimKey() != 0, "stranded without a claim");
                assertGt(vault.contractsWritten(), 0, "stranded with nothing written");
                assertFalse(vault.canRedeemInstantly(), "instant redemption open over a stranded claim");
                assertEq(vault.maxDeposit(alice), 0, "deposits open over a stranded claim");
                assertEq(vault.strandGen(), vault.lastResolvedGen() + 1, "not exactly one generation open");
                assertLe(vault.strandedRemainingWad(), 1e18, "live shares own more than the whole claim");
            } else {
                assertEq(vault.claimKey(), 0, "Idle with an open claim");
                assertEq(vault.lockedAssets(), 0, "Idle with collateral still locked in Valorem");
                assertTrue(vault.canRedeemInstantly(), "Idle and flat but instant redemption refused");
                assertEq(vault.strandGen(), vault.lastResolvedGen(), "a generation is open but nothing is stranded");
            }
        } else {
            assertEq(vault.strandGen(), vault.lastResolvedGen(), "a cycle is open over an unresolved generation");
        }
        // Settling is entered and left inside a single `rollClose`, so no outside observer can
        // ever catch the vault in it. If this ever fires, some path left the vault wedged.
        assertTrue(uint8(vault.phase()) != 3, "observed the Settling phase from outside rollClose");
    }

    /// @notice A stranded claim is owned in full, and by exactly the parties the books name (F-02).
    /// @dev WAD conservation across the three places a share of a stranded claim can sit: live shares
    ///      (`strandedRemainingWad`), epochs that settled while it was stranded (`epochStrandWad`) and
    ///      owners who settled their entry out of such an epoch (`owedStrandWad`). While a generation
    ///      is open they sum to exactly 1e18; once it is redeemed, what its epochs and owners still
    ///      hold is exactly the generation's `wadLeft`, which is what makes the last owner's "take
    ///      what is left" drain the reserves to zero ({Vault._strandSlice}). If a share were ever
    ///      minted or lost between an epoch and an owner, either the reserve would keep money nobody
    ///      can claim or an owner would be quoted money the reserve does not hold.
    function invariant_strandSharesAreConserved() public view {
        uint256 gens = vault.strandGen();
        for (uint256 g = 1; g <= gens; g++) {
            uint256 inEpochs;
            uint256 inOwners;
            for (uint256 e = 1; e <= vault.epochId(); e++) {
                if (vault.epochStrandGen(e) == g) inEpochs += vault.epochStrandWad(e);
            }
            for (uint256 i; i < holders.length; i++) {
                if (vault.owedStrandGen(holders[i]) == g) inOwners += vault.owedStrandWad(holders[i]);
            }
            if (g > vault.lastResolvedGen()) {
                assertEq(
                    vault.strandedRemainingWad() + inEpochs + inOwners,
                    1e18,
                    "an open generation's shares do not sum to the whole claim"
                );
            } else {
                (,, uint256 wadLeft,,) = vault.strands(g);
                assertEq(inEpochs + inOwners, wadLeft, "a redeemed generation's outstanding shares != wadLeft");
            }
        }
    }

    /// @notice The protocol fee is a cut of PREMIUM, never of principal. Everything the fee
    ///         recipient has ever been paid, plus everything accrued and not yet swept, is at most
    ///         `protocolFeeBps` of the premium that ever reached the vault.
    /// @dev WHY THIS BOUND IS SOUND. Let u = usdg.balanceOf(vault) - usdgAccounted, the USDG the
    ///      harvest has not yet seen. A fill raises u by exactly its premium. Every payout lowers
    ///      the balance and `usdgAccounted` together, or (when `_debitUsdgOut` saturates) lowers
    ///      u, so no outflow ever raises it. A harvest charges its fee on u minus the fee-free
    ///      amount and resets u to 0: a deposit/mint checkpoint passes 0, and `rollClose` passes
    ///      the claim redemption S, measured the instant before the harvest and therefore also
    ///      sitting inside u, so its fee base is u - S, the premium since the last harvest. So
    ///      the fee bases summed over every harvest never exceed the premium summed over every
    ///      fill, and since each fee is floor(base * bps / 10_000), sum(fee) * 10_000 <=
    ///      sum(base) * bps <= premium * bps. Stated multiplied out so no floor enters the bound.
    ///
    ///      `feeSafe` is fed by nothing but `_tryPayFee`, which moves a fee out of
    ///      `pendingFeeUsdg` only when the transfer succeeds, so `balance(feeSafe) +
    ///      pendingFeeUsdg` is exactly the lifetime fee accrued. The handler has no action that
    ///      changes the policy or the fee recipient, so one `protocolFeeBps` governs every
    ///      harvest in a run; that is pinned below rather than assumed. If a policy-changing
    ///      action is ever added, bound by the MAXIMUM fee bps seen over the run instead.
    ///
    ///      What it catches: fee'ing strike proceeds. A single assigned 226.00 contract fee'd at
    ///      5% is 11.30 USDG, while the handler never prices a contract above ~5.57 USDG gross, so the
    ///      first assigned close after a pre-change build would put the fee far over this line.
    function invariant_feeNeverTouchesStrikeProceeds() public view {
        _assertFeeBoundedByPremium(handler.ghostPremiumToVault());
    }

    /// @dev The body of {invariant_feeNeverTouchesStrikeProceeds}, taking the premium as an
    ///      argument so a hand-driven unit test that never went through the handler can state the
    ///      same property against the premium it put in itself.
    function _assertFeeBoundedByPremium(uint256 premiumToVault) internal view {
        (,,,, uint16 feeBps,) = vault.policy();
        assertEq(
            feeBps,
            Policy.launchDefaults().protocolFeeBps,
            "the fee bps moved during a run: this bound assumes one rate and must track the max"
        );

        uint256 feesTaken = usdg.balanceOf(feeSafe) + vault.pendingFeeUsdg();
        assertLe(
            feesTaken * 10_000,
            premiumToVault * feeBps,
            "protocol fee exceeds protocolFeeBps of the premium: it has been charged on strike proceeds"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            ANTI-VACUITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Refuse to call a run a pass if it never actually did anything.
    /// @dev Runs at the end of every invariant run. Without this the suite would go green on a
    ///      handler whose every action bailed out on a precondition, which is the classic way
    ///      an invariant suite lies to you.
    function afterInvariant() public {
        uint256 att = handler.attempted();
        uint256 ok = handler.succeeded();

        emit log_named_uint("attempted", att);
        emit log_named_uint("succeeded", ok);
        emit log_named_uint("skipped", handler.skipped());
        emit log_named_uint("failed", handler.revertedCalls());
        emit log_named_uint("deposits", handler.cDeposit());
        emit log_named_uint("mints", handler.cMint());
        emit log_named_uint("instant redeems", handler.cRedeem());
        emit log_named_uint("instant withdraws", handler.cWithdraw());
        emit log_named_uint("share transfers", handler.cTransfer());
        emit log_named_uint("queued redeems", handler.cQueue());
        emit log_named_uint("completed redeems", handler.cComplete());
        emit log_named_uint("usdg claims", handler.cClaim());
        emit log_named_uint("rollOpens", handler.cOpen());
        emit log_named_uint("listings", handler.cList());
        emit log_named_uint("listings cancelled", handler.cCancel());
        emit log_named_uint("fills", handler.cFill());
        emit log_named_uint("exercises", handler.cExercise());
        emit log_named_uint("books locked", handler.cLock());
        emit log_named_uint("rollCloses", handler.cClose());
        emit log_named_uint("fills opening a claim", handler.cFirstFills());
        emit log_named_uint("fills topping a claim up", handler.cTopUpFills());
        emit log_named_uint("flat queue settlements", handler.cSettleQueue());
        emit log_named_uint("third-party writes into the bucket", handler.cThirdPartyWrite());
        emit log_named_uint("third-party exercises", handler.cThirdPartyExercise());
        emit log_named_uint("issuer burns", handler.cBurn());
        emit log_named_uint("burns that unbacked the reserve", handler.cBurnShortfalls());
        emit log_named_uint("haircut redemptions", handler.cHaircuts());
        emit log_named_uint("deferred USDG legs", handler.cDeferredUsdgLegs());
        emit log_named_uint("stranded closes", handler.cStrands());
        emit log_named_uint("stranded claims redeemed", handler.cRetries());
        emit log_named_uint("retries refused StillStranded", handler.cRetriesRefused());
        emit log_named_uint("USDG pause flips", handler.cUsdgPauseToggles());
        emit log_named_uint("USDG freeze flips", handler.cUsdgFreezeToggles());
        emit log_named_uint("NVDA blocklist flips", handler.cNvdaBlockToggles());
        emit log_named_uint("cycles with assignment", handler.cAssignedCycles());

        emit log_named_uint("index rounding allowance (usdg base units)", handler.maxIndexRoundingDrift());
        emit log_named_uint("claims the vault could not fund in full", handler.unfundedClaims());
        emit log_named_uint("worst unfunded claim (usdg base units)", handler.maxClaimShortfall());
        if (handler.revertedCalls() != 0) {
            emit log_named_string("first reverting action", handler.firstRevertAction());
            emit log_named_bytes("first revert data", handler.firstRevertData());
        }

        // NOTHING IS FORGIVEN HERE ANY MORE. The vault used to brick itself on an `usdgOwed()`
        // underflow, and this gate used to carve out the dead tail of such a run. `usdgOwed()`
        // saturates now, nothing in the money path reads it, and every USDG payout is clamped to
        // what the vault can back, so a panic or a failed transfer is a new bug rather than a
        // known one: it reports as a broken guard and fails the run.
        assertEq(handler.revertedCalls(), 0, "a guarded handler call still reverted: a guard is wrong");
        assertGt(att, 0, "no handler calls at all");

        // A holder can always be paid what the vault can back, and the only thing it cannot back
        // is the index's floor drift. Anything larger left unpaid is a leak, not rounding.
        assertLe(
            handler.maxClaimShortfall(),
            handler.maxIndexRoundingDrift(),
            "a holder was left unpaid by more than the index can over-promise by rounding"
        );

        // The drift allowance is only honest while it stays negligible. A dollar of slack in a
        // suite whose whole job is solvency would be a hole, not a bound, so refuse the run
        // before it gets there.
        assertLt(
            handler.maxIndexRoundingDrift(),
            1_000_000,
            "the index rounding allowance grew past one dollar: it is a hole now, not a bound"
        );

        // ONLY JUDGE VACUITY ON A RUN THAT ACTUALLY RAN TO DEPTH, and mean it: the gate has to
        // be the exact depth, not "nearly". A failure anywhere makes Foundry shrink the
        // sequence and re-run it, and a shrunk sequence has had most of its calls deleted — so
        // a loose gate (this said `att < 500` against a depth of 600) lets the shrinker land on
        // a 500-call sequence with no deposits in it. The run then fails as "no deposits",
        // which is an artefact of shrinking and tells you nothing about the real failure it
        // started from. Gating on the full depth makes every shrunk candidate pass here, so the
        // shrinker cannot hide the original failure behind this gate.
        if (att < DEPTH) return;

        // ABSOLUTE FLOORS, OVER THE WHOLE RUN. These are the anti-vacuity gate proper: they name
        // the state transitions the properties above are worthless without. Money has to get in,
        // a cycle has to be written, the queue has to be used, and a cycle has to close — the
        // close is the one call that redeems the Valorem claim, harvests, sweeps the protocol
        // fee and settles an epoch, so a run that never reached one checked every invariant
        // against a vault that had only ever taken deposits.
        //
        // Each floor is `> 0` against a measured minimum far above it: across 100 seeds the
        // leanest full-depth run still managed 23 deposits and mints, 2 rollOpens, 22 queued
        // redemptions and 2 closes. Fills, assignments and USDG claims are deliberately NOT
        // floored: all three genuinely can miss in a run (an unfilled week is a real week), and
        // {test_handlerReachesEveryState} is what pins that the handler can reach them at all.
        assertGt(handler.cDeposit() + handler.cMint(), 0, "no deposits in this run");
        assertGt(handler.cOpen(), 0, "no cycle was ever opened in this run");
        assertGt(handler.cQueue(), 0, "nobody used the redeem queue in this run");
        assertGt(handler.cClose(), 0, "no cycle was ever closed in this run");

        // And a coarse floor on overall productivity, to catch a guard that has quietly rotted
        // into "skip everything" without tripping any of the counters above.
        //
        // THE NUMBER IS MEASURED, NOT WISHED FOR, and it is one in EIGHT rather than the one in
        // five it used to be. Most skips are structural and correct — instant redemption is
        // illegal while a call is open, a listing cannot be approved outside `Listed`, a claim
        // needs a harvest to have happened first — so the ratio is noisy by nature. Asserting
        // the ratio on EVERY run rather than only the last, over 30 seeds (13,000-odd
        // sequences), put the typical run at 38-42% and the worst at 24.5%. A one-in-five line
        // therefore sat 1.2x from the observed floor, which is not headroom, it is a coin flip
        // waiting to happen — and an anti-vacuity gate that cries wolf gets deleted. One in
        // eight is still 75 real state transitions in a 600-call run and sits a clear factor of
        // two below anything ever observed, so when it fires the guards really are broken. The
        // absolute floors above are what carry the weight; this is the backstop.
        assertGe(ok * 8, att, "fewer than an eighth of handler calls did anything: the run is near-vacuous");
    }

    /*//////////////////////////////////////////////////////////////
                      HANDLER SELF-CHECK (DETERMINISTIC)
    //////////////////////////////////////////////////////////////*/

    /// @notice Proves the handler can reach every state the invariants care about, so a green
    ///         run means the properties survived a real cycle rather than an empty one.
    function test_handlerReachesEveryState() public {
        handler.deposit(0, type(uint256).max); // alice, the biggest ticket the handler writes
        handler.deposit(1, type(uint256).max); // bob, the same
        handler.rollOpen(0, 0);
        assertEq(uint8(vault.phase()), 1, "should be Listed");
        assertEq(vault.contractsWritten(), 0, "arming writes nothing");

        handler.approveListing(type(uint256).max, 0, 0);
        assertTrue(vault.listingHash() != bytes32(0), "should have a live listing");

        handler.fill(1); // partial fill: opens the claim
        assertGt(vault.contractsWritten(), 0, "the fill wrote");
        handler.thirdPartyWrite(3); // an adversary joins the bucket
        handler.fill(2); // another fill: tops the claim up
        assertGt(handler.cTopUpFills(), 0, "a top-up fill");
        handler.deposit(2, 0); // carol deposits mid-cycle: new money, same open short
        handler.queueRedeem(0, type(uint256).max);
        assertGt(vault.queuedShares(), 0, "should have shares in escrow");

        handler.exercise(0, 0); // partial assignment inside the window
        handler.thirdPartyExercise(type(uint256).max, 0); // the adversary exercises everything it wrote
        assertGt(handler.totalAssignedOut(), 0, "should have been assigned");
        assertGt(handler.cThirdPartyExercise(), 0, "third-party exercise");

        handler.lockBook(0);
        assertEq(uint8(vault.phase()), 2, "should be Exercisable");

        // Nothing in the handler warps for the closer, so walk the clock past expiry + 1h.
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.rollClose(1); // closed by a stranger, an hour after expiry
        assertEq(uint8(vault.phase()), 0, "should be back to Idle");
        assertGt(vault.epochId(), 1, "queue should have settled an epoch");

        handler.completeRedeem(0);
        handler.claimUsdg(1);
        handler.instantRedeem(1, type(uint256).max);

        assertEq(handler.revertedCalls(), 0, "no handler call should have reverted");
        assertEq(handler.maxClaimShortfall(), 0, "a clean cycle should leave nobody short of USDG");

        // Every action the invariant run depends on actually fired at least once here.
        assertGt(handler.cDeposit(), 0, "deposit");
        assertGt(handler.cOpen(), 0, "rollOpen");
        assertGt(handler.cList(), 0, "approveListing");
        assertGt(handler.cFill(), 0, "fill");
        assertGt(handler.cQueue(), 0, "queueRedeem");
        assertGt(handler.cExercise(), 0, "exercise");
        assertGt(handler.cLock(), 0, "lockBook");
        assertGt(handler.cClose(), 0, "rollClose");
        assertGt(handler.cComplete(), 0, "completeRedeem");
        assertGt(handler.cClaim(), 0, "claimUsdg");
        assertGt(handler.cRedeem(), 0, "instant redeem");
        assertGt(handler.cAssignedCycles(), 0, "a cycle closed with an assignment");
        assertGt(handler.cThirdPartyWrite(), 0, "thirdPartyWrite");

        // And the invariants still hold at the end of it.
        _assertAllInvariants();
    }

    /// @dev The issuer toggles roll a hash of their seed ({VaultHandler._roll}), so a deterministic
    ///      test walks seeds until the state it wants is reached; each miss is a counted skip and
    ///      nothing else.
    function _setUsdgPause(bool want) internal {
        for (uint256 s; usdg.paused() != want; s++) {
            handler.toggleUsdgPause(s);
        }
    }

    function _setNvdaBlock(bool want) internal {
        for (uint256 s; nvda.isBlocked(address(vault)) != want; s++) {
            handler.toggleNvdaBlock(s);
        }
    }

    function _assertAllInvariants() internal view {
        invariant_assetConservation();
        invariant_usdgBooksBalance();
        invariant_usdgHolderSolvency();
        invariant_shareAccounting();
        invariant_noFreeShares();
        invariant_reservesAreReal();
        invariant_phaseSanity();
        invariant_feeNeverTouchesStrikeProceeds();
        invariant_depositGateTracksTheReserve();
        invariant_strandSharesAreConserved();
        invariant_vaultHoldsNoOptionTokens();
        invariant_assignedNeverExceedsSold();
        invariant_longSupplyIsUnexercisedCollateral();
    }

    /// @notice Proves the handler reaches a stranded close (F-02), the queue paying its idle slice
    ///         with the USDG leg deferred under the pause (F-03), a retry refused `StillStranded`, the
    ///         claim redeemed by a stranger and the epoch paid its share, with every invariant holding
    ///         at each step.
    function test_handlerReachesAStrandAndRecovers() public {
        handler.deposit(0, type(uint256).max); // alice, 6e18
        handler.deposit(1, type(uint256).max); // bob, 6e18
        handler.rollOpen(0, 0);
        handler.approveListing(type(uint256).max, 0, 0);
        handler.fill(type(uint256).max); // the whole listing
        handler.queueRedeem(1, type(uint256).max); // bob queues everything, into the escrow that earns the week
        handler.exercise(0, 0); // one contract assigned: the claim now holds strike USDG
        assertGt(vault.claimedExerciseProceeds(), 0, "assigned");
        handler.lockBook(0);
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);

        // Paxos pauses USDG before the close: Valorem's redeem cannot push the strike to the vault.
        _setUsdgPause(true);
        assertTrue(usdg.paused(), "USDG paused");
        uint256 key = vault.claimKey();
        handler.rollClose(1); // a stranger, an hour after expiry
        assertEq(handler.cStrands(), 1, "the close stranded the claim");
        assertTrue(vault.isStranded(), "stranded");
        assertEq(vault.claimKey(), key, "claim kept");
        assertGt(vault.epochStrandWad(1), 0, "bob's epoch owns a share of the claim");
        assertEq(vault.maxDeposit(alice), 0, "deposits shut");
        handler.deposit(2, type(uint256).max); // carol: skipped, not reverted
        assertEq(handler.cDeposit(), 2, "no deposit landed while stranded");
        handler.rollOpen(0, 0); // skipped: StillStranded
        assertEq(handler.cOpen(), 1, "no cycle opened over the stranded claim");
        _assertAllInvariants();

        // Bob collects his idle slice now; his escrow USDG is deferred by the pause and stays booked.
        handler.completeRedeem(1);
        assertEq(handler.cComplete(), 1, "bob collected");
        assertEq(handler.cDeferredUsdgLegs(), 1, "his USDG leg was deferred");
        assertGt(vault.owedQueueUsdg(bob), 0, "and is still owed");
        assertGt(vault.owedStrandWad(bob), 0, "his share of the claim is staged");
        handler.completeRedeem(1); // skipped: only a blocked USDG leg and an unredeemed share left
        assertEq(handler.cComplete(), 1);
        _assertAllInvariants();

        // A retry under the pause is refused; lifting the pause lets a stranger redeem the claim.
        handler.retryStrandedClaim(0);
        assertEq(handler.cRetriesRefused(), 1, "refused StillStranded");
        assertTrue(vault.isStranded(), "still stranded");
        _setUsdgPause(false);
        assertFalse(usdg.paused(), "USDG unpaused");
        handler.retryStrandedClaim(1);
        assertEq(handler.cRetries(), 1, "the claim was redeemed");
        assertFalse(vault.isStranded(), "resolved");
        assertTrue(vault.canRedeemInstantly(), "flat again");
        assertGt(handler.strandAssetsLeft(), 0, "bob's share of the redeem waits in the reserve");
        _assertAllInvariants();

        // Bob collects his share of the claim and his deferred USDG; the generation drains to zero.
        handler.completeRedeem(1);
        assertEq(handler.cComplete(), 2, "bob collected again");
        assertEq(handler.strandAssetsLeft(), 0, "the generation's NVDA is fully collected");
        assertEq(handler.strandUsdgLeft(), 0, "and its USDG");
        assertEq(vault.owedQueueUsdg(bob), 0, "the deferred USDG leg was paid");
        assertEq(vault.owedStrandWad(bob), 0, "no share left staged");

        // Deposits reopen and a fresh cycle can start.
        handler.deposit(2, type(uint256).max);
        assertEq(handler.cDeposit(), 3, "carol's deposit lands now");
        handler.rollOpen(0, 0);
        assertEq(handler.cOpen(), 2, "a new cycle opened");

        assertEq(handler.revertedCalls(), 0, "no handler call should have reverted");
        _assertAllInvariants();
    }

    /// @notice Proves the NVDA-side strand: the vault blocklisted on the Stock Token in an unassigned
    ///         week strands the close (the redeem's NVDA leg is refused), the queue's idle slice waits
    ///         with the claim share because nothing can pay NVDA, and both pay once the block lifts.
    function test_handlerReachesANvdaBlocklistStrand() public {
        handler.deposit(0, type(uint256).max);
        handler.deposit(1, type(uint256).max);
        // Arming locks nothing under write on fill: the collateral the redeem has to push back is
        // whatever a fill wrote, so sell (and write) part of the listing first.
        handler.rollOpen(0, 0);
        handler.approveListing(type(uint256).max, 0, 0);
        handler.fill(1);
        assertGt(vault.lockedAssets(), 0, "a fill locked collateral");
        handler.queueRedeem(1, type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);

        _setNvdaBlock(true);
        assertTrue(nvda.isBlocked(address(vault)), "vault blocklisted on NVDA");
        handler.rollClose(1);
        assertEq(handler.cStrands(), 1, "an unassigned week strands on the NVDA leg");
        assertGt(vault.lockedAssets(), 0, "the collateral is still in Valorem");
        handler.completeRedeem(1); // skipped: the asset leg cannot move
        assertEq(handler.cComplete(), 0, "nothing paid while the vault is blocked");
        handler.retryStrandedClaim(0);
        assertEq(handler.cRetriesRefused(), 1);
        _assertAllInvariants();

        _setNvdaBlock(false);
        handler.retryStrandedClaim(0);
        assertEq(handler.cRetries(), 1, "redeemed once unblocked");
        (, uint256 usdgIn,,,) = vault.strands(1);
        assertEq(usdgIn, 0, "no USDG leg on an unassigned week");
        handler.completeRedeem(1);
        assertEq(handler.cComplete(), 1, "bob paid idle slice plus claim share");
        assertEq(handler.strandAssetsLeft(), 0, "the generation drained");
        assertEq(handler.revertedCalls(), 0, "no handler call should have reverted");
        _assertAllInvariants();
    }

    /// @notice Proves the handler reaches an issuer burn that unbacks the reserve, the shut deposit
    ///         gate that follows, and a haircut redemption, with every invariant holding throughout.
    function test_handlerReachesABurnShortfallAndTheHaircut() public {
        handler.deposit(0, type(uint256).max); // alice, 6e18
        handler.deposit(1, type(uint256).max); // bob, 6e18

        // The handler refuses to burn before the run has closed a cycle, so run one OTM week first.
        handler.rollOpen(0, 0);
        handler.approveListing(0, 0, 0);
        handler.fill(0); // one contract
        handler.adminBurn(0, 1e18);
        assertEq(handler.cBurn(), 0, "no burn before the first close");
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.rollClose(1);
        assertEq(handler.cClose(), 1, "first cycle closed");
        assertEq(nvda.balanceOf(address(vault)), 12e18, "collateral back, nothing assigned");

        handler.queueRedeem(0, type(uint256).max); // alice queues everything
        handler.settleQueue(0);
        assertEq(vault.reservedAssets(), 6e18, "half the book is reserved");

        // Burn three quarters of the balance: the reserve (half) is now unbacked.
        uint256 bal = nvda.balanceOf(address(vault));
        handler.adminBurn(0, (bal * 3) / 4);
        assertEq(handler.cBurn(), 1, "adminBurn");
        assertEq(handler.cBurnShortfalls(), 1, "the burn unbacked the reserve");
        assertLt(nvda.balanceOf(address(vault)), vault.reservedAssets(), "balance < reserved");
        assertEq(vault.maxDeposit(alice), 0, "deposits shut");
        handler.deposit(2, type(uint256).max); // carol: skipped, not reverted
        assertEq(handler.cDeposit(), 2, "no deposit landed while the reserve was unbacked");
        invariant_assetConservation();
        invariant_noFreeShares();
        invariant_reservesAreReal();
        invariant_depositGateTracksTheReserve();

        // alice collects: paid the haircut, reserve released in full, the vault's gate reopens.
        handler.completeRedeem(0);
        assertEq(handler.cHaircuts(), 1, "haircut redemption");
        assertEq(vault.reservedAssets(), 0, "reserve fully released");
        assertGt(vault.maxDeposit(alice), 0, "deposits reopen once the reserve is collected");
        // The burn took the whole book: alice's haircut payout drained the balance to zero while bob's
        // shares are still outstanding, so the vault is a dead book at a share price of zero. The VAULT
        // would accept carol's deposit (at one wei a share); the HANDLER refuses it, as a front end
        // would, see `_canDeposit`. Pinned both ways so neither side drifts silently.
        assertEq(nvda.balanceOf(address(vault)), 0, "the book is empty");
        assertGt(vault.totalSupply(), 0, "with shares outstanding");
        handler.deposit(2, type(uint256).max);
        assertEq(handler.cDeposit(), 2, "the handler does not deposit into a dead book");

        assertEq(handler.revertedCalls(), 0, "no handler call should have reverted");
        invariant_assetConservation();
        invariant_usdgBooksBalance();
        invariant_shareAccounting();
        invariant_noFreeShares();
        invariant_reservesAreReal();
        invariant_phaseSanity();
        invariant_depositGateTracksTheReserve();
    }

    /// @notice Proves the handler reaches the F-01 adversary (a third-party write and exercise into
    ///         the vault's bucket) with the vault assigned on no more than it sold, and a queue settled
    ///         while flat.
    function test_handlerReachesTheThirdPartyBucketAndFlatSettlement() public {
        handler.deposit(0, type(uint256).max);
        handler.deposit(1, type(uint256).max);
        handler.rollOpen(0, 0);
        handler.approveListing(0, 0, 0); // priced on the floor at $215 spot
        handler.fill(1); // the vault sells (and writes) a fraction
        uint256 sold = vault.contractsWritten();
        assertGt(sold, 0, "fill");

        handler.thirdPartyWrite(type(uint256).max); // 40 contracts into the same bucket
        assertGt(handler.cThirdPartyWrite(), 0, "thirdPartyWrite");
        handler.thirdPartyExercise(type(uint256).max, 0); // and exercises them all
        assertGt(handler.cThirdPartyExercise(), 0, "thirdPartyExercise");
        assertLe(vault.contractsAssigned(), sold, "assigned on at most what was sold");
        assertGt(handler.totalAssignedOut(), 0, "the vault was assigned pro rata in its bucket");
        assertEq(mockClear.balanceOf(address(vault), vault.optionId()), 0, "no inventory");

        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.warpAhead(type(uint256).max);
        handler.rollClose(1);
        assertEq(uint8(vault.phase()), 0, "should be back to Idle");

        handler.queueRedeem(0, 1);
        handler.settleQueue(0);
        assertGt(handler.cSettleQueue(), 0, "settleQueue");
        handler.completeRedeem(0);
        assertGt(handler.cComplete(), 0, "completeRedeem after a flat settlement");
        assertEq(handler.revertedCalls(), 0, "no handler call should have reverted");

        invariant_assetConservation();
        invariant_usdgBooksBalance();
        invariant_reservesAreReal();
        invariant_phaseSanity();
        invariant_vaultHoldsNoOptionTokens();
    }

    /// @notice The redeem queue takes a whole position, which is what the handler assumes
    ///         when it bounds `queueRedeem` by the full balance.
    /// @dev Pinned because an earlier revision escrowed the shares AND subtracted
    ///      `queuedSharesOf` from the owner's balance in `_update`, which double counted them
    ///      and made queueing more than half a position impossible. That is the one exit a
    ///      holder has while a call is open, so it is worth a standing test.
    function test_queueRedeemTakesTheWholePosition() public {
        _deposit(alice, 10e18);

        vm.prank(alice);
        uint256 epoch = vault.queueRedeem(10e18);

        assertEq(epoch, 1, "queued into the live epoch");
        assertEq(vault.balanceOf(alice), 0, "alice holds nothing now");
        assertEq(vault.balanceOf(address(vault)), 10e18, "escrow holds it all");
        assertEq(vault.queuedShares(), 10e18, "and the queue agrees");
        assertEq(vault.queuedSharesOf(alice), 10e18, "alice is down for all ten");
    }

    /// @notice The accrual index's floor drift, found by this suite and pinned here.
    /// @dev {Distributor} credits `totalUsdgDistributed` with a floor taken PER DISTRIBUTION,
    ///      but a holder who does not touch their shares between two distributions accrues on
    ///      the COMBINED index delta, floored once. floor(b*(d1+d2)/A) can be one base unit more
    ///      than floor(b*d1/A) + floor(b*d2/A), so lifetime claims can exceed lifetime credits.
    ///
    ///      That much is inherent to an index and is not going away. What used to make it
    ///      dangerous was `usdgOwed()`: a plain `totalUsdgDistributed - totalUsdgClaimed` that
    ///      `_accrueHarvest` read, so the first base unit of drift underflowed it and every
    ///      later `rollClose`, deposit and mint panicked — the collateral stuck in Valorem, the
    ///      queue unable to settle, instant redemption blocked by `contractsWritten != 0`.
    ///      The harvest is anchored on the measured `usdgAccounted` checkpoint now and
    ///      `usdgOwed()` saturates and is read by nothing in the money path, so the drift costs
    ///      dust and nothing else; {test_accrualDriftCostsDustAndNothingElse} states that.
    ///
    ///      The numbers below are the shrunk counterexample from the invariant run, replayed
    ///      straight against the vault. Shared by the test that pins the drift's present shape
    ///      and by the test that states what it is allowed to cost.
    function _replayAccrualDrift() internal returns (uint256 claims, uint256 credited) {
        // Awkward, non-round share counts are the point: the drift is a rounding artefact.
        _deposit(carol, 1_496_804_350_505_375_910);

        uint256 optionId = optionIds[RUNG_MID];
        vm.prank(keeper);
        vault.rollOpen(optionId);

        // $4.201220 for one contract, ONE consideration item: the exact figure the vault netted under
        // the old two-item order at $4.422336, so the hand-checked drift below is unchanged. The
        // premium does not divide evenly into the supply, which is what makes the index rounding
        // observable.
        OrderComponents memory c = _approveListing(optionId, 1, 4_201_220);
        _fill(c, 1);
        assertEq(usdg.balanceOf(address(vault)), 4_201_220, "premium landed");

        // Distribution 1: the deposit checkpoints the premium while carol is the only holder, so
        // bob gets none of it. This deposit has to land BEFORE the exercise window opens —
        // deposits are closed from `cycleExerciseTs` onward, because once a contract can be
        // assigned the NAV falls while the offsetting strike USDG is still stuck in the Valorem
        // claim, and pricing new shares against that gap is a theft from the assigned holders.
        _deposit(bob, 907_670_442_937_483_625);

        _warpToExercise();
        _exercise(optionId, 1); // fully assigned: collateral out, strike proceeds in

        // Distribution 2: the close harvests the 236 USDG of strike proceeds, with both holders.
        _warpToExpiry();
        _rollClose();

        claims = vault.claimableUsdg(bob) + vault.claimableUsdg(carol);
        credited = vault.totalUsdgDistributed();
    }

    /// @notice The drift in the shape it actually has today. This test is the alarm that goes
    ///         off when somebody changes it: the moment claims stop outrunning credits it fails,
    ///         and a plain `assertLe(claims, credited)` is what should replace it.
    function test_accrualIndexCanPromiseMoreUsdgThanItCredited() public {
        (uint256 claims, uint256 credited) = _replayAccrualDrift();

        // Present-day behaviour, asserted unconditionally. An earlier draft wrapped the whole
        // second half in `if (claims <= credited) return;` so it would still pass once the bug
        // was fixed — which also meant a single silent `return` could turn the entire test into
        // a no-op without anyone noticing. A test that pins a bug has to fail when the bug goes.
        assertEq(claims, credited + 1, "claims outrun credits by exactly the rounding unit");
        assertEq(claims, usdg.balanceOf(address(vault)), "and they eat the retained dust too");

        vm.prank(bob);
        vault.claimUsdg();
        vm.prank(carol);
        vault.claimUsdg();
        assertEq(usdg.balanceOf(address(vault)), 0, "the vault is now empty");
        assertGt(vault.totalUsdgClaimed(), vault.totalUsdgDistributed(), "claimed more than credited");

        // The lifetime books are now underwater and stay that way. `usdgOwed()` saturates to
        // zero rather than reporting a negative liability, which is what keeps the vault
        // usable; it does NOT mean the promise was kept. Nothing ever restores the base unit.
        assertEq(vault.usdgOwed(), 0, "usdgOwed saturates rather than reporting the deficit");

        // The vault is not bricked by this any more — deposits and a whole further cycle still
        // work — so the damage shows up as money, not as a wedge: see
        // {test_settledRedeemerIsAlwaysPayable}, where the same rounding used to leave a settled
        // redeemer unable to collect their principal.
        _deposit(alice, 1e18);

        _nextWeek();
        _rollOpen(); // armed, listed to nobody: an unsold week distributes nothing
        _warpToExpiry();
        _rollClose();
        assertEq(_phase(), 0, "the cycle still closes: the underflow brick has been fixed");
        assertGt(vault.totalUsdgClaimed(), vault.totalUsdgDistributed(), "but the deficit is permanent");
    }

    /// @dev The bookkeeping counter `totalUsdgDistributed` genuinely CANNOT equal the sum of
    ///      what accounts can claim, and that is inherent to an index rather than a bug.
    ///      `_distributeUsdg` credits a per-distribution floor, while `_pending` floors once
    ///      over the combined delta since an account last settled, and
    ///      floor(b*(d1+d2)/A) >= floor(b*d1/A) + floor(b*d2/A). A holder who sits through two
    ///      distributions without touching their shares therefore accrues up to a base unit
    ///      more than was recorded as credited.
    ///
    ///      What must hold is not the counter identity but SOLVENCY: the vault can always pay
    ///      everyone it owes, and nothing reverts. Both are true because every USDG payout is
    ///      clamped to {Vault._usdgAvailableForHolders} and `usdgOwed()` saturates instead of
    ///      underflowing. The drift costs at most a few base units of unclaimed dust; it can
    ///      never strand principal or brick a roll, which is what the old version did.
    function test_accrualDriftCostsDustAndNothingElse() public {
        (uint256 claims, uint256 credited) = _replayAccrualDrift();

        // The drift is real, tiny, and bounded.
        if (claims > credited) {
            assertLe(claims - credited, 16, "the drift is base units, not a leak");
        }

        // It never underflows, whichever way it went.
        assertLe(vault.usdgOwed(), usdg.balanceOf(address(vault)), "owed is never more than held");

        // Every real obligation is fully backed.
        assertLe(
            vault.usdgReservedForQueue() + vault.pendingFeeUsdg(),
            usdg.balanceOf(address(vault)),
            "the queue reserve and the accrued fee are both backed"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    MONEY MATHS, WORKED BY HAND
    //////////////////////////////////////////////////////////////*/

    /// @notice One clean cycle, every USDG base unit accounted for by hand.
    /// @dev Written out in full so a reader can check the fixture instead of trusting it.
    ///
    ///      alice deposits 10e18 -> 10e18 shares (first deposit, 1:1).
    ///      arm the 231 rung, list 3 at $1.90 and sell all 3, which writes 3:
    ///        utilization cap = 10e18 * 9_500 / 10_000 / 1e18 = 9 contracts, so 3 is legal;
    ///        collateral locked = 3 * 1e18 = 3e18, leaving 7e18 idle.
    ///        consideration to the vault = 1_900_000 * 3 = 5_700_000, and the policy floor is
    ///          220_000_000 * 3 * 40 / 10_000 = 2_640_000  -> clears it.
    ///      Nobody exercises, so at rollClose the claim returns all 3e18 and no strike proceeds.
    ///      Harvest: balance 5_700_000, nothing committed, so gross = 5_700_000, all premium
    ///      (no assignment, so nothing fee-free).
    ///        protocol fee = 5_700_000 * 500 / 10_000          =   285_000
    ///        net to holders                                   = 5_415_000
    ///      Index: delta = 5_415_000 * 1e27 / 10e18 = 5.415e14, and 5.415e14 * 10e18 / 1e27
    ///        = 5_415_000 exactly, so usdgDust stays 0.
    ///      alice's accrual = 10e18 * 5.415e14 / 1e27           = 5_415_000.
    ///      And the share price does not move: 10e18 assets still back 10e18 shares.
    function test_premiumHarvestSplitsToTheBaseUnit() public {
        _deposit(alice, 10e18);
        assertEq(vault.balanceOf(alice), 10e18, "first deposit mints one for one");

        _openAndSell(3);
        assertEq(vault.lockedAssets(), 3e18, "three lots locked in Valorem by the fill");
        assertEq(vault.idleAssets(), 7e18, "seven lots left idle");
        assertEq(usdg.balanceOf(address(vault)), 5_700_000, "the premium, all of it the vault's");

        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        assertEq(nvda.balanceOf(address(vault)), 10e18, "all collateral came back: nobody exercised");
        assertEq(usdg.balanceOf(feeSafe), 285_000, "protocol fee is 5% of the premium harvested");
        assertEq(usdg.balanceOf(address(vault)), 5_415_000, "and the rest stays for holders");
        assertEq(vault.totalUsdgDistributed(), 5_415_000, "credited in full");
        assertEq(vault.usdgDust(), 0, "5_415_000 over 10e18 shares indexes exactly");
        assertEq(vault.claimableUsdg(alice), 5_415_000, "alice can claim every cent of it");

        // USDG is NOT part of the share price: 10e18 of asset still backs 10e18 of shares.
        assertEq(vault.totalAssets(), 10e18, "share backing unchanged by the premium");
        assertEq(vault.convertToAssets(1e18), 1e18, "share price unmoved");

        vm.prank(alice);
        uint256 claimed = vault.claimUsdg();
        assertEq(claimed, 5_415_000, "claim pays the accrual exactly");
        assertEq(usdg.balanceOf(address(vault)), 0, "vault is flat on USDG");
        assertEq(vault.usdgOwed(), 0, "and owes nobody anything");
    }

    /// @notice A settled epoch drains to EXACTLY zero, with deliberately awkward numbers.
    /// @dev The spec promises the last claimant of an epoch takes precisely what remains, so
    ///      there is zero dust. Round numbers would prove nothing — every division would be
    ///      exact — so the deposits, the queued amounts and the assignment are all chosen to
    ///      make every division lossy. carol queues three wei of shares on purpose: she is the
    ///      last claimant, and she is the one who has to absorb the remainder.
    ///
    ///      HAND CHECK.
    ///        supply  = 7_777_777_777_777_777_777 + 3_333_333_333_333_333_331
    ///                + 1_111_111_111_111_111_113 = 12_222_222_222_222_222_221  (all 1:1)
    ///        queued  = 5_000_000_000_000_000_001 + 1_000_000_000_000_000_007 + 3
    ///                =  6_000_000_000_000_000_011
    ///        3 contracts sold (and so written) on the 231 rung, 1 exercised, so at rollClose the
    ///        claim returns 2e18 of asset and 231_000_000 of strike proceeds:
    ///          asset balance = 12_222_222_222_222_222_221 - 3e18 + 2e18
    ///                        = 11_222_222_222_222_222_221
    ///        payoutAssets, priced like instant redeem (virtual share included):
    ///                       6_000_000_000_000_000_011 * (11_222_222_222_222_222_221 + 1)
    ///                       / (12_222_222_222_222_222_221 + 1) = 5_509_090_909_090_909_101
    ///        USDG: premium 5_700_000 + strike 231_000_000 = 236_700_000 gross. The strike
    ///          proceeds are fee-free, so fee = 5_700_000 * 500 / 10_000 = 285_000 (5% of the
    ///          premium only), net = 236_700_000 - 285_000 = 236_415_000. Indexed over the
    ///          pre-burn supply:
    ///          delta = 236_415_000 * 1e27 / 12_222_222_222_222_222_221 = 19_343_045_454_545_454
    ///          credited = delta * 12_222_222_222_222_222_221 / 1e27 = 236_414_999, so exactly
    ///          one base unit stays behind as usdgDust.
    ///        Escrow accrual (the queue's own share of the week it sat through):
    ///          6_000_000_000_000_000_011 * 19_343_045_454_545_454 / 1e27 = 116_058_272.
    ///        USDG drawdown of that accrual, same order:
    ///          alice 116_058_272 * 5_000_000_000_000_000_001 / 6_000_000_000_000_000_011
    ///                                              =  96_715_226
    ///          bob   19_343_046 * 1_000_000_000_000_000_007 / 1_000_000_000_000_000_010
    ///                                              =  19_343_045
    ///          carol, last, takes the remainder    =           1
    ///        Drawdown, in order alice / bob / carol:
    ///          alice 5_509_090_909_090_909_101 * 5_000_000_000_000_000_001
    ///                / 6_000_000_000_000_000_011 = 4_590_909_090_909_090_910
    ///          bob                                 =   918_181_818_181_818_188
    ///          carol, last, takes the remainder    =                         3
    ///          4_590_909_090_909_090_910 + 918_181_818_181_818_188 + 3
    ///                                              = 5_509_090_909_090_909_101. Nothing left.
    function test_queueEpochDrawsDownToZeroDust() public {
        uint256 aDep = 7_777_777_777_777_777_777;
        uint256 bDep = 3_333_333_333_333_333_331;
        uint256 cDep = 1_111_111_111_111_111_113;
        _deposit(alice, aDep);
        _deposit(bob, bDep);
        _deposit(carol, cDep);

        uint256 supply = aDep + bDep + cDep;
        assertEq(vault.totalSupply(), supply, "deposits mint one for one while assets == shares");
        assertEq(supply, 12_222_222_222_222_222_221, "hand-checked supply");

        (uint256 optionId,) = _openAndSell(3);

        uint256 aQ = 5_000_000_000_000_000_001;
        uint256 bQ = 1_000_000_000_000_000_007;
        uint256 cQ = 3;
        vm.prank(alice);
        vault.queueRedeem(aQ);
        vm.prank(bob);
        vault.queueRedeem(bQ);
        vm.prank(carol);
        vault.queueRedeem(cQ);
        assertEq(vault.queuedShares(), 6_000_000_000_000_000_011, "hand-checked escrow");

        _warpToExercise();
        _exercise(optionId, 1); // one of the three is assigned
        vault.lockBook();
        _warpToExpiry();
        _rollClose();

        assertEq(nvda.balanceOf(address(vault)), 11_222_222_222_222_222_221, "2e18 back, 1e18 assigned away");
        assertEq(vault.reservedAssets(), 5_509_090_909_090_909_101, "hand-checked epoch reserve");

        assertEq(usdg.balanceOf(feeSafe), 285_000, "protocol fee: 5% of the 5_700_000 premium, none of the strike");
        assertEq(vault.totalUsdgDistributed(), 236_414_999, "hand-checked credit");
        assertEq(vault.usdgDust(), 1, "the one base unit the index could not represent");

        uint256 reservedUsdg = vault.usdgReservedForQueue();
        assertEq(reservedUsdg, 116_058_272, "hand-checked escrow accrual, paid with the redemption");

        // Drain the epoch. The order matters: carol goes last with three wei of shares.
        vm.prank(alice);
        (uint256 aOut, uint256 aUsdg) = vault.completeRedeem(alice);
        vm.prank(bob);
        (uint256 bOut, uint256 bUsdg) = vault.completeRedeem(bob);
        vm.prank(carol);
        (uint256 cOut, uint256 cUsdg) = vault.completeRedeem(carol);

        assertEq(aOut, 4_590_909_090_909_090_910, "alice's pro-rata slice");
        assertEq(bOut, 918_181_818_181_818_188, "bob's pro-rata slice");
        assertEq(cOut, 3, "carol, last, takes exactly what is left");
        assertEq(aOut + bOut + cOut, 5_509_090_909_090_909_101, "the epoch paid out every base unit");
        // USDG is paid per entry by the index growth each entry's shares sat through in escrow
        // (all three queued at index 0, settled at 19_343_045_454_545_454): floor(shares * index / 1e27).
        // alice 96_715_227.27 -> 96_715_227; bob 19_343_045.59 -> 19_343_045; carol, last, takes the
        // remainder 116_058_272 - 96_715_227 - 19_343_045 = 0, which is also her own floor (0.058).
        assertEq(aUsdg, 96_715_227, "alice: floor of her shares' index growth");
        assertEq(bUsdg, 19_343_045, "bob: floor of his shares' index growth");
        assertEq(cUsdg, 0, "carol's three wei of shares earned 0.058 of a base unit, and the remainder is 0");
        assertEq(aUsdg + bUsdg + cUsdg, reservedUsdg, "and every base unit of the escrow's USDG");

        // ZERO DUST: nothing is stranded in the epoch or in the reserves.
        assertEq(vault.reservedAssets(), 0, "no asset stranded in the settled epoch");
        assertEq(vault.usdgReservedForQueue(), 0, "no USDG stranded in the settled epoch");
        assertEq(vault.queuedSharesOf(carol), 0, "carol's queue slot is closed");

        // And the invariants still hold after an awkward, fully drained settlement. The fee
        // bound is stated against the 5_700_000 of premium this test filled by hand, since the
        // handler's ghost never saw it; 285_000 * 10_000 == 5_700_000 * 500, so it holds with
        // equality while 231_000_000 of strike proceeds went through the same harvest.
        invariant_usdgBooksBalance();
        invariant_shareAccounting();
        invariant_noFreeShares();
        invariant_reservesAreReal();
        invariant_phaseSanity();
        _assertFeeBoundedByPremium(5_700_000);
    }

    /*//////////////////////////////////////////////////////////////
              REGRESSION: THE WORST BUG THIS SUITE FOUND
    //////////////////////////////////////////////////////////////*/

    /// @dev The fourteen handler calls the fuzzer shrunk the failure down to, replayed verbatim.
    ///      `bound` is a pure function of its input, the handler pranks internally and nothing
    ///      here reads the clock except through the handler, so this is deterministic — the
    ///      assertions below re-derive the state from the vault rather than hard-coding it, so
    ///      the sequence stays a regression rather than a set of magic numbers. To re-derive it
    ///      against a changed contract: delete `cache/invariant/failures`, run the suite on
    ///      random seeds until a settled redeemer cannot collect, and read the shrunk sequence
    ///      out of the failure report.
    function _replayShrunkShortfallSequence() internal {
        handler.mintShares(392018837125427104589832581607, 4);
        handler.deposit(2123574579, 1000);
        handler.rollOpen(3, 16562);
        handler.queueRedeem(3, 10741306253717019503541772419713936945217196400975256642973503555);
        handler.approveListing(
            348, 279844674491765041288496783162929638129721525479985, 650711817032216429628102352962173952670641
        );
        handler.fill(32637446685991744264379122460653);
        handler.mintShares(24476585496062179696709759171091744378599999466504950159849712970183344084312, 1982);
        handler.fill(153419026);
        handler.exercise(
            48124957246106480306235023949874390304587076,
            7743437068904103131174173665968876251252891696163917313290615751511333927
        );
        handler.warpAhead(300000);
        handler.deposit(5700000, 87148635);
        handler.rollClose(724285949212773832774497895598021670763805165742501167211872204012875);
        handler.claimUsdg(11253);
    }

    /// @notice REGRESSION for the worst bug this suite found: a settled redeemer's PRINCIPAL
    ///         being held hostage by a one-base-unit USDG shortfall.
    /// @dev {Distributor}'s index floors once per distribution, while an account's pending
    ///      accrual floors once over the combined delta since it last settled, and
    ///      floor(b*(d1+d2)) >= floor(b*d1) + floor(b*d2). So the sum of everyone's accrual can
    ///      sit a base unit above the sum of what was ever distributed.
    ///
    ///      `_settleQueue` reserved the escrow's accrual straight out of that index, so
    ///      `usdgReservedForQueue` could exceed the USDG the vault actually held. Because
    ///      `_completeRedeem` pays the asset leg and the USDG leg in the same call, that
    ///      one-unit short transfer reverted the WHOLE redemption and took 6.6 NVDA of
    ///      principal down with it. Observed exactly:
    ///        usdgReservedForQueue  130_145_448   reserved
    ///        usdg.balanceOf(vault) 130_145_447   held, short by one
    ///
    ///      Fixed by clamping every USDG payout to what the vault can actually back
    ///      ({Distributor._claimUsdg}, {Distributor._takeAccrued}, and
    ///      {Vault._usdgAvailableForHolders}, which excludes the queue reserve and the pending
    ///      fee). The drift now costs at most one base unit of unpaid dust to the last
    ///      claimant instead of stranding somebody's collateral.
    function test_settledRedeemerIsAlwaysPayable() public {
        _replayShrunkShortfallSequence();

        uint256 held = usdg.balanceOf(address(vault));
        uint256 reserved = vault.usdgReservedForQueue();
        assertLe(reserved, held, "the queue reserve is never more than the vault holds");

        // Alice's epoch has settled, so she is entitled to collect right now. Derived from the
        // vault rather than hard-coded: the sequence is a regression for the PROPERTY, and
        // pinning "epoch 1" would make it fail for a harmless change in how many times the
        // queue happened to settle along the way.
        uint256 aliceEpoch = vault.queuedEpochOf(alice);
        assertGt(vault.queuedSharesOf(alice), 0, "alice is sitting in the queue");
        assertLt(aliceEpoch, vault.epochId(), "and the epoch she queued into has settled");

        (uint256 dueAssets, uint256 dueUsdg) = vault.previewCompleteRedeem(alice);
        assertGt(dueAssets, 6e18, "there is real principal behind the queued position");
        assertGt(dueUsdg, 0, "and a USDG leg that has to move in the same call");

        uint256 aliceAssetsBefore = nvda.balanceOf(alice);

        // The redemption goes through on the first attempt. No donation, no rescue.
        vm.prank(alice);
        (uint256 gotAssets, uint256 gotUsdg) = vault.completeRedeem(alice);

        assertEq(gotAssets, dueAssets, "principal paid in full");
        assertEq(gotUsdg, dueUsdg, "USDG leg paid in full");
        assertEq(nvda.balanceOf(alice), aliceAssetsBefore + dueAssets, "and it actually reached her");
        assertEq(vault.reservedAssets(), 0, "the asset reserve is emptied");
        assertEq(vault.usdgReservedForQueue(), 0, "and so is the USDG reserve");
    }

    /// @notice A holder who queues again can still collect money that has already settled.
    /// @dev REGRESSION GUARD, and it is guarding a hazard this suite walked into. `queueRedeem`
    ///      folds an older settled entry into `owedAssets` / `owedQueueUsdg` instead of paying it
    ///      out — deliberate, so a frozen Stock Token cannot stop a holder from queueing. The
    ///      trap is that the holder then has a LIVE entry in the current epoch, and a
    ///      `_completeRedeem` that settled the queue entry unconditionally would revert with
    ///      `EpochNotSettled` and never reach `_payoutOwed`. Finished money from a closed epoch
    ///      would be locked for another whole cycle by the act of queueing again.
    ///
    ///      `_completeRedeem` now settles the entry only when its epoch has closed and pays the
    ///      staged balance either way. This test is what stops that from being undone.
    function test_reQueuingDoesNotLockAlreadySettledMoney() public {
        _deposit(alice, 10e18);
        _deposit(bob, 10e18);

        // Epoch 1: alice queues four shares and the cycle closes, settling them.
        vm.prank(alice);
        vault.queueRedeem(4e18);
        _fullCycleOtm(3, _okUnitPrice());
        assertEq(vault.epochId(), 2, "epoch 1 has settled");

        (uint256 dueAssets, uint256 dueUsdg) = vault.previewCompleteRedeem(alice);
        assertGt(dueAssets, 0, "alice is owed her epoch-1 principal right now");

        // She queues again before collecting. The settled money is staged, not paid.
        vm.prank(alice);
        vault.queueRedeem(1e18);
        assertEq(vault.owedAssets(alice), dueAssets, "epoch-1 assets staged");
        assertEq(vault.owedQueueUsdg(alice), dueUsdg, "epoch-1 USDG staged");
        assertEq(vault.queuedEpochOf(alice), 2, "and she is queued again, into the live epoch");
        assertEq(vault.queuedSharesOf(alice), 1e18, "with the new entry");

        // THE POINT: the live entry must not hold the settled money hostage.
        uint256 aliceBefore = nvda.balanceOf(alice);
        vm.prank(alice);
        (uint256 paidAssets, uint256 paidUsdg) = vault.completeRedeem(alice);
        assertEq(paidAssets, dueAssets, "the settled principal is paid in full, immediately");
        assertEq(paidUsdg, dueUsdg, "and the USDG with it");
        assertEq(nvda.balanceOf(alice), aliceBefore + dueAssets, "it really moved");

        // The new entry is untouched and still queued for the epoch that has not closed yet.
        assertEq(vault.queuedSharesOf(alice), 1e18, "the fresh entry survived the collection");
        assertEq(vault.queuedEpochOf(alice), 2, "still queued into the live epoch");
        assertEq(vault.owedAssets(alice), 0, "and nothing is left staged");
    }
}
