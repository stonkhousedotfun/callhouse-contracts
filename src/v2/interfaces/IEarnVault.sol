// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IEarnVault
/// @notice The Earn vault's own surface: shares for one ERC-20 asset, a disclosing withdrawal queue, and a bounded
///         yield skim to the FeeSplitter (INTERFACE_VERSION 8, v8 design §8.2). The vault ALSO implements the frozen
///         {IFundingSource}; that half is declared there and is deliberately not repeated here.
/// @dev UNITS (ADR-04). `assets` are the vault asset's own base units (6 dp for USDG). `shares` are this contract's
///      ERC-20, 18 dp, minted against a MEASURED {totalAssets}. `bps` are of `V2Constants.BPS` = 10_000.
///
///      THREE PROPERTIES THIS INTERFACE EXISTS TO NAME, because each one is the kind of thing an implementation can
///      get plausibly, silently wrong:
///
///      1. A REDEMPTION THE VENUE CANNOT COVER IS QUEUED, NEVER REVERTED. {redeem} always succeeds: it either pays
///         now or returns a non-zero `requestId` and emits {WithdrawalQueued} carrying the shortfall. Reverting a
///         withdrawal as the whole liquidity story tells a holder nothing and tells the chain nothing.
///      2. A QUEUED EXIT IS PRICED WHEN IT IS SERVED, NOT WHEN IT IS REQUESTED. The shares are escrowed in the vault
///         and stay in `totalSupply` while they wait, so a loss that lands between request and service is borne by
///         the queued holder exactly as it is by everyone else. Pricing at request time would make the queue a way
///         to step out of a loss ahead of the depositors who stayed.
///      3. THE SKIM IS CHARGED ON GAIN, NEVER ON A BALANCE. {skim} compares assets-per-share against a stored
///         {highWaterMark} and charges only the excess, bounded by a compiled ceiling. A skim taken off a balance
///         is a skim taken out of principal, and it looks identical in a test where the vault only ever gains.
interface IEarnVault {
    /// @notice A withdrawal that could not be paid when it was asked for. Priced when served, never now.
    /// @dev `shares` is what is still escrowed for this request; a partial service reduces it and the entry stays at
    ///      the head of the queue. `shares == 0` means served in full or cancelled.
    /// @notice ONE queue entry, in ONE FIFO, for BOTH directions. T-184: a written series makes the share price
    ///         unmeasurable, so a deposit that arrives then has to wait exactly as a redemption does.
    /// @dev WHICH DIRECTION AN ENTRY IS, and it is an invariant rather than a convention: a REDEMPTION has
    ///      `shares != 0` and `assets == 0`; a queued DEPOSIT has `assets != 0` and `shares == 0`. NEVER BOTH, and
    ///      {EarnVault} never writes an entry with both set. An entry with both zero is spent or cancelled and the
    ///      next {IEarnVault.processQueue} that reaches it drops it. Reading `shares` alone, as every pre-T-184
    ///      caller did, therefore sees a queued deposit as an empty slot -- which is why `deposit` itself had to
    ///      change shape rather than quietly returning zero.
    struct Request {
        address owner; // who may cancel it, and who the escrowed shares or assets came from
        address receiver; // who the assets (or the minted shares) go to when it is served
        uint256 shares; // escrowed shares still owed -- a REDEMPTION entry
        uint256 assets; // escrowed assets still to be minted against -- a DEPOSIT entry
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice `caller` paid `assets` base units in and `receiver` got `shares`.
    /// @dev `assets` is the MEASURED balance delta, not the argument, so a fee-on-transfer asset credits what arrived.
    event Deposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    /// @notice `shares` were burned for `assets` base units, paid straight away.
    event Redeemed(address indexed owner, address indexed receiver, uint256 shares, uint256 assets);
    /// @notice A redemption could not be paid now, so it was QUEUED as `id`. THE DISCLOSING EVENT.
    /// @dev `shortfall` is the base units missing at the moment of the request (what was owed minus what the vault
    ///      and the venue could hand over). It is reported for operators and is NOT the amount that will be paid:
    ///      the request is priced again, from scratch, when {processQueue} serves it.
    event WithdrawalQueued(
        uint256 indexed id, address indexed owner, address indexed receiver, uint256 shares, uint256 shortfall
    );
    /// @notice Queue entry `id` was served with `shares` burned for `assets`. `complete` is false on a partial
    ///         service, where the entry keeps its place at the head of the queue.
    event WithdrawalServed(uint256 indexed id, address indexed receiver, uint256 shares, uint256 assets, bool complete);
    /// @notice Queue entry `id` was withdrawn by its owner; the escrowed shares went back. The holder keeps the
    ///         exposure, so cancelling is not an escape from a loss either.
    event WithdrawalCancelled(uint256 indexed id, address indexed owner, uint256 shares);

    /// @notice A deposit could not be priced now, so it was QUEUED as `id`. THE DISCLOSING EVENT for T-184.
    /// @dev `assets` is the MEASURED balance delta held in escrow, not the argument. Escrowed assets are NOT part
    ///      of {IEarnVault.totalAssets} while they wait: they belong to the depositor until the entry is served.
    event DepositQueued(uint256 indexed id, address indexed owner, address indexed receiver, uint256 assets);
    /// @notice Queued deposit `id` was served: `assets` minted `shares` at the share price of the serving block.
    event DepositServed(uint256 indexed id, address indexed receiver, uint256 assets, uint256 shares);
    /// @notice Queued deposit `id` was cancelled and its escrowed `assets` returned to `owner`.
    event DepositCancelled(uint256 indexed id, address indexed owner, uint256 assets);
    /// @notice A skim ran. `gain` is the realised gain above the old mark in asset base units, `fee` is what went to
    ///         the splitter, `highWaterMark` is the mark left behind. A flat or losing period emits `gain == 0` and
    ///         `fee == 0` rather than nothing, so an operator can tell "ran and took nothing" from "never ran".
    event Skimmed(uint256 gain, uint256 fee, uint256 highWaterMark);
    /// @notice The venue adapter changed. `adapter` is the zero address when the vault runs with no venue at all.
    event AdapterSet(address indexed adapter);
    /// @notice The yield skim rate changed, bps of realised gain.
    event SkimBpsSet(uint16 bps);
    /// @notice `deposited` base units of `offered` actually went into the venue (MEASURED from the adapter's return).
    event SweptToVenue(uint256 offered, uint256 deposited);
    /// @notice `withdrawn` base units of `requested` actually came back out of the venue (MEASURED as this vault's
    ///         own balance delta, never the adapter's return).
    event PulledFromVenue(uint256 requested, uint256 withdrawn);
    /// @notice Just-in-time funding was switched on or off for this vault.
    event FundingEnabledSet(bool on);
    /// @notice The OrderBook asked for `requested` base units of `asset` in the pre-fund stage and this vault
    ///         deposited `delivered` into its own Clearinghouse ledger. `delivered == 0` is a legal answer and is
    ///         emitted rather than reverted -- see {IFundingSource}.
    event Funded(address indexed asset, uint256 requested, uint256 delivered);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice An AskWrite would take the vault's written units on one series -- resting AskWrite orders plus open
    ///         shorts, net of longs it holds there -- to `wouldBe`, above `ceiling`
    ///         (`EarnVault.MAX_WRITTEN_UNITS_PER_SERIES`). T-OP-039: the aggregate bound this vault was missing;
    ///         `EarnVault.MAX_ORDER_NOTIONAL` bounds one order only.
    error WrittenUnitsExceeded(uint256 wouldBe, uint256 ceiling);
    /// @notice An AskWrite would take the vault's written notional summed over every series it is short or resting a
    ///         write on to `wouldBe` asset base units, above `ceiling` (EarnVault.MAX_WRITTEN_NOTIONAL). T-OP-039.
    error WrittenNotionalExceeded(uint256 wouldBe, uint256 ceiling);
    /// @notice {convertToShares} / {convertToAssets} were asked for a price while the vault holds an option position
    ///         (an open short, a long, or resale escrow). The flat-NAV price is only knowable at the boundary; a
    ///         number quoted meanwhile would be the understated {totalAssets} dressed as a price. T-OP-065 (SEC-19,
    ///         owner ruling 2026-09-22): fail loud rather than lie. {indicativeAssetsPerShare} is the display figure.
    error PositionOpen();

    /*//////////////////////////////////////////////////////////////
                             DEPOSIT / REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @notice Pays `assets` base units in and mints shares to `receiver`.
    /// @param assets Base units to pull from `msg.sender` (approve the vault first).
    /// @param receiver Who gets the shares.
    /// @return shares Shares minted.
    /// @dev THE SELECTOR IS UNCHANGED, BY OWNER RULING 2026-09-20 on question Q-76a519afccce44c2, and the return
    ///      value now carries a second meaning that callers MUST handle. A deposit into a flat vault mints and
    ///      returns the shares, as before. A deposit that arrives while the vault has a written series outstanding
    ///      QUEUES instead of pricing and RETURNS ZERO -- it has not failed, and the assets are escrowed, not lost.
    ///
    ///      A ZERO RETURN IS NO LONGER ONLY AN ERROR, WHICH IS THE WHOLE RISK OF KEEPING THIS SELECTOR. Before
    ///      T-184 the only zero here was a rounding failure, and it reverted `BadUnits` rather than returning. Now
    ///      zero means "queued": a caller that reads it as failure and retries will escrow a SECOND deposit.
    ///      THE REQUEST ID IS LEARNED ONLY FROM {DepositQueued}; there is no return channel for it. Callers that
    ///      need the id must read the event, and callers that branch on the return value must consult
    ///      {IEarnVault.hasOpenShort} to tell a queue from a failure.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Burns `shares` for their pro-rata assets, or QUEUES the request when the vault cannot pay now.
    /// @dev NEVER REVERTS FOR LACK OF LIQUIDITY. `requestId == 0` means it was paid in this call; otherwise the
    ///      shares are escrowed, {WithdrawalQueued} is emitted, and the exit is priced when it is served.
    /// @param shares Shares to redeem, held by `msg.sender`.
    /// @param receiver Who the assets go to.
    /// @return assets Base units paid in this call; 0 when the request was queued.
    /// @return requestId Queue id, or 0 when it was paid now.
    function redeem(uint256 shares, address receiver) external returns (uint256 assets, uint256 requestId);

    /// @notice Serves up to `maxEntries` queued withdrawals, oldest first. PERMISSIONLESS.
    /// @dev Each entry is priced at the share price OF THIS MOMENT. Stops at the first entry the vault cannot pay
    ///      in full, after paying that entry whatever it can -- the queue is FIFO and is never stepped over.
    /// @param maxEntries Bound on the work this call does; 0 does nothing.
    /// @return served Entries paid in full by this call.
    function processQueue(uint256 maxEntries) external returns (uint256 served);

    /// @notice Takes a queued request back and returns its escrowed shares. The request's owner only.
    /// @param id Queue id.
    function cancelQueued(uint256 id) external;

    /*//////////////////////////////////////////////////////////////
                                  SKIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Charges the yield skim on realised gain above {highWaterMark} and sends it to the FeeSplitter.
    ///         PERMISSIONLESS.
    /// @dev Takes ZERO on a flat or losing period, and takes nothing at all when the fee cannot be paid in full --
    ///      in that case the mark is left where it was, so a caller cannot burn the protocol's claim on a gain by
    ///      calling this while the venue is frozen.
    /// @return fee Base units sent to the splitter.
    function skim() external returns (uint256 fee);

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The ERC-20 this vault takes deposits in and pays withdrawals in.
    function asset() external view returns (address);

    /// @notice Every asset this vault owns, MEASURED: its own balance, its free Clearinghouse ledger, and the venue.
    /// @dev NOT a funding answer. {IFundingSource.fundable} is derived from the venue's `withdrawable`, never from
    ///      this: a venue at high utilisation is worth a lot and can return nothing.
    /// @dev WHAT THIS MEASURES AND WHAT IT CANNOT, written out because a stale sentence here is how the T-184
    ///      defect survived review. It is the vault's own wallet balance plus its FREE Clearinghouse ledger plus
    ///      the venue, MINUS assets escrowed by queued deposits, which are the depositors' and not the vault's.
    ///      THE FREE LEDGER EXCLUDES COLLATERAL LOCKED BEHIND A WRITTEN SERIES, so while the vault has a short
    ///      outstanding this number is UNDERSTATED by that collateral and no continuous correction exists -- face
    ///      value overstates it by the whole obligation and only a mark could find the value between, which is
    ///      exactly the quoter-supplied mark that must never move the share price. That is why deposits and
    ///      redemptions QUEUE while a series is written rather than pricing against this number: see
    ///      {IEarnVault.hasOpenShort}. For a CALL the collateral is the UNDERLYING, which none of these terms ever
    ///      counted, so this is not merely understated but blind to it -- tracked separately, not here.
    /// @dev SEC-19 / F-CP-03 (T-OP-026): THE MISSING TERM IS BY DESIGN, NOT AN OMISSION, and it stays missing. The
    ///      review offered a "conservative" term -- locked collateral minus the worst-case payout, capped at locked --
    ///      and for a FULLY COLLATERALISED write, the only kind this vault makes, that term is identically zero: a
    ///      cash-secured put can lose its whole strike collateral and a covered call its whole stock. So the choice
    ///      is between this number and a mark, and a mark is what the paragraph above forbids. What makes the
    ///      understated number SAFE is that nothing settles at it: every mint, burn and fee is priced at a flat NAV
    ///      (the boundary above; `test/v2/unit/EarnVaultNav.t.sol` pins each price to the base unit). The one
    ///      consequence a caller CAN observe is that {convertToShares} and {convertToAssets} quote the understated
    ///      rate while a position is open -- they are quotes of this number, not prices anyone is paid.
    function totalAssets() external view returns (uint256);

    /// @notice Shares `assets` base units would buy at the current price.
    /// @dev Reverts PositionOpen while the vault holds an option position: {totalAssets} is then the understated
    ///      flat-NAV floor, and a quote off it is a number, not a price anyone is paid (T-OP-065). Integrators read
    ///      ERC-4626-shaped views as prices, so the view refuses instead of answering. {indicativeTotalAssets} is
    ///      the display figure for that interval.
    function convertToShares(uint256 assets) external view returns (uint256);

    /// @notice Base units `shares` are worth at the current price.
    /// @dev Reverts PositionOpen while the vault holds an option position; see {convertToShares}.
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice DISPLAY ONLY. {totalAssets} plus, for every open short collateralised in this vault's asset, the
    ///         collateral it locks less the option's intrinsic value at the series oracle's spot, per unit, floored
    ///         at zero: `Σ units x max(collateralPerUnit - grossPayoutPerUnit(spot), 0)`. Longs held and resale
    ///         escrow contribute nothing; a short with no usable spot contributes nothing (its whole collateral is
    ///         treated as intrinsic); mint rent already paid is not added back.
    /// @dev A MARK, and therefore NEVER A PRICE: no deposit, redeem, queue service, skim or boundary reads it
    ///      ({totalAssets} NatSpec, T-OP-026). It exists so an app can show a holder what their shares are
    ///      approximately worth while {convertToAssets} refuses. Conservative in every branch (T-OP-065).
    function indicativeTotalAssets() external view returns (uint256);

    /// @notice DISPLAY ONLY. {indicativeTotalAssets} per 1e18 shares, base units; 0 with no supply. See
    ///         {indicativeTotalAssets} for what it is and is not.
    function indicativeAssetsPerShare() external view returns (uint256);

    /// @notice Assets per 1e18 shares at the last skim, base units. The skim charges only above this.
    function highWaterMark() external view returns (uint256);

    /// @notice Yield skim rate, bps of realised gain.
    function skimBps() external view returns (uint16);

    /// @notice The venue adapter, or the zero address when the vault holds everything itself.
    function adapter() external view returns (address);

    /// @notice Next queue id to be served and the last one issued. The queue is empty when `head > tail`.
    function queue() external view returns (uint256 head, uint256 tail);

    /// @notice True while the vault still holds a short on at least one series it wrote.
    /// @dev THE FLAT BOUNDARY, T-184. While this is true the share price is unmeasurable, so {deposit} and
    ///      {redeem} queue and {processQueue} serves nothing. It is pruned lazily against the vault's own ERC-1155
    ///      short balance, so a series that settled stops counting the first time any of those is called.
    function hasOpenShort() external view returns (bool);

    /// @notice Assets held in escrow for queued deposits. Excluded from {totalAssets}.
    function escrowedAssets() external view returns (uint256);

    /// @notice A queue entry. `owner == address(0)` for an id that was never issued or is fully served.
    function request(uint256 id) external view returns (Request memory);

    /// @notice The book's compiled just-in-time funding budget, re-exported from `V2Constants` so the indexer, the
    ///         quoter and the monitor MIRROR the contract instead of retyping three numbers.
    /// @return fundGas `V2Constants.FUNDING_GAS`.
    /// @return fundableReadGas `V2Constants.FUNDABLE_READ_GAS`.
    /// @return maxFundedMakers `V2Constants.MAX_FUNDED_MAKERS_PER_TAKE`.
    function fundingBudget() external pure returns (uint256 fundGas, uint256 fundableReadGas, uint256 maxFundedMakers);
}
