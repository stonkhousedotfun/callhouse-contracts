// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy} from "../../src/Policy.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockRegistry} from "../../src/mocks/MockRegistry.sol";
import {MockSeaport} from "../../src/mocks/MockSeaport.sol";
import {MockFeed} from "../../src/mocks/MockFeed.sol";
import {OrderComponents, OfferItem, ConsiderationItem, ItemType, OrderType} from "../../src/interfaces/ISeaport.sol";

/// @notice Drives the vault through random but LEGAL sequences: deposits, mints, instant
///         redemptions, share transfers, the redeem queue, USDG claims, and full roll cycles
///         (open, list, partial fill, partial assignment, lock, close) across many weeks.
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
    MockRegistry internal immutable registry;
    MockSeaport internal immutable seaport;
    MockFeed internal immutable feed;
    address internal immutable buyer;
    address internal immutable overcallFee;
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
    /// @notice Asset base units handed to option buyers through assignment. Gone for good.
    uint256 public totalAssignedOut;

    /*//////////////////////////////////////////////////////////////
                  GHOST STATE FOR THE PROTOCOL FEE BOUND
    //////////////////////////////////////////////////////////////*/

    /// @notice Every fee-bearing USDG base unit that ever reached the vault: the vault's leg of
    ///         each successful Overcall fill, MEASURED as the vault's USDG balance delta across
    ///         the `fulfil` call rather than recomputed from the order.
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
    uint256 public cWriteMore;
    uint256 public cSettleQueue;
    uint256 public cStaleKill;

    /// @notice Cycles that ended with at least one contract assigned.
    uint256 public cAssignedCycles;

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
        MockRegistry registry_,
        MockSeaport seaport_,
        MockFeed feed_,
        address buyer_,
        address overcallFee_,
        address admin_,
        address guardian_,
        address[3] memory actors_
    ) {
        vault = vault_;
        nvda = nvda_;
        usdg = usdg_;
        clear = clear_;
        registry = registry_;
        seaport = seaport_;
        feed = feed_;
        buyer = buyer_;
        overcallFee = overcallFee_;
        admin = admin_;
        guardian = guardian_;
        actors = actors_;

        strikes.push(226_000_000);
        strikes.push(231_000_000);
        strikes.push(236_000_000);
        strikes.push(241_000_000);
        strikes.push(246_000_000);

        // Standing approvals for the buyer so a fill or an exercise is never blocked on one.
        vm.startPrank(buyer_);
        usdg_.approve(address(seaport_), type(uint256).max);
        usdg_.approve(address(clear_), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        attempted++;
        if (!_canDeposit()) {
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
        if (!_canDeposit()) {
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
        if (!vault.canRedeemInstantly()) {
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
        if (!vault.canRedeemInstantly()) {
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
        bool staged = vault.owedAssets(who) != 0 || vault.owedQueueUsdg(who) != 0;
        // A live (unsettled) entry does NOT block collection of a staged balance; see
        // {VaultInvariantTest.test_reQueuingDoesNotLockAlreadySettledMoney}.
        if (!settledEntry && !staged) {
            _skip();
            return;
        }

        (uint256 dueAssets, uint256 dueUsdg) = vault.previewCompleteRedeem(who);
        uint256 before = nvda.balanceOf(address(vault));
        uint256 usdgBefore = usdg.balanceOf(address(vault));
        vm.prank(who);
        try vault.completeRedeem(who) returns (uint256 assets, uint256 usdgOut) {
            totalWithdrawn += assets;
            assertEq(assets, dueAssets, "previewCompleteRedeem quoted assets completeRedeem did not pay");
            assertEq(usdgOut, dueUsdg, "previewCompleteRedeem quoted USDG completeRedeem did not pay");
            assertEq(before - nvda.balanceOf(address(vault)), assets, "completeRedeem moved the wrong amount of asset");
            assertEq(usdgBefore - usdg.balanceOf(address(vault)), usdgOut, "completeRedeem moved the wrong USDG");
            // Nothing collectable may survive: no staged balance, and no SETTLED queue entry.
            // A live entry for an epoch that has not closed yet is allowed to remain — that is
            // the whole point of {VaultInvariantTest.test_reQueuingDoesNotLockAlreadySettledMoney}.
            assertEq(vault.owedAssets(who), 0, "staged assets survived a completed redemption");
            assertEq(vault.owedQueueUsdg(who), 0, "staged USDG survived a completed redemption");
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
        if (claimable == 0) {
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

    /*//////////////////////////////////////////////////////////////
                              THE WEEKLY ROLL
    //////////////////////////////////////////////////////////////*/

    function rollOpen(uint256 spotSeed, uint256 rungSeed, uint256 sizeSeed) external {
        attempted++;
        if (uint8(vault.phase()) != 0 || vault.writesHalted()) {
            _skip();
            return;
        }
        if (vault.idleAssets() < LOT) {
            _skip();
            return;
        }

        // A fresh cycle every week, exactly as the registry does it. New timestamps mean new
        // Valorem option ids, which keeps each cycle's claim isolated from the last one's.
        _installFreshCycle();

        uint256 spot = _refreshSpot(spotSeed);
        uint256 optionId = _pickRung(spot, rungSeed);
        if (optionId == 0) {
            _skip();
            return;
        }

        uint256 maxN = _maxContracts();
        if (maxN == 0) {
            _skip();
            return;
        }
        uint112 n = uint112(bound(sizeSeed, 1, maxN));

        try vault.rollOpen(optionId, n) {
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
        uint256 available = clear.balanceOf(address(vault), optionId);
        if (available == 0) {
            _skip();
            return;
        }

        // approveListing re-checks the band's lower bound at live spot, so keep spot at or below
        // the highest price whose band floor still admits the written strike.
        (uint16 minOtmBps,, uint16 minPremiumBps,,,) = vault.policy();
        uint256 maxSpot = (vault.cycleStrikeUsdg() * BPS) / (BPS + minOtmBps);
        if (maxSpot > 232_000_000) maxSpot = 232_000_000;
        uint256 spot = bound(spotSeed, maxSpot < 215_000_000 ? maxSpot : 215_000_000, maxSpot);
        feed.setAnswer(int256(spot * 100));
        uint256 amount = bound(amountSeed, 1, available);
        // Clear the 0.40%-of-spot floor per contract, and stay under the strike.
        uint256 floorUnit = (spot * minPremiumBps) / BPS + 1;
        uint256 unitPrice = bound(priceSeed, floorUnit, floorUnit * 6);
        // Slots count price CUTS. Once three are spent, only a listing at or above the lowest
        // price authorised this cycle is legal, so lift the price to it rather than skip. The
        // lowest cleared some earlier floor and the strike ceiling, and lifting a price that
        // already clears today's floor keeps it clear.
        if (vault.listingsThisCycle() >= 3 && unitPrice < vault.lowestListedUnitUsdg()) {
            unitPrice = vault.lowestListedUnitUsdg();
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

    /// @dev A tranche top-up of this cycle's claim. Spot is set INSIDE the band for the written
    ///      strike (one base unit clear of either edge), because the gate re-checks the band at
    ///      live spot and a random spot would mostly skip. Size is bounded on the claim's total.
    function writeMore(uint256 sizeSeed, uint256 spotSeed) external {
        attempted++;
        if (uint8(vault.phase()) != 1 || vault.writesHalted() || block.timestamp >= vault.cycleExerciseTs()) {
            _skip();
            return;
        }

        (uint16 minOtmBps, uint16 maxOtmBps,, uint16 util,, uint64 cap) = vault.policy();
        uint256 k = vault.cycleStrikeUsdg();
        uint256 spot = bound(spotSeed, (k * BPS) / (BPS + maxOtmBps) + 1, (k * BPS) / (BPS + minOtmBps) - 1);
        feed.setAnswer(int256(spot * 100));

        uint256 byUtil = ((vault.idleAssets() + vault.lockedAssets()) * util) / BPS / LOT;
        uint256 maxTotal = byUtil < cap ? byUtil : cap;
        uint256 written = vault.contractsWritten();
        if (maxTotal <= written) {
            _skip();
            return;
        }
        uint112 n = uint112(bound(sizeSeed, 1, maxTotal - written));

        uint256 key = vault.claimKey();
        uint256 total = vault.totalAssets();
        try vault.writeMore(n) {
            assertEq(vault.claimKey(), key, "a top-up opened a second claim");
            assertEq(vault.contractsWritten(), written + n, "contractsWritten did not accumulate");
            assertEq(vault.totalAssets(), total, "a top-up moved the share price");
            succeeded++;
            cWriteMore++;
        } catch (bytes memory err) {
            _reverted("writeMore", err);
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
        uint256 before = nvda.balanceOf(address(vault));
        vm.prank(address(uint160(uint256(keccak256(abi.encode(whoSeed, "settler"))))));
        try vault.settleQueue() {
            (uint256 sharesR, uint256 assetsR,) = vault.epochs(e);
            assertEq(sharesR, q, "the whole queue settled");
            assertEq(assetsR, expected, "settled at something other than the flat pro-rata slice");
            assertEq(vault.queuedShares(), 0, "queue not emptied");
            assertEq(nvda.balanceOf(address(vault)), before, "settleQueue moved asset");
            succeeded++;
            cSettleQueue++;
        } catch (bytes memory err) {
            _reverted("settleQueue", err);
        }
    }

    /// @dev A stranger kills a listing the policy would no longer authorise at a fresh spot.
    function invalidateStaleListing(uint256 spotSeed) external {
        attempted++;
        if (vault.listingHash() == bytes32(0)) {
            _skip();
            return;
        }
        uint256 spot = _refreshSpot(spotSeed);
        (uint16 minOtmBps,, uint16 minPremiumBps,,,) = vault.policy();
        bool stale = vault.cycleStrikeUsdg() < (spot * (BPS + minOtmBps)) / BPS
            || vault.listingGrossUsdg() < (spot * vault.listingAmount() * minPremiumBps) / BPS;
        if (!stale) {
            _skip();
            return;
        }

        vm.prank(address(uint160(uint256(keccak256(abi.encode(spotSeed, "sniper-guard"))))));
        try vault.invalidateStaleListing() {
            live.active = false;
            succeeded++;
            cStaleKill++;
        } catch (bytes memory err) {
            _reverted("invalidateStaleListing", err);
        }
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

    /// @dev Partial fills are the norm on Overcall, so the fill size is fuzzed against what is
    ///      left of the order rather than always taking the lot.
    function fill(uint256 fillSeed) external {
        attempted++;
        if (!live.active || vault.listingHash() == bytes32(0)) {
            _skip();
            return;
        }

        OrderComponents memory c = _rebuildLive();
        bytes32 h = seaport.getOrderHash(c);
        uint256 remaining = live.amount - seaport.filled(h);
        if (remaining == 0) {
            _skip();
            return;
        }
        if (clear.balanceOf(address(vault), live.optionId) < remaining) {
            _skip();
            return;
        }

        uint256 fillAmount = bound(fillSeed, 1, remaining);
        usdg.mint(buyer, live.unitPrice * fillAmount + 1e6);

        uint256 vaultUsdgBefore = usdg.balanceOf(address(vault));
        vm.prank(buyer);
        try seaport.fulfil(c, fillAmount) {
            // The ghost is the MEASURED inflow, so a partial fill counts exactly what Seaport
            // actually moved. It is cross-checked against the order's own vault leg (Overcall's
            // 5% floored per contract, so the fraction is always exact) to prove the
            // measurement is the premium and nothing else.
            uint256 premiumIn = usdg.balanceOf(address(vault)) - vaultUsdgBefore;
            uint256 feePerContract = (live.unitPrice * 500) / BPS;
            assertEq(
                premiumIn,
                (live.unitPrice - feePerContract) * fillAmount,
                "a fill paid the vault something other than its consideration leg"
            );
            ghostPremiumToVault += premiumIn;
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

        vm.prank(buyer);
        try clear.exercise(optionId, n) {
            totalAssignedOut += uint256(n) * LOT;
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
        if (!asKeeper) vm.prank(address(uint160(uint256(keccak256(abi.encode(whoSeed, "closer"))))));
        try vault.rollClose() {
            if (assignedBefore != 0) cAssignedCycles++;
            live.active = false;
            succeeded++;
            cClose++;
        } catch (bytes memory err) {
            _reverted("rollClose", err);
        }
    }

    /// @notice Free-running time, so phases are not always entered at the same instant.
    function warpAhead(uint256 seed) external {
        attempted++;
        vm.warp(block.timestamp + bound(seed, 1 hours, 2 days));
        succeeded++;
    }

    /// @notice Halting must never block a redemption, a claim or a close. Flip it often enough
    ///         that a run spends real time halted, but leave writing possible most of the time.
    function toggleHalt(uint256 seed) external {
        attempted++;
        bool halt = seed % 4 == 0;
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
        return (cDeposit + cMint + 2 * cClose) * HOLDER_SLOTS;
    }

    function _skip() internal {
        skipped++;
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
        return p == 0 || p == 1;
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
        registry.setCycleWithStrikes(cycleOptionIds, strikes, cycleExercise, cycleExpiry);
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

    function _maxContracts() internal view returns (uint256) {
        (,,, uint16 maxUtilizationBps,, uint64 cap) = vault.policy();
        uint256 byUtilization = (vault.idleAssets() * maxUtilizationBps) / BPS / LOT;
        return byUtilization < cap ? byUtilization : cap;
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

    /// @dev The exact Overcall shape: 5% fee floored PER CONTRACT, so every consideration item
    ///      divides evenly by the order size and a partial fill is expressible.
    function _buildOrderWithCounter(
        uint256 optionId,
        uint256 amount,
        uint256 unitPrice,
        uint40 endTime,
        uint256 counter,
        uint256 salt
    ) internal view returns (OrderComponents memory c) {
        uint256 feePerContract = (unitPrice * 500) / BPS;
        uint256 toOvercall = feePerContract * amount;
        uint256 toVault = (unitPrice - feePerContract) * amount;

        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155,
            token: address(clear),
            identifierOrCriteria: optionId,
            startAmount: amount,
            endAmount: amount
        });

        ConsiderationItem[] memory consid = new ConsiderationItem[](2);
        consid[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(usdg),
            identifierOrCriteria: 0,
            startAmount: toVault,
            endAmount: toVault,
            recipient: payable(address(vault))
        });
        consid[1] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(usdg),
            identifierOrCriteria: 0,
            startAmount: toOvercall,
            endAmount: toOvercall,
            recipient: payable(overcallFee)
        });

        c = OrderComponents({
            offerer: address(vault),
            zone: address(0),
            offer: offer,
            consideration: consid,
            orderType: OrderType.PARTIAL_OPEN,
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
/// @dev The six properties below are the ones that, if they ever stop holding, mean someone
///      cannot be paid. They are checked after every single handler call, in every phase, with
///      collateral locked, orders half filled, buyers assigned and redeemers queued.
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

    function setUp() public override {
        super.setUp();

        handler = new VaultHandler(
            vault,
            nvda,
            usdg,
            mockClear,
            registry,
            seaport,
            feed,
            buyer,
            overcallFee,
            admin,
            guardian,
            [alice, bob, carol]
        );

        // Hoisted: reading KEEPER_ROLE is itself an external call and would eat the prank.
        bytes32 keeperRole = vault.KEEPER_ROLE();
        vm.prank(admin);
        vault.grantRole(keeperRole, address(handler));

        holders = [alice, bob, carol, buyer, address(vault)];

        bytes4[] memory selectors = new bytes4[](20);
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
        selectors[17] = VaultHandler.writeMore.selector;
        selectors[18] = VaultHandler.settleQueue.selector;
        selectors[19] = VaultHandler.invalidateStaleListing.selector;

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
        uint256 outflow = handler.totalWithdrawn() + handler.totalAssignedOut();
        // Checked separately so a leak reports as a leak instead of an underflow panic.
        assertGe(inflow, outflow, "asset conservation: more asset left the vault than ever entered");

        uint256 accountedFor = nvda.balanceOf(address(vault)) + vault.lockedAssets();
        assertEq(accountedFor, inflow - outflow, "asset conservation: idle + locked != in - out - assigned");
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
        assertEq(
            vault.usdgReservedForQueue(), inEpochs + staged, "queue USDG reserve != unsettled epochs + staged balances"
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
        assertLe(
            owedToHolders + vault.reservedAssets(),
            nvda.balanceOf(address(vault)) + vault.lockedAssets(),
            "holders plus settled redeemers are owed more asset than exists"
        );
    }

    /// @notice A settled redeemer's money is really there. Reserves are carved out of the
    ///         balance, never out of the locked collateral or out of thin air.
    function invariant_reservesAreReal() public view {
        // The asset leg is strict. Nothing rounds here: `reservedAssets` is set from a real
        // balance at settlement and drawn down by real transfers.
        assertLe(vault.reservedAssets(), nvda.balanceOf(address(vault)), "reservedAssets exceeds the asset balance");

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
        // states for USDG: the reserve is exactly what is still owed inside the open epochs plus
        // what has been staged against accounts by an earlier `queueRedeem`.
        uint256 inEpochs;
        uint256 staged;
        for (uint256 e = 1; e <= vault.epochId(); e++) {
            (, uint256 assetsRemaining,) = vault.epochs(e);
            inEpochs += assetsRemaining;
        }
        for (uint256 i; i < holders.length; i++) {
            staged += vault.owedAssets(holders[i]);
        }
        assertEq(vault.reservedAssets(), inEpochs + staged, "asset reserve != unsettled epochs + staged balances");

        // `lockedAssets()` is read straight out of Valorem's position; `contractsWritten` and
        // `contractsAssigned()` come from the vault's own counters and the claim. If those two
        // ever disagree, the vault's idea of its collateral has drifted from the clearinghouse's
        // and `totalAssets` — and therefore the share price — is wrong.
        uint256 written = vault.contractsWritten();
        uint256 assigned = vault.contractsAssigned();
        assertLe(assigned, written, "more contracts assigned than were ever written");
        assertEq(vault.lockedAssets(), (written - assigned) * 1e18, "locked collateral disagrees with the open short");
    }

    /// @notice Idle means flat. If it does not, instant redemption would pay out collateral
    ///         that is still collateralising somebody's short call.
    function invariant_phaseSanity() public view {
        if (vault.contractsWritten() > 0) {
            assertTrue(uint8(vault.phase()) != 0, "contracts written while Idle");
        }
        if (uint8(vault.phase()) == 0) {
            assertEq(vault.claimKey(), 0, "Idle with an open claim");
            assertEq(vault.lockedAssets(), 0, "Idle with collateral still locked in Valorem");
            assertTrue(vault.canRedeemInstantly(), "Idle and flat but instant redemption refused");
        }
        // Settling is entered and left inside a single `rollClose`, so no outside observer can
        // ever catch the vault in it. If this ever fires, some path left the vault wedged.
        assertTrue(uint8(vault.phase()) != 3, "observed the Settling phase from outside rollClose");
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
        emit log_named_uint("tranche top-ups", handler.cWriteMore());
        emit log_named_uint("flat queue settlements", handler.cSettleQueue());
        emit log_named_uint("stale listings killed", handler.cStaleKill());
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
        handler.rollOpen(0, 0, type(uint256).max);
        assertEq(uint8(vault.phase()), 1, "should be Listed");
        assertGt(vault.contractsWritten(), 0, "should have written contracts");

        handler.approveListing(type(uint256).max, 0, 0);
        assertTrue(vault.listingHash() != bytes32(0), "should have a live listing");

        handler.fill(1); // partial fill
        handler.deposit(2, 0); // carol deposits mid-cycle: new money, same open short
        handler.queueRedeem(0, type(uint256).max);
        assertGt(vault.queuedShares(), 0, "should have shares in escrow");

        handler.exercise(0, 0); // partial assignment inside the window
        assertGt(handler.totalAssignedOut(), 0, "should have been assigned");

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

        // And the invariants still hold at the end of it.
        invariant_assetConservation();
        invariant_usdgBooksBalance();
        invariant_usdgHolderSolvency();
        invariant_shareAccounting();
        invariant_noFreeShares();
        invariant_reservesAreReal();
        invariant_phaseSanity();
        invariant_feeNeverTouchesStrikeProceeds();
    }

    /// @notice Proves the handler reaches the three audit-fix actions: a tranche top-up, a stale
    ///         listing killed by a stranger, and a queue settled while flat.
    function test_handlerReachesTranchesStaleKillsAndFlatSettlement() public {
        handler.deposit(0, type(uint256).max);
        handler.deposit(1, type(uint256).max);
        handler.rollOpen(0, 0, 0); // one contract, leaving room for a tranche
        handler.writeMore(0, 0);
        assertGt(handler.cWriteMore(), 0, "writeMore");

        handler.approveListing(0, 0, 0); // priced on the floor at $215 spot
        handler.invalidateStaleListing(type(uint256).max); // $232 spot: the floor has risen past it
        assertGt(handler.cStaleKill(), 0, "invalidateStaleListing");

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
        vault.rollOpen(optionId, 1);

        // $4.422336 for one contract. HAND CHECK: fee/contract = 4_422_336 * 500 / 10_000
        // = 221_116 (floor), so Overcall takes 221_116 and the vault's consideration item is
        // 4_422_336 - 221_116 = 4_201_220. The premium does not divide evenly into the supply,
        // which is exactly what makes the index rounding observable.
        OrderComponents memory c = _approveListing(optionId, 1, 4_422_336);
        _fill(c, 1);
        assertEq(usdg.balanceOf(address(vault)), 4_201_220, "premium landed");
        assertEq(usdg.balanceOf(overcallFee), 221_116, "Overcall took its 5% of the one contract");

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

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        feed.setAnswer(SPOT_FEED);
        uint256 nextOption = optionIds[RUNG_PICK];

        vm.prank(keeper);
        vault.rollOpen(nextOption, 1);
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
    ///      rollOpen 3 contracts on the 231 rung:
    ///        utilization cap = 10e18 * 9_500 / 10_000 / 1e18 = 9 contracts, so 3 is legal;
    ///        collateral locked = 3 * 1e18 = 3e18, leaving 7e18 idle.
    ///      Listing 3 contracts at $2.00 each:
    ///        fee per contract = 2_000_000 * 500 / 10_000      = 100_000
    ///        consideration[1] to Overcall = 100_000 * 3       =   300_000
    ///        consideration[0] to the vault = 1_900_000 * 3    = 5_700_000
    ///        gross = 6_000_000, and the policy floor is
    ///          220_000_000 * 3 * 40 / 10_000                  = 2_640_000  -> clears it.
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

        uint256 optionId = _rollOpen(3);
        assertEq(vault.lockedAssets(), 3e18, "three lots locked in Valorem");
        assertEq(vault.idleAssets(), 7e18, "seven lots left idle");

        OrderComponents memory c = _approveListing(optionId, 3, _okUnitPrice());
        _fill(c, 3);
        assertEq(usdg.balanceOf(address(vault)), 5_700_000, "vault leg of the premium");
        assertEq(usdg.balanceOf(overcallFee), 300_000, "Overcall's 5%, floored per contract");

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
    ///        3 contracts written on the 231 rung, 3 sold, 1 exercised, so at rollClose the
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

        uint256 optionId = _rollOpen(3);
        OrderComponents memory c = _approveListing(optionId, 3, _okUnitPrice());
        _fill(c, 3);

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
        handler.rollOpen(3, 16562, 12766);
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
