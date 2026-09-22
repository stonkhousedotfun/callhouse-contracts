// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IEarnVenueAdapter
/// @notice Where the Earn vault parks its idle assets. One adapter per venue; the vault holds at most one at a
///         time and can run with none, in which case every asset sits in the vault's own balance.
/// @dev DELIBERATELY SMALL. Every function here is one the vault calls on a path that must not be able to
///      surprise it, so the seam is five functions and no callbacks, no hooks and no share token of its own.
///      An adapter is trusted for CUSTODY and not for HONESTY: the vault measures what it actually received,
///      never what an adapter claimed, exactly as the OrderBook measures a funding source's `free` delta
///      rather than its return value ({IFundingSource}).
///
///      THE DISTINCTION THIS INTERFACE EXISTS TO MAKE is {withdrawable} against {totalAssets}. `totalAssets`
///      is what the venue says the position is worth; `withdrawable` is what it can actually hand back IN THIS
///      BLOCK. On a lending venue running near full utilisation those are different numbers most of the time,
///      and the vault's {IFundingSource.fundable} must be derived from the SECOND one. Deriving it from the
///      first -- or from a `previewRedeem`, or from a share balance -- produces a quote the book believes and
///      a take that then skips the maker, which is the silent quote/take divergence the pre-fund design exists
///      to prevent. An adapter that cannot tell the two apart must return the conservative one from both.
///
///      EVERY AMOUNT IS IN THE ASSET'S OWN BASE UNITS ({asset}'s decimals: 6 for USDG, 18 for a Stock Token).
///      No adapter returns shares.
interface IEarnVenueAdapter {
    /// @notice The ERC-20 this adapter takes and returns. Immutable for the life of the adapter.
    /// @dev The vault checks this against its own asset on wiring and refuses a mismatch, so a wrong adapter is
    ///      a failed transaction rather than a silent custody move into a venue denominated in something else.
    function asset() external view returns (address);

    /// @notice Move `assets` base units from the caller into the venue.
    /// @dev The caller transfers first, or the adapter pulls under an allowance -- an implementation states
    ///      which in its own NatSpec. MEASURED, NOT ASSUMED: the return is what the venue actually took, which
    ///      may be less than `assets` on a deposit cap, a fee-on-transfer asset, or a partially paused venue.
    ///      The vault credits the return and never `assets`.
    /// @param assets Base units offered.
    /// @return deposited Base units the venue actually took.
    function deposit(uint256 assets) external returns (uint256 deposited);

    /// @notice Pull up to `assets` base units out of the venue and send them to `to`.
    /// @dev Under-delivery is LEGAL and must not revert: a venue at high utilisation returns what it has, and
    ///      the vault's own callers are built for a short answer (a redemption becomes a queued request; a
    ///      {IFundingSource.fund} simply delivers less and costs the vault only the fills it would have made).
    ///      An adapter that reverts rather than returning less turns a partial answer into no answer at all.
    /// @param assets Base units requested.
    /// @param to Recipient of whatever comes back.
    /// @return withdrawn Base units actually sent to `to`.
    function withdraw(uint256 assets, address to) external returns (uint256 withdrawn);

    /// @notice Base units this venue could return RIGHT NOW, in this block.
    /// @dev NOT the position's value -- see the note on this interface. This is the number
    ///      {IFundingSource.fundable} is derived from, and it is read on the book's quote path under
    ///      `V2Constants.FUNDABLE_READ_GAS` (50,000), so an implementation must answer within a small,
    ///      bounded number of storage reads. An implementation that cannot answer cheaply must return a
    ///      cheaper CONSERVATIVE bound rather than an expensive exact one: running out of gas is read as 0 by
    ///      the book, which is safe but makes the vault invisible to takers.
    function withdrawable() external view returns (uint256);

    /// @notice Base units the venue position is worth, including anything not currently withdrawable.
    /// @dev The vault adds this to its own balance and its Clearinghouse `free` to price shares, so a venue
    ///      loss lands here and is borne pro rata by depositors. It is read on the deposit/redeem path, not on
    ///      the book's quote path, so it may be more expensive than {withdrawable}.
    function totalAssets() external view returns (uint256);
}
