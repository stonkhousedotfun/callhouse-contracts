// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IValoremClear} from "../interfaces/IValoremClear.sol";
import {IOvercallRegistry} from "../interfaces/IOvercallRegistry.sol";

/// @title ValoremLib
/// @notice The write and redeem mechanics against the Valorem clearinghouse.
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

    error ValoremFeesEnabled(uint8 feeBps);
    error OptionAssetMismatch(address expectedUnderlying, address gotUnderlying);
    error OptionExerciseAssetMismatch(address expectedExercise, address gotExercise);
    error UnexpectedLotSize(uint96 expected, uint96 got);
    error OptionWindowMismatch(uint40 optionExerciseTs, uint40 optionExpiryTs);
    error WriteReturnedNoClaim();

    /*//////////////////////////////////////////////////////////////
                                 WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock collateral into Valorem and mint `n` option contracts plus one claim NFT.
    /// @dev Validates the option against the cycle before any collateral moves.
    /// @return claimId The Valorem claim NFT representing the short position.
    /// @return collateral Asset base units locked.
    function writeCalls(
        IValoremClear clear,
        IERC20 asset,
        address exerciseAsset,
        uint256 optionId,
        uint112 n,
        IOvercallRegistry.Cycle memory cyc,
        bool feeAccepted
    ) public returns (uint256 claimId, uint256 collateral) {
        // Valorem's engine fee is 15 bps of NOTIONAL. On a weekly out-of-the-money call that is a
        // large slice of the premium, so the vault refuses to write while it is on unless
        // governance has explicitly accepted it.
        if (!feeAccepted && clear.feesEnabled()) revert ValoremFeesEnabled(clear.feeBps());

        IValoremClear.Option memory o = clear.option(optionId);
        if (o.underlyingAsset != address(asset)) revert OptionAssetMismatch(address(asset), o.underlyingAsset);
        if (o.exerciseAsset != exerciseAsset) revert OptionExerciseAssetMismatch(exerciseAsset, o.exerciseAsset);
        if (o.underlyingAmount != cyc.lotSize) revert UnexpectedLotSize(cyc.lotSize, o.underlyingAmount);

        // The option's own window must be exactly the cycle's. The deployed registry enforces
        // this in `setCycle`, but the vault must not DEPEND on a third party having done so: the
        // deposit gate rests on "assignment cannot happen before `cycleExerciseTs`", and that is
        // only true if the option actually written shares that timestamp. One comparison against
        // a struct already in memory buys independence from the registry's owner.
        if (o.exerciseTimestamp != cyc.exerciseTimestamp || o.expiryTimestamp != cyc.expiryTimestamp) {
            revert OptionWindowMismatch(o.exerciseTimestamp, o.expiryTimestamp);
        }

        collateral = uint256(n) * uint256(o.underlyingAmount);

        // Size the approval to what the clearinghouse will ACTUALLY pull. When Valorem's engine
        // fee is on it takes 15 bps of notional ON TOP of the collateral, so approving only the
        // collateral makes every write revert on allowance — which is what made the
        // `acceptValoremFee` governance switch still non-functional even after the flag was
        // wired through. `feesEnabled()` has to be read explicitly here, because the guard above
        // short-circuits and never reads it once governance has accepted.
        uint256 approveAmount = collateral;
        if (clear.feesEnabled()) {
            uint256 fee = (collateral * uint256(clear.feeBps())) / 10_000;
            if (fee == 0) fee = 1; // upstream applies the same floor
            approveAmount = collateral + fee;
        }

        // forceApprove resets to zero first, which keeps this safe against tokens that reject a
        // non-zero-to-non-zero approve. The allowance is zeroed again immediately after, so no
        // standing approval to the clearinghouse is ever left behind, including any unconsumed
        // fee headroom.
        asset.forceApprove(address(clear), approveAmount);
        claimId = clear.write(optionId, n);
        if (claimId == 0) revert WriteReturnedNoClaim();
        asset.forceApprove(address(clear), 0);
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
