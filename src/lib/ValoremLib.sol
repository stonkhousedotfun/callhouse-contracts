// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IValoremClear} from "../interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../interfaces/IChainlinkFeed.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {Policy, PolicyParams} from "../Policy.sol";

/// @title ValoremLib
/// @notice The arm gate, the fill gate, the write and redeem mechanics against the Valorem
///         clearinghouse, and the oracle read both gates depend on.
/// @dev DEPLOYMENT NOTE: `public`, so this compiles to a standalone library that {Vault} reaches
///      by DELEGATECALL and that must be deployed and linked. See {SeaportOrderLib} for why the
///      split is kept now that chain 4663's 98,304 B code limit no longer forces it.
///
///      DELEGATECALL SEMANTICS. Every function here runs in the caller's context, so
///      `address(this)` is the VAULT. That matters: Valorem mints the option ERC-1155 and the
///      claim NFT to `msg.sender`, and `redeem` reverts `CallerDoesNotOwnClaimId` for anyone
///      else. The vault must be the writer, and delegatecall is what keeps it so.
///
///      NO REGISTRY. An earlier design read the option type's approval, strike and window from
///      Overcall's per-market registry, a contract owned by one third-party EOA. The vault now
///      validates the option type from the clearinghouse itself: the tuple is immutable in
///      Valorem once created, `newOptionType` is permissionless (the keeper creates the weekly
///      type), and every bound the registry used to promise is enforced here instead.
library ValoremLib {
    using SafeERC20 for IERC20;

    /// @dev The exercise window must open at least this long after `rollOpen`. A type whose
    ///      window opens in the next block could be filled and exercised inside one tick, and
    ///      the deposit gate rests on nothing being assignable before `cycleExerciseTs`.
    uint40 internal constant MIN_LEAD = 1 hours;

    /// @dev Expiry must sit at least this long after the exercise timestamp. Valorem's own
    ///      floor is one minute; a one-minute exercise window is a lottery, not a call.
    uint40 internal constant MIN_EXERCISE_WINDOW = 1 days;

    /// @dev The longest cycle this vault will ever underwrite, measured from `rollOpen`. Weekly
    ///      cycles run seven days with a 24-hour exercise window.
    ///
    ///      WHY A COMPILED-IN CONSTANT, NOT A POLICY FIELD. The vault snapshots the type's expiry
    ///      and `rollClose` refuses to run until it passes, so collateral written into a type
    ///      with a far expiry would be locked in Valorem for the whole tenor with no redemption
    ///      path for anyone. A skipped week is strictly better than a decade-long lock on
    ///      depositor principal, and making this admin-settable would reintroduce a single-key
    ///      dependency for no gain.
    uint40 internal constant MAX_CYCLE_TENOR = 21 days;

    /// @dev Everything the arm gate needs from the vault. No size: nothing is written at open.
    struct Open {
        IChainlinkFeed feed;
        IERC20 asset;
        address exerciseAsset;
        uint256 optionId;
        uint32 maxPriceAge;
        bool feeAccepted;
    }

    /// @dev Everything the fill gate needs: the vault's live state plus the fill Seaport is
    ///      about to execute, in one struct so the gate stays inside the EVM stack limit.
    struct Fill {
        IChainlinkFeed feed;
        IERC20 asset;
        uint256 optionId;
        /// @dev Zero on the first fill of a cycle (opens the claim). The cycle's claim afterwards.
        uint256 claimId;
        /// @dev The strike snapshotted at `rollOpen`.
        uint256 strikeUsdg;
        /// @dev Asset base units the size is measured against: idle plus locked, less reserved.
        uint256 sizingAssets;
        /// @dev `reservedAssets`: what the balance must still cover after the write.
        uint256 reserved;
        /// @dev USDG the buyer pays for THIS fill, pro rata from the listing.
        uint256 grossUsdg;
        /// @dev Contracts already written into `claimId` this cycle.
        uint112 written;
        /// @dev Contracts Seaport is about to move out: the amount to write.
        uint112 n;
        uint40 cycleExerciseTs;
        uint32 maxPriceAge;
        bool feeAccepted;
    }

    /// @dev Declared here with the SAME signatures as {Vault}'s, so the selectors a caller sees
    ///      are unchanged by the gate living in this library.
    error NotAnOptionType(uint256 tokenId);
    error OptionAssetMismatch(address expectedUnderlying, address gotUnderlying);
    error OptionExerciseAssetMismatch(address expectedExercise, address gotExercise);
    error UnexpectedLotSize(uint96 expected, uint96 got);
    error ExerciseTooSoon(uint40 exerciseTs, uint40 earliest);
    error BadCycleWindow(uint40 exerciseTs, uint40 expiryTs);
    error ValoremFeeNotAccepted(uint8 feeBps);
    error OraclePaused();
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error WriteWindowClosed(uint40 exerciseTs);
    error PremiumBelowFloorAtFill(uint256 grossUsdg, uint256 floorUsdg);
    error ReserveBreached(uint256 balance, uint256 reserved);
    error WriteReturnedNoClaim();
    error WriteReturnedWrongClaim(uint256 expected, uint256 got);
    /// @dev The claim redeem failed with almost no gas left: the inner call was starved, not refused.
    ///      See {tryRedeemClaim}.
    error RedeemOutOfGas();

    /*//////////////////////////////////////////////////////////////
                                  OPEN
    //////////////////////////////////////////////////////////////*/

    /// @notice Every check an option type must pass before the vault arms a cycle on it. Writes
    ///         NOTHING: under write-on-fill the collateral moves only inside a Seaport fill.
    /// @dev THE ARM GATE. The keeper names a Valorem option id; the vault trusts nothing about it
    ///      and reads the tuple back from the clearinghouse:
    ///        1. It is an OPTION type (`tokenType == Option`), not a claim id and not an unknown
    ///           id. `option()` ignores the claim key, so a claim id would otherwise pass every
    ///           tuple check below and then `write` would mint into somebody else's claim.
    ///        2. Underlying is this vault's asset and the exercise asset is USDG.
    ///        3. One contract is exactly one token (`Policy.LOT`). The vault prices everything per
    ///           token: the OTM band compares the per-contract strike with per-1e18 spot, the
    ///           premium floor is per 1e18, and utilisation divides assets by 1e18. A contract of
    ///           more than one token would make an in-the-money strike look out of the money.
    ///        4. The window: exercise opens at least MIN_LEAD from now (nothing can be assigned in
    ///           the same tick it is sold), stays open at least MIN_EXERCISE_WINDOW, and the whole
    ///           tenor is at most MAX_CYCLE_TENOR (collateral can never be locked for years).
    ///        5. Valorem's engine fee is off, or governance has accepted paying it.
    ///        6. The oracle is live and the strike sits inside the OTM band, BOTH bounds. The
    ///           ceiling is checked here and only here: after a sell-off a strike above the band
    ///           is safer to sell, not riskier, so the fill gate checks the floor alone.
    /// @return strikeUsdg The type's exerciseAmount per contract, USDG base units.
    /// @return exerciseTs The type's exercise timestamp.
    /// @return expiryTs The type's expiry timestamp.
    function open(IValoremClear clear, Open memory w, PolicyParams memory p)
        public
        view
        returns (uint256 strikeUsdg, uint40 exerciseTs, uint40 expiryTs)
    {
        uint256 id = w.optionId;
        if (clear.tokenType(id) != IValoremClear.TokenType.Option) revert NotAnOptionType(id);

        IValoremClear.Option memory o = clear.option(id);
        if (o.underlyingAsset != address(w.asset)) revert OptionAssetMismatch(address(w.asset), o.underlyingAsset);
        if (o.exerciseAsset != w.exerciseAsset) revert OptionExerciseAssetMismatch(w.exerciseAsset, o.exerciseAsset);
        if (o.underlyingAmount != Policy.LOT) revert UnexpectedLotSize(uint96(Policy.LOT), o.underlyingAmount);

        exerciseTs = o.exerciseTimestamp;
        expiryTs = o.expiryTimestamp;
        uint40 earliest = uint40(block.timestamp) + MIN_LEAD;
        if (exerciseTs < earliest) revert ExerciseTooSoon(exerciseTs, earliest);
        if (expiryTs < exerciseTs + MIN_EXERCISE_WINDOW || expiryTs > block.timestamp + MAX_CYCLE_TENOR) {
            revert BadCycleWindow(exerciseTs, expiryTs);
        }

        // Valorem's engine fee is 15 bps of NOTIONAL. On a weekly out-of-the-money call that is a
        // large slice of the premium, so writing through it is a governance decision, not a
        // keeper decision. Refused at arm so a whole week is not listed and then refused at fill.
        if (clear.feesEnabled() && !w.feeAccepted) revert ValoremFeeNotAccepted(clear.feeBps());

        if (oraclePaused(w.asset)) revert OraclePaused();
        strikeUsdg = o.exerciseAmount;
        Policy.checkStrike(strikeUsdg, spotUsdg(w.feed, w.maxPriceAge), p);
    }

    /*//////////////////////////////////////////////////////////////
                              WRITE ON FILL
    //////////////////////////////////////////////////////////////*/

    /// @notice Write exactly `f.n` contracts into Valorem inside a Seaport fill, either opening
    ///         the cycle's claim (`f.claimId == 0`) or topping it up.
    /// @dev THE FILL GATE. Called from {Vault.authorizeOrder}, which Seaport 1.6 invokes BEFORE it
    ///      transfers the option tokens out and BEFORE it records the fill. The tuple, lot and
    ///      window were pinned at {open} and are immutable in Valorem, so they are not re-read;
    ///      everything that can change between arm and fill is:
    ///        1. THE CLOCK. No write once exercise can start: the deposit gate rests on "nothing
    ///           can be assigned before `cycleExerciseTs`", and a contract written into an open
    ///           exercise window could be assigned in the block it was sold.
    ///        2. THE ENGINE FEE. Valorem can switch it on mid-week; unaccepted, the fill refuses.
    ///        3. THE ORACLE. Paused or stale, no price stands behind the floors, so no sale.
    ///        4. THE BAND FLOOR AT LIVE SPOT. A rally since the arm can have pulled the strike
    ///           inside the floor; a buyer filling at Monday's price on Friday's spot would be
    ///           buying a near-the-money call for an out-of-the-money premium. Floor ONLY: a
    ///           sell-off makes the call safer, not riskier (decision D9).
    ///        5. THE PREMIUM FLOOR AT LIVE SPOT, plus the engine fee valued at spot when it is
    ///           on. The listing was priced against the spot of its day; the fill is priced
    ///           against today's. When the fee is on, Valorem pulls it from the vault in the
    ///           asset on top of the collateral, so the buyer's USDG must cover it or the
    ///           depositors are paying to sell (AUDIT-FINDINGS F-04).
    ///        6. SIZE ON THE TOTAL. `written + n` against `Policy.maxContracts(NAV)`, so the cap
    ///           and the utilisation ceiling bind the whole cycle, fill by fill.
    ///      Then the write itself: approve exactly collateral plus fee, `clear.write`, zero the
    ///      approval, and refuse to leave the balance below `reservedAssets`.
    ///
    ///      WHY THIS CLOSES THE UNSOLD-INVENTORY FINDING. Valorem assigns exercise pro rata by
    ///      amount WRITTEN across every writer of an option id, whoever sold. A vault that wrote
    ///      ahead of its sales carried the intrinsic value of everything it had not sold as pure
    ///      exposure, and a third party could write into the same bucket and take it
    ///      (AUDIT-FINDINGS F-01). Writing only what Seaport is moving out at that moment makes
    ///      written == sold by construction: every contract the vault can be assigned on earned a
    ///      premium, and there is never an unsold option token in the vault to be steered against.
    /// @return claimId The Valorem claim NFT representing the cycle's short position.
    /// @return collateral Asset base units locked by THIS write (the fee, if any, is on top).
    function writeOnFill(IValoremClear clear, Fill memory f, PolicyParams memory p)
        public
        returns (uint256 claimId, uint256 collateral)
    {
        if (block.timestamp >= f.cycleExerciseTs) revert WriteWindowClosed(f.cycleExerciseTs);
        // `n == 0` is refused on its own: `written + 0` would otherwise sail through the size check.
        if (f.n == 0) revert Policy.ContractsZero();

        bool feesOn = clear.feesEnabled();
        if (feesOn && !f.feeAccepted) revert ValoremFeeNotAccepted(clear.feeBps());

        IERC20 asset = f.asset;
        if (oraclePaused(asset)) revert OraclePaused();
        uint256 spot = spotUsdg(f.feed, f.maxPriceAge);

        (uint256 bandFloor,) = Policy.strikeBand(spot, p);
        if (f.strikeUsdg < bandFloor) revert Policy.StrikeBelowBand(f.strikeUsdg, bandFloor);

        collateral = uint256(f.n) * Policy.LOT;
        // Size the pull to what the clearinghouse will ACTUALLY take. When the engine fee is on it
        // charges 15 bps of notional on top of the collateral, with a one-base-unit floor; upstream
        // charges a top-up exactly as it charges a fresh claim.
        uint256 fee;
        if (feesOn) {
            fee = (collateral * uint256(clear.feeBps())) / 10_000;
            if (fee == 0) fee = 1;
        }
        // The fee is asset base units; valued at spot (USDG per 1e18) it becomes the extra USDG
        // the buyer must pay for the sale to be worth making.
        uint256 floorUsdg = Policy.minPremium(spot, f.n, p) + (fee * spot) / Policy.LOT;
        if (f.grossUsdg < floorUsdg) revert PremiumBelowFloorAtFill(f.grossUsdg, floorUsdg);

        // The sum is a uint256, and passing the cap (a uint64) bounds it far below uint112, so the
        // caller's `contractsWritten += n` cannot overflow.
        Policy.checkContracts(uint256(f.written) + f.n, f.sizingAssets, p);

        // forceApprove resets to zero first, which keeps this safe against tokens that reject a
        // non-zero-to-non-zero approve. The allowance is zeroed again immediately after, so no
        // standing approval to the clearinghouse is ever left behind, including unconsumed fee
        // headroom.
        asset.forceApprove(address(clear), collateral + fee);
        // Valorem Clear has ONE `write`: pass an option id to open a fresh claim, or a claim id
        // the caller owns to add to it (upstream 6436c82 checks `balanceOf[msg.sender][claimId]
        // == 1` and returns the claim id it was given). A top-up that came back with any other
        // id would mean the collateral went somewhere `claimKey` does not track, so it reverts.
        uint256 target = f.claimId;
        claimId = clear.write(target == 0 ? f.optionId : target, f.n);
        if (claimId == 0) revert WriteReturnedNoClaim();
        if (target != 0 && claimId != target) revert WriteReturnedWrongClaim(target, claimId);
        asset.forceApprove(address(clear), 0);

        // Second line of defence behind the 99.85% utilisation ceiling (F-04): whatever Valorem
        // pulled, the balance must still cover what settled redeemers are owed.
        uint256 bal = asset.balanceOf(address(this));
        if (bal < f.reserved) revert ReserveBreached(bal, f.reserved);
    }

    /*//////////////////////////////////////////////////////////////
                                ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the Stock Token has halted its own oracle.
    /// @dev Probed with a staticcall so a token without the function is not a permanent brick.
    function oraclePaused(IERC20 asset) public view returns (bool) {
        (bool ok, bytes memory data) =
            address(asset).staticcall(abi.encodeWithSelector(IStockToken.oraclePaused.selector));
        return ok && data.length == 32 && abi.decode(data, (bool));
    }

    /// @notice Spot for one lot in USDG base units, refusing a feed older than `maxAge`.
    /// @dev Gate and display only. Nothing downstream of a write decision ever calls it, and the
    ///      settlement path never does. See {Vault.maxPriceAge} for why the age is days.
    function spotUsdg(IChainlinkFeed feed, uint32 maxAge) public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (block.timestamp - updatedAt > maxAge) revert StalePrice(updatedAt, maxAge);
        return Policy.normalizeSpot(answer, feed.decimals());
    }

    /*//////////////////////////////////////////////////////////////
                                REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @notice Try to redeem a claim after expiry and report the exact balance deltas.
    /// @dev Measures real balances rather than trusting the event or the position struct. That is
    ///      correct even if Valorem ever netted a fee, and it is the number both the redeem queue
    ///      and the harvest are computed from.
    ///
    ///      WHY A LOW-LEVEL CALL AND NOT `clear.redeem(...)` (AUDIT-FINDINGS F-02). Upstream `redeem`
    ///      pushes the exercise asset (USDG) and then the underlying (NVDA) to the caller in the same
    ///      call, each only when non-zero, and a revert on either leg reverts the redeem. Both tokens
    ///      have an issuer who can make a leg revert at will: USDG can be paused, or the vault or
    ///      Clear frozen (Clear is the SENDER of the USDG leg), or Clear's USDG burnt by a supply
    ///      controller; the Stock Token issuer can blocklist the vault, which reverts the NVDA leg in
    ///      every week that is not fully assigned. An earlier draft let that revert bubble out of
    ///      `rollClose`, and `rollClose` is the only exit from Listed/Exercisable, so a stablecoin
    ///      action froze 100% of principal and the queue for as long as it lasted. The revert is now
    ///      caught and reported as `ok == false`; {Vault.rollClose} moves to Idle with the claim kept
    ///      (a "stranded" claim) and {Vault.retryStrandedClaim} redeems it once the cause clears.
    ///
    ///      THE GAS GUARD. A caught revert cannot be told apart from an out-of-gas inside the callee
    ///      by its return data, and a caller who starves the inner call could otherwise strand a
    ///      perfectly redeemable claim on purpose. EIP-150 hands the callee at most 63/64 of the gas
    ///      left, so after a callee out-of-gas the caller has at most 1/64 of `gasBefore` remaining;
    ///      a genuine early revert leaves far more. Failing with `gasleft() <= gasBefore / 63` is
    ///      therefore treated as starvation and reverts {RedeemOutOfGas} instead of stranding. The
    ///      bound errs on the safe side: a legitimate revert that happens to land in the last 1/63 of
    ///      the gas is also refused, and the caller simply retries with more gas.
    ///
    ///      WHAT THE GUARD DOES NOT SEE, AND WHY IT STILL HOLDS. If the starvation lands one call
    ///      deeper, in the token transfer Clear makes, Clear itself reverts with a reason and hands
    ///      back the 1/64 it kept, so this frame is left with about 2/64 of `gasBefore` and the
    ///      guard reads that as a refusal. But stranding is not free: the caller still has to open a
    ///      generation, harvest and settle the queue, which costs far more than 2/64 of any gas
    ///      figure small enough to starve a ~130k redeem, so the outer call runs out and the whole
    ///      transaction reverts with the claim untouched. The regression walks `rollClose` up a gas
    ///      ladder against the mock and the real Clear bytecode and asserts every call either
    ///      reverts leaving the claim as it was or redeems it: nothing lands in between.
    /// @return ok True if the claim was redeemed and its collateral is now in the caller's balance.
    function tryRedeemClaim(IValoremClear clear, IERC20 asset, IERC20 exerciseAsset, uint256 claimKey)
        public
        returns (bool ok, uint256 underlyingReturned, uint256 exerciseReceived)
    {
        uint256 assetBefore = asset.balanceOf(address(this));
        uint256 exerciseBefore = exerciseAsset.balanceOf(address(this));

        uint256 gasBefore = gasleft();
        (ok,) = address(clear).call(abi.encodeCall(IValoremClear.redeem, (claimKey)));
        if (!ok) {
            if (gasleft() <= gasBefore / 63) revert RedeemOutOfGas();
            return (false, 0, 0);
        }

        underlyingReturned = asset.balanceOf(address(this)) - assetBefore;
        exerciseReceived = exerciseAsset.balanceOf(address(this)) - exerciseBefore;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Underlying still locked behind a claim, in asset base units.
    /// @dev Reads Valorem's own `position` rather than deriving it, so partial assignment is
    ///      reflected the moment a buyer exercises. Defensive against a revert on a redeemed or
    ///      unknown claim: a view that reverted here would freeze `totalAssets()`, and with it
    ///      every deposit and every redemption.
    function lockedAssets(IValoremClear clear, uint256 claimKey) public view returns (uint256) {
        if (claimKey == 0) return 0;
        try clear.position(claimKey) returns (IValoremClear.Position memory p) {
            int256 amt = p.underlyingAmount;
            return amt > 0 ? uint256(amt) : 0;
        } catch {
            return 0;
        }
    }

    /// @notice Exercise-asset proceeds sitting in a claim, not yet redeemed.
    /// @dev Non-zero only once buyers have been assigned.
    function claimedExerciseProceeds(IValoremClear clear, uint256 claimKey) public view returns (uint256) {
        if (claimKey == 0) return 0;
        try clear.position(claimKey) returns (IValoremClear.Position memory p) {
            int256 amt = p.exerciseAmount;
            return amt > 0 ? uint256(amt) : 0;
        } catch {
            return 0;
        }
    }

    /// @notice Contracts assigned against a claim so far, as a raw count.
    /// @dev Valorem reports `amountExercised` as a 1e18-scaled scalar, so divide back down.
    ///      Getting this wrong reports a 10-contract assignment as 1e19. Pro-rata assignment
    ///      across a shared bucket can leave a fraction; this floors it, which is display only.
    function contractsAssigned(IValoremClear clear, uint256 claimKey) public view returns (uint256) {
        if (claimKey == 0) return 0;
        try clear.claim(claimKey) returns (IValoremClear.Claim memory c) {
            return c.amountExercised / 1e18;
        } catch {
            return 0;
        }
    }
}
