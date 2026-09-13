// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IValoremClear} from "../interfaces/IValoremClear.sol";
import {IOvercallRegistry} from "../interfaces/IOvercallRegistry.sol";
import {IChainlinkFeed} from "../interfaces/IChainlinkFeed.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {Policy, PolicyParams} from "../Policy.sol";

/// @title ValoremLib
/// @notice The write gate, the write and redeem mechanics against the Valorem clearinghouse, and the
///         oracle read the gate depends on.
/// @dev DEPLOYMENT NOTE: `public`, so this compiles to a standalone library that {Vault} reaches
///      by DELEGATECALL and that must be deployed and linked. Like {SeaportOrderLib}, the reason
///      is the EIP-170 24 KB runtime limit rather than taste: with this inlined the vault has
///      well under a hundred bytes of headroom, which is no margin at all for an audit fix.
///
///      DELEGATECALL SEMANTICS. Every function here runs in the caller's context, so
///      `address(this)` is the VAULT. That matters: Valorem mints the option ERC-1155 and the
///      claim NFT to `msg.sender`, and `redeem` reverts `CallerDoesNotOwnClaimId` for anyone
///      else. The vault must be the writer, and delegatecall is what keeps it so.
library ValoremLib {
    using SafeERC20 for IERC20;

    /// @dev The longest cycle this vault will ever underwrite, measured from the moment of the
    ///      write. Overcall's cycles are seven days with a 24-hour exercise window.
    ///
    ///      WHY A COMPILED-IN CONSTANT, NOT A POLICY FIELD. The registry that sets the cycle is
    ///      owned by a single third-party EOA, and its `setCycle` bounds the expiry only from
    ///      below (`exerciseAt + MIN_EXERCISE_WINDOW`). Nothing stops it setting an expiry years
    ///      out, by malice or by fat finger. The vault snapshots that expiry and `rollClose`
    ///      then refuses to run until it passes, so collateral would be locked in Valorem for
    ///      the whole tenor with no redemption path for anyone. A skipped week is strictly
    ///      better than a decade-long lock on depositor principal, and making this
    ///      admin-settable would reintroduce the single-key dependency it exists to remove.
    uint40 internal constant MAX_CYCLE_TENOR = 21 days;

    /// @dev Everything the write gate needs from the vault, in one struct so the gate stays
    ///      inside the EVM stack limit. Callers pass their storage as it stands; the fields marked
    ///      TOP-UP ONLY are ignored when `claimId` is zero, which is what lets `rollOpen` and
    ///      `writeMore` share one call site without branching in the vault.
    struct Write {
        IOvercallRegistry registry;
        IChainlinkFeed feed;
        IERC20 asset;
        address exerciseAsset;
        uint256 optionId;
        /// @dev Zero opens a fresh claim. Non-zero tops this claim up.
        uint256 claimId;
        /// @dev TOP-UP ONLY. The strike snapshotted at `rollOpen`.
        uint256 strikeUsdg;
        /// @dev Asset base units the size is measured against: idle plus locked.
        uint256 sizingAssets;
        /// @dev Contracts already written into `claimId` (zero on a fresh write).
        uint112 written;
        uint112 n;
        /// @dev TOP-UP ONLY. The cycle the claim was written into.
        uint32 cycleNumber;
        uint40 cycleExerciseTs;
        uint32 maxPriceAge;
        bool feeAccepted;
    }

    /// @dev Declared here with the SAME signatures as {Vault}'s, so the selectors a caller sees
    ///      are unchanged by the gate living in this library.
    error WritingNotOpen();
    error NoCycle();
    error OptionNotApproved(uint256 optionId);
    error OptionNotInCurrentCycle(uint256 optionId, uint32 optionCycle, uint32 currentCycle);
    error BadCycleWindow(uint40 exerciseTs, uint40 expiryTs);
    error ValoremFeeNotAccepted(uint8 feeBps);
    error OraclePaused();
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error WriteWindowClosed(uint40 exerciseTs);
    error OptionAssetMismatch(address expectedUnderlying, address gotUnderlying);
    error OptionExerciseAssetMismatch(address expectedExercise, address gotExercise);
    error UnexpectedLotSize(uint96 expected, uint96 got);
    error OptionWindowMismatch(uint40 optionExerciseTs, uint40 optionExpiryTs);
    error WriteReturnedNoClaim();
    error WriteReturnedWrongClaim(uint256 expected, uint256 got);

    /*//////////////////////////////////////////////////////////////
                                 WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Run every pre-write check, then lock collateral into Valorem and mint `w.n` option
    ///         contracts, either into a fresh claim (`w.claimId == 0`) or on top of an existing one.
    /// @dev THE ONE WRITE GATE. `rollOpen` and `writeMore` both come through here, so a check
    ///      added for one cannot be forgotten for the other. The order is the order `rollOpen`
    ///      always checked in, so a caller sees the same revert for the same state.
    ///
    ///      WHY A TOP-UP RE-RUNS THE WHOLE GATE. A tranche written on Wednesday is a new decision
    ///      taken at Wednesday's spot, not a continuation of Monday's. A rally since the open can
    ///      have pulled the strike inside the band floor, the oracle can have stopped, governance
    ///      can have halted, and Valorem can have switched its fee on. Each of those refuses a
    ///      fresh write, and so each refuses a top-up.
    ///
    ///      WHY SIZE IS MEASURED ON THE TOTAL. Checking each tranche against 95% of what is idle
    ///      at the time would creep: 95% of idle, then 95% of the 5% left, and so on towards
    ///      100%. The cap and the utilisation limit are therefore applied to everything the claim
    ///      will hold after this write (`written + n`) against idle plus locked, which is the
    ///      same book `rollOpen` sized against when nothing was locked yet.
    /// @return claimId The Valorem claim NFT representing the short position.
    /// @return collateral Asset base units locked by THIS write.
    /// @return strikeUsdg The strike checked against the band.
    /// @return cycleNumber The registry's live cycle number.
    /// @return exerciseTs The live cycle's exercise timestamp.
    /// @return expiryTs The live cycle's expiry timestamp.
    function write(IValoremClear clear, Write memory w, PolicyParams memory p)
        public
        returns (
            uint256 claimId,
            uint256 collateral,
            uint256 strikeUsdg,
            uint32 cycleNumber,
            uint40 exerciseTs,
            uint40 expiryTs
        )
    {
        // The registry's own gate. `isWritingOpen()` is false both before the first cycle is
        // set and after the write deadline passes.
        IOvercallRegistry registry = w.registry;
        if (!registry.isWritingOpen()) revert WritingNotOpen();

        IOvercallRegistry.Cycle memory cyc = registry.cycle();
        if (cyc.number == 0) revert NoCycle();
        uint256 id = w.optionId;
        if (!registry.isApproved(id)) revert OptionNotApproved(id);

        uint32 optCycle = registry.cycleOf(id);
        if (optCycle != cyc.number) revert OptionNotInCurrentCycle(id, optCycle, cyc.number);

        strikeUsdg = registry.strikePerContract(id);
        if (w.claimId != 0) {
            // A top-up writes into THIS vault's cycle and nothing else. The registry rolling on,
            // even to a cycle that happens to re-approve the same option id, ends the tranche
            // window.
            if (cyc.number != w.cycleNumber) revert OptionNotInCurrentCycle(id, w.cycleNumber, cyc.number);
            // No write once exercise can start. The deposit gate rests on "nothing can be
            // assigned before `cycleExerciseTs`", and a tranche written into an open exercise
            // window could be assigned in the same block it was written.
            if (block.timestamp >= w.cycleExerciseTs) revert WriteWindowClosed(w.cycleExerciseTs);
            strikeUsdg = w.strikeUsdg;
        }

        // Refuse an absurd cycle before any collateral moves. The registry's owner is a single
        // third-party EOA and its `setCycle` bounds the expiry only from below, so a hostile or
        // mistaken cycle could otherwise lock the vault's collateral until that expiry passed.
        if (cyc.expiryTimestamp <= cyc.exerciseTimestamp || cyc.expiryTimestamp > block.timestamp + MAX_CYCLE_TENOR) {
            revert BadCycleWindow(cyc.exerciseTimestamp, cyc.expiryTimestamp);
        }

        // Valorem's engine fee is 15 bps of NOTIONAL. On a weekly out-of-the-money call that is a
        // large slice of the premium, so writing through it is a governance decision, not a
        // keeper decision.
        bool feesOn = clear.feesEnabled();
        if (feesOn && !w.feeAccepted) revert ValoremFeeNotAccepted(clear.feeBps());

        if (oraclePaused(w.asset)) revert OraclePaused();
        Policy.checkStrike(strikeUsdg, spotUsdg(w.feed, w.maxPriceAge), p);
        // `n == 0` is refused on its own: on a top-up `written + 0` would otherwise sail through
        // the size check. The sum is a uint256, and passing the cap (a uint64) bounds it far
        // below uint112, so the caller's `contractsWritten += n` cannot overflow.
        if (w.n == 0) revert Policy.ContractsZero();
        Policy.checkContracts(uint256(w.written) + w.n, w.sizingAssets, p);

        (claimId, collateral) = _write(clear, w, cyc, feesOn);
        (cycleNumber, exerciseTs, expiryTs) = (cyc.number, cyc.exerciseTimestamp, cyc.expiryTimestamp);
    }

    /// @dev Validate the option against the cycle, then write. Split from {write} for the stack.
    function _write(IValoremClear clear, Write memory w, IOvercallRegistry.Cycle memory cyc, bool feesOn)
        private
        returns (uint256 claimId, uint256 collateral)
    {
        IERC20 asset = w.asset;
        IValoremClear.Option memory o = clear.option(w.optionId);
        if (o.underlyingAsset != address(asset)) revert OptionAssetMismatch(address(asset), o.underlyingAsset);
        if (o.exerciseAsset != w.exerciseAsset) revert OptionExerciseAssetMismatch(w.exerciseAsset, o.exerciseAsset);
        if (o.underlyingAmount != cyc.lotSize) revert UnexpectedLotSize(cyc.lotSize, o.underlyingAmount);
        // The vault prices everything per ONE token: the OTM band compares the per-contract strike
        // with per-1e18 spot, the premium floor is per 1e18, and utilisation divides idle by 1e18
        // (Policy.LOT). The registry owner can change `lotSize` between cycles, and a contract of
        // more than one token would make an in-the-money strike look out of the money and lock more
        // collateral than utilisation allows. Refuse any lot other than exactly one token.
        if (cyc.lotSize != 1e18) revert UnexpectedLotSize(1e18, cyc.lotSize);

        // The option's own window must be exactly the cycle's. The deployed registry enforces
        // this in `setCycle`, but the vault must not DEPEND on a third party having done so: the
        // deposit gate rests on "assignment cannot happen before `cycleExerciseTs`", and that is
        // only true if the option actually written shares that timestamp. One comparison against
        // a struct already in memory buys independence from the registry's owner.
        //
        // On a top-up this is also what pins the live cycle's window to the SNAPSHOT: the option's
        // timestamps are immutable in Valorem and matched the cycle the vault snapshotted at
        // `rollOpen`, so a live cycle that matches the option matches the snapshot.
        if (o.exerciseTimestamp != cyc.exerciseTimestamp || o.expiryTimestamp != cyc.expiryTimestamp) {
            revert OptionWindowMismatch(o.exerciseTimestamp, o.expiryTimestamp);
        }

        collateral = uint256(w.n) * uint256(o.underlyingAmount);

        // Size the approval to what the clearinghouse will ACTUALLY pull. When Valorem's engine
        // fee is on it takes 15 bps of notional ON TOP of the collateral, so approving only the
        // collateral makes every write revert on allowance — which is what made the
        // `acceptValoremFee` governance switch still non-functional even after the flag was
        // wired through. Upstream charges it on a top-up exactly as on a fresh claim.
        uint256 approveAmount = collateral;
        if (feesOn) {
            uint256 fee = (collateral * uint256(clear.feeBps())) / 10_000;
            if (fee == 0) fee = 1; // upstream applies the same floor
            approveAmount = collateral + fee;
        }

        // forceApprove resets to zero first, which keeps this safe against tokens that reject a
        // non-zero-to-non-zero approve. The allowance is zeroed again immediately after, so no
        // standing approval to the clearinghouse is ever left behind, including any unconsumed
        // fee headroom.
        asset.forceApprove(address(clear), approveAmount);
        // Valorem Clear has ONE `write`: pass an option id to open a fresh claim, or a claim id
        // the caller owns to add to it (upstream 6436c82 checks `balanceOf[msg.sender][claimId]
        // == 1` and returns the claim id it was given). A top-up that came back with any other
        // id would mean the collateral went somewhere `claimKey` does not track, so it reverts.
        uint256 target = w.claimId;
        claimId = clear.write(target == 0 ? w.optionId : target, w.n);
        if (claimId == 0) revert WriteReturnedNoClaim();
        if (target != 0 && claimId != target) revert WriteReturnedWrongClaim(target, claimId);
        asset.forceApprove(address(clear), 0);
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

    /// @notice Redeem a claim after expiry and report the exact balance deltas.
    /// @dev Measures real balances rather than trusting the event or the position struct. That is
    ///      correct even if Valorem ever netted a fee, and it is the number both the redeem queue
    ///      and the harvest are computed from.
    function redeemClaim(IValoremClear clear, IERC20 asset, IERC20 exerciseAsset, uint256 claimKey)
        public
        returns (uint256 underlyingReturned, uint256 exerciseReceived)
    {
        uint256 assetBefore = asset.balanceOf(address(this));
        uint256 exerciseBefore = exerciseAsset.balanceOf(address(this));

        clear.redeem(claimKey);

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
    ///      Getting this wrong reports a 10-contract assignment as 1e19.
    function contractsAssigned(IValoremClear clear, uint256 claimKey) public view returns (uint256) {
        if (claimKey == 0) return 0;
        try clear.claim(claimKey) returns (IValoremClear.Claim memory c) {
            return c.amountExercised / 1e18;
        } catch {
            return 0;
        }
    }
}
