// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IFeeDiscount
/// @notice Optional taker-side fee discount module of the OrderBook (INTERFACE_VERSION 8, v8 design §7). Nothing is
///         set at launch: the seam exists so a discount programme can ship later without redeploying the book.
/// @dev THE BOOK DOES NOT TRUST THE MODULE. `discountBps` is read once per {IOrderBook.take} with a staticcall capped
///      at `V2Constants.DISCOUNT_READ_GAS` (30,000), of whose return data only the first 32 bytes are copied. A
///      revert, a read that runs out of that gas, or short return data all count as 0, and any answer above
///      `V2Constants.MAX_DISCOUNT_BPS` (5,000) is clamped to it. So the worst a module can do is give takers a
///      discount it is not allowed to exceed, plus 30,000 gas per take.
///
///      READ ONCE PER TAKE. `_takerFee` is evaluated at four call sites inside one take and the maker-rebate maths
///      require it to be consistent and non-decreasing within the call (a rebate is a share of the taker fee and
///      would underflow otherwise), so the book reads the discount once, clamps it, and carries it beside the fee
///      parameters for the whole take. A module whose answer moves between two blocks is therefore harmless; one that
///      could move inside a take would not be.
///
///      TAKER SIDE ONLY. The discount reduces `takerFee`: `takerFee = base - base * discountBps / BPS`. Seller fees
///      (the 5 % primary-sale fee and the 0 % resale fee) and the Clearinghouse's exercise fee are untouched, and
///      maker-side boosts already have their own seam in `IMakerRegistry`. With no module set the whole path is one
///      zero-address check.
interface IFeeDiscount {
    /// @notice The taker-fee discount `taker` gets on this take, in basis points of the fee.
    /// @dev Called by the OrderBook as a gas-capped staticcall; see the contract NatSpec for exactly how a failure,
    ///      an out-of-gas or an over-large answer is treated. Must be cheap: 30,000 gas covers about one mapping read.
    /// @param taker The account calling {IOrderBook.take} (never the recipient, and never a maker).
    /// @return Discount in bps of the taker fee, clamped by the book to `V2Constants.MAX_DISCOUNT_BPS`.
    function discountBps(address taker) external view returns (uint16);
}
