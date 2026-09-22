// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IBuybackExecutor
/// @notice The swappable half of the buyback: turns USDG into STONKHOUSE and burns it (INTERFACE_VERSION 8,
///         03-INTERFACES §2.10, v8 design §6).
/// @dev WHY IT IS A SEPARATE CONTRACT. The route ends in a Uniswap v4 pool whose key is HOOKED and whose hook is
///      third-party code. That is outside our control, so the executor is replaceable under `TREASURY_ADMIN`'s 24 h
///      lane (`FeeSplitter.setBuybackExecutor`) while the splitter, which holds the money, is not.
///
///      THE ROUTE, PINNED AT CONSTRUCTION: USDG -> WETH on the Uniswap v3 0.01 % pool under a TWAP floor; unwrap;
///      WETH -> STONKHOUSE through ONE immutable v4 `PoolKey` (`fee: 0`, non-zero `hooks`, ETH-quoted); `burn()`.
///      The key is an immutable constructor argument and is never discovered: chain 4663 carries thousands of pools
///      and the hook is part of a pool's identity.
///
///      WHAT IT MUST REFUSE: an observed hook fee above `V2Constants.MAX_HOOK_FEE_BPS` (300), keeping any input
///      past the end of the call, and `tokenOut < minTokenOut`. It holds nothing between calls and has no admin
///      function.
///
///      WHAT THE SPLITTER ENFORCES, AND NOTHING MORE: `FeeSplitter.buyback` caps the spend, enforces
///      `V2Constants.BUYBACK_COOLDOWN`, debits its reserve by the USDG its own balance says was spent (T-429), and
///      requires `burned` to be NON-ZERO and to equal the token's measured total-supply delta. So an executor that reports a burn it did not make fails, and so does one that takes the
///      USDG and burns nothing -- that second case passed on `0 == 0` until the non-zero bound was added.
///      IT DOES NOT PROVE the USDG was spent on the token, that the pinned route was the one taken, or that `burned`
///      is proportionate to `usdgIn`: an executor that keeps most of the spend and burns dust still passes. The bound
///      on that is this contract's own code and the 24 h `TREASURY_ADMIN` lane that replaces it, not that check.
interface IBuybackExecutor {
    /// @notice Spends `usdgIn` on STONKHOUSE along the pinned route and burns everything it bought.
    /// @dev The FeeSplitter only (`V2Errors.NotAuthorized`). The splitter approves exactly `usdgIn` beforehand.
    ///      A hook fee above the compiled ceiling or an output below `minTokenOut` reverts and leaves the splitter's
    ///      balance intact. It MAY SPEND LESS THAN `usdgIn`: the USDG -> WETH leg stops at its price limit when the
    ///      pool runs out of in-range liquidity, and the unspent USDG is transferred back to the splitter inside this
    ///      call. The return tuple does not report the spend, so the splitter measures it as its own USDG balance
    ///      delta across the call rather than debiting `usdgIn` (T-429, F-05-08).
    /// @param usdgIn USDG base units to spend, already capped by the splitter at its per-call cap.
    /// @param minTokenOut Least STONKHOUSE base units the buy must produce; the caller derives it off chain.
    /// @return tokenOut STONKHOUSE base units bought.
    /// @return burned STONKHOUSE base units burned; the splitter rejects zero and checks the rest against the
    ///         total-supply delta it measures itself.
    function execute(uint256 usdgIn, uint256 minTokenOut) external returns (uint256 tokenOut, uint256 burned);
}
