// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IFeeSplitter
/// @notice Where every protocol fee lands in INTERFACE_VERSION 8 (03-INTERFACES §2.9, v8 design §6). Both core
///         contracts are constructed with the splitter as their `feeRecipient`; it converts Stock Token fees to USDG
///         through the `PayoutRouter`, splits the USDG once between a buyback balance and the Treasury Safe, and
///         buys back and burns STONKHOUSE from that balance.
/// @dev INFLOWS. USDG (taker fees, seller fees net of rebate, put exercise fees) and Stock Tokens (call exercise
///      fees, and writer rent if it is ever switched on). `Clearinghouse.sweepFees` PUSHES both, and reverts if the
///      recipient rejects the transfer, so the splitter must accept plain ERC-20 pushes of USDG and of every
///      underlying and must never revert in a receive path. {claimOrderBookFees} pulls whatever a failed push parked
///      in `OrderBook.owed[splitter]`, which only the splitter itself can claim.
///
///      CONVERSION FLOOR COMES FROM THE ORACLE, NEVER FROM A POOL. A fee conversion does not happen at a settlement
///      instant, so the floor is the oracle's SPOT WITH ITS OK FLAG, times `(1 - slippage - routeFeeBps)`. No route or
///      no ok spot means the tokens are HELD in the splitter until a route exists and a skip event is emitted -- they
///      are never dumped at whatever the pool says. Stock is only ever sold for USDG; the only token burned is
///      STONKHOUSE.
///
///      SPLIT ONCE, AT THE MOMENT IT BECOMES USDG. `burnBps` of each conversion (and of each direct USDG
///      distribution) goes to the buyback balance and the rest to the treasury. Stock Tokens held for a later route
///      and the buyback balance itself are never split again, so nothing is ever taxed twice across a floor miss and
///      a retry. `burnBps` is fully adjustable 0..10,000 under `FEE_MANAGER`'s 48 h lane (owner decision V3-D25):
///      there is no compiled bound, and the delay plus the guardian's cancel are the only protection against
///      redirecting the whole flow to the treasury.
///
///      BUYBACK. {buyback} spends `min(buybackBalance, cap)` under a compiled `V2Constants.BUYBACK_COOLDOWN`, calls
///      the executor, and requires the burn to equal the token's measured total-supply delta. The per-call cap is
///      configured (50 USDG at launch) under the compiled `V2Constants.BUYBACK_CAP_CEIL` (1,000 USDG). There is no
///      daily cap, by owner decision.
///
///      EVENT NAMES AND FIELDS match the local flywheel prototype on purpose, so its indexer handlers are reusable.
interface IFeeSplitter {
    /// @notice Pulls whatever the OrderBook parked in `owed[splitter]` after a failed fee push.
    /// @dev Anyone. A zero balance is a no-op. The USDG lands unsplit and is split by the next {distribute}.
    /// @return claimed USDG base units pulled.
    function claimOrderBookFees() external returns (uint256 claimed);

    /// @notice Converts the splitter's whole balance of `asset` to USDG if it can, then splits that USDG once.
    /// @dev Use `FeeSplitter.distributeAmount` when the whole balance is more than the route can clear in one
    ///      swap. It is on the implementation rather than here because this interface's ERC-165 id is pinned.
    /// @dev Anyone. `asset == usdg` skips the conversion and splits directly. A Stock Token is sold through the
    ///      `PayoutRouter` under a floor of the oracle's ok spot less the configured slippage and the route fee; no
    ///      route, no ok spot, a floor miss or a dust balance emits {DistributionSkipped} and holds the tokens.
    ///      Paused by the guardian.
    /// @param asset USDG or a Stock Token the splitter holds.
    /// @return usdgIn USDG base units that were split by this call (0 when it skipped).
    function distribute(address asset) external returns (uint256 usdgIn);

    /// @notice Spends the buyback balance, up to the per-call cap, on STONKHOUSE and burns it.
    /// @dev `BUYBACK` role. Reverts `V2Errors.CooldownActive(readyAt)` inside `V2Constants.BUYBACK_COOLDOWN` of the
    ///      last buy. Calls {IBuybackExecutor.execute} and requires the burned amount to equal the token's measured
    ///      total-supply delta. Paused by the guardian.
    /// @param minTokenOut Least STONKHOUSE base units the buy must produce, derived off chain by the caller.
    /// @return usdgIn USDG base units spent.
    /// @return burned STONKHOUSE base units burned.
    function buyback(uint256 minTokenOut) external returns (uint256 usdgIn, uint256 burned);

    /// @notice Sets the Treasury Safe, which receives the non-buyback share. TREASURY_ADMIN (24 h).
    /// @param treasury_ Treasury Safe address.
    function setTreasury(address treasury_) external;

    /// @notice Sets the OrderBook {claimOrderBookFees} pulls from. TREASURY_ADMIN (24 h).
    /// @param orderBook_ OrderBook address.
    function setOrderBook(address orderBook_) external;

    /// @notice Sets the PayoutRouter Stock Token fees are sold through. TREASURY_ADMIN (24 h).
    /// @param router_ IPayoutRouter address.
    function setRouter(address router_) external;

    /// @notice Sets the buyback executor. TREASURY_ADMIN (24 h).
    /// @dev Its own setter, and its own 24 h lane, because the v4 pool and its hook are outside our control.
    /// @param executor_ IBuybackExecutor address.
    function setBuybackExecutor(address executor_) external;

    /// @notice Sets the share of each USDG distribution that goes to the buyback balance. FEE_MANAGER (48 h).
    /// @dev Any value 0..10_000 (owner decision V3-D25: fully adjustable). There is NO compiled bound, so the 48 h
    ///      delay and the guardian's cancel are the only protection against redirecting the whole flow.
    /// @param burnBps_ Basis points to the buyback balance; the rest goes to the treasury.
    function setBurnBps(uint16 burnBps_) external;

    /// @notice Sets the most USDG one {buyback} may spend. FEE_MANAGER (48 h).
    /// @dev `CeilingExceeded` above `V2Constants.BUYBACK_CAP_CEIL`. Launch value 50 USDG (50_000_000).
    /// @param perCallUsdg USDG base units per call.
    function setBuybackCap(uint256 perCallUsdg) external;

    /// @notice Sets the slippage the Stock Token conversion floor allows. FEE_MANAGER (48 h).
    /// @dev `CeilingExceeded` above `V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS`.
    /// @param bps Basis points below the oracle's ok spot, before the route fee.
    function setConversionSlippageBps(uint16 bps) external;

    /// @notice Pauses or resumes {distribute} and {buyback}. GUARDIAN, instant.
    /// @dev {claimOrderBookFees} and plain ERC-20 pushes are NEVER paused: the splitter must always be able to
    ///      receive, or `Clearinghouse.sweepFees` would revert.
    /// @param paused_ True to pause. Trailing underscore only because {paused} is now also a view on this
    ///        interface, and a parameter of the same name would shadow it.
    function setPaused(bool paused_) external;

    /// @notice The Treasury Safe that receives the non-buyback share.
    /// @return Treasury address.
    function treasury() external view returns (address);

    /// @notice The USDG set aside for buybacks and not yet spent.
    /// @return USDG base units.
    function buybackBalance() external view returns (uint256);

    /// @notice When the last {buyback} ran; the next one is allowed from this plus `V2Constants.BUYBACK_COOLDOWN`.
    /// @return Unix seconds, 0 before the first buyback.
    function lastBuybackAt() external view returns (uint40);

    /// @notice The OrderBook {claimOrderBookFees} pulls a failed fee push out of.
    /// @dev Zero until {setOrderBook} runs, which makes {claimOrderBookFees} a silent no-op returning 0.
    /// @return OrderBook address.
    function orderBook() external view returns (address);

    /// @notice The PayoutRouter Stock Token fees are sold through.
    /// @dev Zero until {setRouter} runs; {distribute} of a Stock Token then skips with reason NO_ROUTE.
    /// @return `IPayoutRouter` address.
    function router() external view returns (address);

    /// @notice The buyback executor {buyback} spends the buyback balance through.
    /// @dev NAMED FOR THE STORAGE, NOT FOR THE SETTER, and deliberately so. The setter frozen in 03-INTERFACES
    ///      §2.9 is {setBuybackExecutor} and the event below is {BuybackExecutorSet}, but the implementation's
    ///      variable is `executor`, so the getter the compiler generates is `executor()`. Renaming the variable
    ///      to match would have to be paired with a hand-written getter or it moves nothing; renaming the setter
    ///      moves a frozen selector. The asymmetry is the cheapest of the three. Do not "fix" it.
    /// @return `IBuybackExecutor` address, zero before it is set.
    function executor() external view returns (address);

    /// @notice The SettlementOracle whose ok spot is the Stock Token conversion floor.
    /// @dev Zero until `setOracle` runs; {distribute} of a Stock Token then skips with reason NO_SPOT.
    ///      `setOracle` itself is NOT in this interface -- it is a TREASURY_ADMIN entry in `script/v2/roles.v8.json`
    ///      so that it is not a silent ADMIN. The read is here anyway, because the source of the floor is exactly
    ///      what an operator has to be able to verify: a swapped oracle is a drainable conversion.
    /// @return `ISettlementOracle` address.
    function oracle() external view returns (address);

    /// @notice The STONKHOUSE token {buyback} burns and measures the total-supply delta of.
    /// @dev Zero until `setToken` runs, which makes {buyback} skip with reason NO_EXECUTOR. Same note as
    ///      {oracle}: the setter is not in this interface, the read is.
    /// @return STONKHOUSE token address.
    function stonkhouse() external view returns (address);

    /// @notice The share of each USDG distribution that goes to the buyback balance.
    /// @dev 0..10_000 with NO compiled bound (owner decision V3-D25); the rest goes to the treasury. Before this
    ///      view existed, "the whole fee flow was redirected to the treasury" was visible only as an
    ///      `OperationScheduled` naming the selector, with no way to read what the split had become.
    /// @return Basis points to the buyback balance.
    function burnBps() external view returns (uint16);

    /// @notice The slippage the Stock Token conversion floor allows, before the route fee is subtracted too.
    /// @return Basis points below the oracle's ok spot.
    function conversionSlippageBps() external view returns (uint16);

    /// @notice The most USDG a single {buyback} may spend.
    /// @return USDG base units; 50_000_000 (50 USDG) at launch, never above `V2Constants.BUYBACK_CAP_CEIL`.
    function buybackCap() external view returns (uint256);

    /// @notice Whether {distribute} and {buyback} are paused.
    /// @dev GUARDIAN's execution delay is 0, so {setPaused} is called DIRECTLY rather than scheduled, and the
    ///      AccessManager emits no `OperationScheduled` / `OperationExecuted` for it. This view and {PausedSet}
    ///      are therefore the only evidence a pause leaves anywhere.
    /// @return True while paused. {claimOrderBookFees} and plain ERC-20 pushes are never paused.
    function paused() external view returns (bool);

    /// @notice `assetIn` base units of `asset` became `usdgIn` USDG, split into `treasuryOut` and `buybackAdded`.
    /// @dev For `asset == usdg`, `assetIn == usdgIn`. `treasuryOut + buybackAdded == usdgIn` always.
    event Distributed(
        address indexed asset, uint256 assetIn, uint256 usdgIn, uint256 treasuryOut, uint256 buybackAdded
    );
    /// @notice {distribute} converted nothing and kept the tokens. `reason` is NO_ROUTE, NO_SPOT, BELOW_FLOOR or DUST.
    event DistributionSkipped(address indexed asset, bytes32 reason);
    /// @notice A buyback spent `usdgIn` USDG base units and received `tokenOut` STONKHOUSE base units.
    event BoughtBack(uint256 usdgIn, uint256 tokenOut);
    /// @notice `amount` STONKHOUSE base units were burned, checked against the token's total-supply delta.
    event Burned(uint256 amount);
    /// @notice {buyback} did nothing. `reason` names which precondition was not met.
    event BuybackSkipped(bytes32 reason);

    /*//////////////////////////////////////////////////////////////
                              ADMIN EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev WHY THESE EXIST. The splitter holds every protocol fee and owns the burn/treasury split, and until
    ///      these events landed NOT ONE of its ten restricted setters emitted anything. The sharpest case is
    ///      {setPaused}: GUARDIAN's execution delay is 0, so the call is made directly instead of being scheduled,
    ///      and the AccessManager records no operation for it either -- a paused splitter was invisible to the
    ///      monitor, the indexer and the site at the same time. After these events a paused splitter is visible
    ///      from logs alone.
    ///
    ///      SHAPE. One event per setter, named `<X>Set` after the setter, carrying only the NEW value, with
    ///      address fields indexed. That is the shape v8 already uses (`TradingPausedSet`, `CreatePausedSet`,
    ///      `MintPausedSet`, `MinterSet`, `DefaultOracleSet`, `TreasurySet`), so an indexer handler written for
    ///      one reads like a handler written for any other.
    ///
    ///      THEY FIRE UNCONDITIONALLY, including on a write that stores the value already there. What an operator
    ///      needs from a log is that the CALL happened, on a contract where the access layer records nothing for
    ///      the zero-delay lanes; a change-only emit would hide exactly the guardian action this task exists to
    ///      surface.
    ///
    ///      {TreasurySet}, {BurnBpsSet} and {BuybackCapSet} are emitted FROM THE CONSTRUCTOR as well, carrying the
    ///      launch values. Without that a log-only reader cannot learn the 50/50 split or the 50 USDG per-call cap
    ///      until somebody happens to change them, and "visible from logs alone" would only be true of the
    ///      settings that had already moved.

    /// @notice The Treasury Safe that receives the non-buyback share is now `treasury`.
    /// @dev Same signature, and so the same topic0, as `IKeeperRewards.TreasurySet` and
    ///      `IRewardsDistributor.TreasurySet`: one handler decodes all three. Also emitted by the constructor.
    event TreasurySet(address indexed treasury);
    /// @notice The OrderBook {claimOrderBookFees} pulls from is now `orderBook`.
    event OrderBookSet(address indexed orderBook);
    /// @notice `amount` USDG base units stayed in `orderBook` when the splitter repointed away from it.
    /// @dev F-05-06. {setOrderBook} drains the old book first, but it does not revert if that fails, because a dead
    ///      old book must not block migration forever. This event is what makes the shortfall visible instead of
    ///      silent: the amount is what `owed[splitter]` said and the splitter did not receive. `amount` is 0 when the
    ///      old book could not even be asked.
    event OrderBookFeesStranded(address indexed orderBook, uint256 amount);
    /// @notice The PayoutRouter Stock Token fees are sold through is now `router`.
    event RouterSet(address indexed router);
    /// @notice The buyback executor is now `executor`.
    /// @dev Named for the frozen setter {setBuybackExecutor}; the matching view is {executor}, named for the
    ///      storage. See {executor} for why the two names differ.
    event BuybackExecutorSet(address indexed executor);
    /// @notice The SettlementOracle supplying the conversion floor is now `oracle`.
    /// @dev NOT called `OracleSet`. `OracleSet(address indexed, bool)` already exists in `ChainlinkFeedSource`,
    ///      `UniV3TwapSource` and `DataStreamsSource`, where it means "this price source is allow-listed". The
    ///      shapes differ, so the topic0s differ and no decoder is ambiguous -- but the NAME would be, and a
    ///      human reading a merged log view would see one label over two unrelated facts. `DefaultOracleSet` in
    ///      `IClearinghouse` is the same move: a singleton oracle pointer given a distinct name beside the
    ///      sources' `OracleSet`.
    event SettlementOracleSet(address indexed oracle);
    /// @notice The STONKHOUSE token {buyback} burns is now `token`.
    /// @dev Named for the storage (`stonkhouse`) rather than for the setter (`setToken`), the way
    ///      `MarketConfigSet` and `RouteSet` are named for what they report rather than for which of several
    ///      setters wrote it. `TokenSet` would say nothing on a contract that handles three tokens.
    event StonkhouseSet(address indexed token);
    /// @notice The buyback share of each distribution is now `burnBps` basis points; the treasury gets the rest.
    /// @dev The one setting with no compiled bound (V3-D25), so this is the only on-chain record of what the
    ///      split actually became. Also emitted by the constructor with the launch value.
    event BurnBpsSet(uint16 burnBps);
    /// @notice The most USDG one {buyback} may spend is now `perCallUsdg` base units.
    /// @dev Also emitted by the constructor with the launch value.
    event BuybackCapSet(uint256 perCallUsdg);
    /// @notice The conversion floor now allows `bps` basis points of slippage, before the route fee.
    event ConversionSlippageBpsSet(uint16 bps);
    /// @notice {distribute} and {buyback} are now paused (`paused` true) or resumed (false).
    /// @dev The guardian acts at delay 0 and the AccessManager logs nothing for it, so this event is the whole
    ///      audit trail of a pause.
    event PausedSet(bool paused);
}
