// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IFundingSource
/// @notice A maker contract that funds its own Clearinghouse ledger just in time, during the OrderBook's pre-fund
///         stage (INTERFACE_VERSION 8, v8 design §8.2). The Earn vault is the first implementor; nothing implements
///         it at launch.
/// @dev WHY THE STAGE IS BEFORE PLANNING, NOT AT FILL TIME. The book decides which orders it can fill inside `_plan`,
///      a `view` shared with {IOrderBook.quoteTake}, out of a per-account `free()` budget cached the first time that
///      account is seen. A callback at delivery time would never be reached: a just-in-time maker would already have
///      been skipped as under-collateralised. So {IOrderBook.take} (never the view) runs a dry plan that ASSUMES
///      funding, totals each funded maker's need per asset, calls {fund}, and only then runs the real plan on real
///      balances.
///
///      THE BOOK NEVER DEPENDS ON THE ANSWER. {fund} is called inside `try` with
///      `V2Constants.FUNDING_GAS` (400,000) and at most `V2Constants.MAX_FUNDED_MAKERS_PER_TAKE` (4) makers are funded
///      in one take; further funded makers are planned without funding. Delivery is measured as the maker's `free`
///      delta, not as the return of the call. Under-delivery or a revert simply leaves that maker's orders skipped,
///      which is exactly what an under-collateralised `AskWrite` does today. The book's reentrancy guard is held for
///      the whole take, so a source cannot re-enter `place`, `cancel` or `take`; depositing into the Clearinghouse is
///      the only thing it needs and the only thing it can do.
///
///      OPT-IN IS TWO-SIDED. `CONFIG_ADMIN` allows a maker (`setFundingAllowed`, 24 h lane) and the maker then turns
///      funding on for itself (`setFunding`). An EOA cannot: the book calls {fundable} when funding is switched on and
///      requires it to answer.
///
///      LOCKED COLLATERAL NEVER LEAVES THE CLEARINGHOUSE. A funding source deposits into ITS OWN ledger account;
///      settlement and redemption never depend on it. A venue freeze means the source quotes less, not that a series
///      breaks.
interface IFundingSource {
    /// @notice Base units of `asset` this source could still deliver into its own Clearinghouse ledger right now.
    /// @dev Read by {IOrderBook.quoteTake} as a staticcall capped at `V2Constants.FUNDABLE_READ_GAS` (50,000); a
    ///      revert, an out-of-gas or short return data counts as 0. Added to the maker's `free()` budget, so a quote
    ///      is exact unless the source misreports itself -- and the taker's `minUnits` protects them either way.
    /// @param asset USDG or the series' 18-dp underlying.
    /// @return Asset base units available, an upper bound this source expects to honour in the same block.
    function fundable(address asset) external view returns (uint256);

    /// @notice Deposits up to `amount` of `asset` into this source's OWN Clearinghouse ledger account.
    /// @dev The OrderBook only, inside {IOrderBook.take}, before planning, with a gas cap and inside `try`. Delivering
    ///      less than `amount`, or reverting, is allowed and costs only the fills this maker would have made. The
    ///      book measures what arrived as the source's `free(asset)` delta and emits `Funded` or `FundingFailed`.
    ///      Implementors must not assume they are the only funded maker in the take.
    /// @param asset USDG or the series' 18-dp underlying.
    /// @param amount Asset base units the book needs from this maker for its planned fills.
    function fund(address asset, uint256 amount) external;
}
