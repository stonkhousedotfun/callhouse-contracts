// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Managed} from "../../access/Managed.sol";
import {OptionMath} from "../../lib/OptionMath.sol";
import {IClearinghouse} from "../../interfaces/IClearinghouse.sol";
import {IEarnVault} from "../../interfaces/IEarnVault.sol";
import {V2Ids} from "../../interfaces/V2Ids.sol";
import {IEarnVenueAdapter} from "../../interfaces/IEarnVenueAdapter.sol";
import {IFundingSource} from "../../interfaces/IFundingSource.sol";
import {IOrderBook} from "../../interfaces/IOrderBook.sol";
import {ISettlementOracle} from "../../interfaces/ISettlementOracle.sol";
import {V2Constants} from "../../interfaces/V2Constants.sol";
import {V2Errors} from "../../interfaces/V2Errors.sol";
import {V2Types} from "../../interfaces/V2Types.sol";

/// @title EarnVault
/// @notice The Earn vault (INTERFACE_VERSION 8, v8 design §8.2): depositors pay one ERC-20 in and get shares, the
///         idle balance is parked in a pluggable venue, the vault rests AskWrite orders on the OrderBook as the
///         maker of record, and the book's pre-fund stage pulls assets back out of the venue JUST IN TIME through
///         the frozen {IFundingSource}.
/// @dev UNITS (ADR-04). `assets` are the vault asset's base units (6 dp for USDG); `shares` are this ERC-20, 18 dp;
///      `units` are 0.01-share option units; `bps` are of `V2Constants.BPS`.
///
///      WHO CAN DO WHAT (INTERFACE_VERSION 8). The vault holds no role table: it is {Managed}, and one
///      `AccessManager` maps (this contract, selector) to a role id. The house modifier order is
///      `external nonReentrant restricted`, and `restricted` is NOT view-safe.
///        - ANYONE: {deposit}, {redeem}, {processQueue}, {cancelQueued} (its own request only) and {skim}. {skim} is
///          permissionless on purpose: it can only move a bounded fee to the one immutable {splitter}, and making it
///          permissionless means a stalled operator cannot let a fee accrue unbooked.
///        - QUOTER (role 9): {place}, {cancel}, {depositToClearinghouse}, {withdrawFromClearinghouse},
///          {sweepToVenue}, {pullFromVenue}, {refreshApprovals}.
///        - CONFIG_ADMIN (role 3): {setFundingEnabled}, {setBookFunding}.
///        - OPS_ADMIN (role 6): NOTHING. Owner ruling G returns OPS_ADMIN to zero target selectors, and T-253
///          completed that by moving {refreshApprovals} -- the one selector the ruling's list did not name --
///          to QUOTER, MIRRORING `MakerVault.refreshApprovals` and `HouseVault.refreshApprovals`, which are both
///          QUOTER in the same manifest. OPS_ADMIN is the no-timelock Safe and is key-rotation-only.
///        - TREASURY_ADMIN (role 4): {setAdapter}, {setSkimBps}.
///
///      THE MANIFEST IS THE ONE THAT BINDS, AND THE TABLE THAT USED TO BE COPIED HERE IS GONE ON PURPOSE. T-103
///      left an "INTENDED `script/v2/roles.v8.json` MAPPING" list in this comment because `script/` was out of its
///      scope at the time. The `EarnVault` block landed with T-219 and T-253, and that copied list had already
///      drifted from it in three rows -- it still showed `setFundingEnabled` and `setBookFunding` as OPS_ADMIN when
///      the manifest maps both to CONFIG_ADMIN, and `refreshApprovals` as OPS_ADMIN after the move. A second table
///      that nothing reads is a sentence that goes quietly false, so the bullets above are the only role note kept
///      here and `script/v2/roles.v8.json` is authoritative. An unmapped `restricted` selector falls to ADMIN by
///      default (06-QUIRKS §A.8) rather than reverting, which is why the mapping is proved rather than described:
///      `test/v2/unit/AccessMatrix.t.sol` walks the manifest against the live fixture and fails by name.
///
///      THE FOUR THINGS THIS CONTRACT IS BUILT TO GET RIGHT. Each of them passes a naive test and is wrong exactly
///      when it matters.
///
///      1. `fundable` IS DERIVED FROM WHAT THE VENUE CAN RETURN IN THIS BLOCK, NEVER FROM WHAT IT IS WORTH.
///         {fundable} reads `IEarnVenueAdapter.withdrawable()` and this vault's own token balance, and NOTHING else:
///         no {totalAssets}, no `convertToAssets`, no `previewRedeem`, no share balance. A nominal answer is right
///         against a mock venue that always pays and wrong against a lending venue at high utilisation, which is
///         most of the time; the book would quote a maker it then has to skip, which is the silent quote/take
///         divergence the whole pre-fund design exists to prevent ({IEarnVenueAdapter}).
///         GAS. The read is: one immutable compare, two packed SLOADs (the queue pointers), one SLOAD for the flag,
///         one SLOAD for the adapter, one `balanceOf` staticcall and one `withdrawable` staticcall -- around 15,000
///         gas plus the adapter's own, inside `V2Constants.FUNDABLE_READ_GAS`. It is a CONSERVATIVE BOUND by
///         construction and never an optimistic one: it ignores the vault's free Clearinghouse ledger (already in
///         the book's own budget), ignores anything the venue holds but cannot return, and answers 0 outright while
///         a withdrawal queue is open. Running out of gas here would be read as 0 by the book, which is safe but
///         makes the vault invisible to takers, so nothing on this path may ever grow a loop.
///      2. THE SKIM IS CHARGED ON REALISED GAIN, NEVER ON A BALANCE. {skim} compares assets-per-share against
///         {highWaterMark} and charges {skimBps} of the excess, bounded by the compiled {SKIM_BPS_CEIL}. A flat or
///         losing period takes ZERO. The mark is per SHARE, not on total assets, because a deposit raises total
///         assets without earning anybody anything -- a mark on the total would skim principal on every deposit and
///         would look perfectly healthy in any test where the vault only ever gains.
///         DELIVERY IS A PLAIN `safeTransfer` TO {splitter}. `FeeSplitter.distribute` is permissionless and
///         balance-based (`_pendingUsdg()` = `balanceOf(this) - buybackBalance`), so this needs no interface, no
///         allowance and no callback.
///      3. A QUEUED EXIT IS PRICED WHEN IT IS SERVED. The escrowed shares stay in `totalSupply` while they wait, so
///         a loss landing between request and service is borne by the queued holder like everyone else. Pricing at
///         request time would turn the queue into a way to step out of a loss ahead of the depositors who stayed.
///         The queue is FIFO and {processQueue} is permissionless; {redeem} QUEUES with a disclosing event rather
///         than reverting, and once a queue is open every later redemption joins it rather than stepping over it.
///      4. {fund} NEVER REVERTS ON UNDER-DELIVERY. The book measures delivery as this vault's Clearinghouse `free`
///         DELTA, not as a return value, and a revert costs the vault EVERY fill in that take instead of some of
///         them. So a short pull, a frozen venue, a missing adapter and a wrong asset all return normally with
///         `delivered == 0` in {Funded}. The only revert is `NotAuthorized` for a caller that is not the immutable
///         {orderBook}.
///
///      NO NEW ERROR (T-103 AC-12). `V2Errors` is exported as one shared ABI, so adding an error there is an
///      interface change. Everything here reverts with an error that already exists: `NotAuthorized`,
///      `UnsupportedAsset`, `BadUnits`, `CeilingExceeded`, `InsufficientCollateral`, `NoSource`.
///
///      FIRST DEPOSITOR. MIRRORED from `HouseVault` (src/v2/periphery/house/HouseVault.sol:474-481): the first
///      deposit is priced at a FIXED 1 share per 1 asset base unit -- never at a rate derived from {totalAssets} --
///      and {MIN_SHARES} shares are credited to {DEAD_SHARES}. OZ ERC20 `_mint` reverts `ERC20InvalidReceiver` on
///      `address(0)` (lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol:214-217), so the burn address is
///      {DEAD_SHARES} (`address(0xdead)`) rather than `address(0)`. The fixed rate is what makes the classic
///      inflation attack pointless: assets donated before the first deposit raise everybody's share price and buy
///      the donor nothing. The dead shares then block the follow-up, where a 1-wei first depositor donates a large
///      balance and rounds every later depositor down to zero shares.
///
///      MEASURED, NEVER ASSUMED. Every asset movement in this contract is credited from a balance delta or a
///      clamped, re-read balance: an adapter is trusted for custody and not for honesty ({IEarnVenueAdapter}), and
///      a fee-on-transfer or partially paused venue must cost its own depositors and nobody else.
contract EarnVault is IEarnVault, IFundingSource, ERC20, IERC1155Receiver, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Dead-share sink. OZ ERC20 `_mint` refuses `address(0)` (`ERC20InvalidReceiver`); HouseVault's
    ///         `_mint(address(0), MIN_SHARES)` is unreachable on this OZ revision. MIRRORED intent from
    ///         `HouseVault.MIN_SHARES` (src/v2/periphery/house/HouseVault.sol:147).
    address public constant DEAD_SHARES = address(0xdead);

    /// @notice Dead shares credited to {DEAD_SHARES} on the first deposit. MIRRORED from `HouseVault.MIN_SHARES`
    ///         (src/v2/periphery/house/HouseVault.sol:147).
    uint256 public constant MIN_SHARES = 1e3;

    /// @notice Bps of spot subtracted from intrinsic value when computing the ask floor. ZERO here, deliberately.
    /// @dev The siblings read this from a stored `Limits` struct written at deploy time (`DeployV8.s.sol:365`,
    ///      `DevDeploy.s.sol:880`, which defaults it to 100). This vault has no such struct, and a tolerance is a
    ///      TUNED value, not a derivable one - inventing a compiled number would be the re-reasoning this
    ///      workspace forbids. Zero is the strictest sound setting and needs no tuning to be correct. A
    ///      configurable tolerance is a deliberate follow-up, not an oversight; it needs an owner for the numbers.
    ///
    ///      SEC-05 did NOT change this side. {MAX_BID_BPS_OF_SPOT} now carries a non-zero compiled number, but
    ///      that number is MIRRORED from the value the siblings are deployed with rather than invented, so the
    ///      rule stated above still holds: nothing here is re-reasoned. The ask floor is untouched.
    uint16 public constant ASK_TOLERANCE_BPS = 0;

    /// @notice Time value a bid may pay ON TOP OF intrinsic value, bps of spot. The bid bound is
    ///         `intrinsic + spot * MAX_BID_BPS_OF_SPOT / BPS`, not a fraction of spot on its own.
    /// @dev SEC-05. This was `uint16(V2Constants.BPS)` -- a bid capped at 100 % of SPOT -- and that is not the
    ///      strict bound its old comment claimed. `spot` is the price of the UNDERLYING SHARE while `price` is an
    ///      option premium, so 100 % of spot let a QUOTER key rest a bid at the whole share price for one option.
    ///      A quoter could rest a bid at price == spot on a deep-OTM put (the strike floor of spot/2 is allowed by
    ///      `Clearinghouse.sol:475`) and have an accomplice write into it: premium about spot/100 against a maximum
    ///      payout of about spot/200. That is a heavily favourable bet for the accomplice rather than guaranteed
    ///      arbitrage -- it loses if spot halves inside the hour -- but the vault is on the wrong side of it and
    ///      the rail is armed: `script/v2/roles.v8.json:217` maps
    ///      `place(uint256,uint8,uint128,uint64,uint40)` to QUOTER, so the delay-0 hot key can quote today.
    ///
    ///      THE NUMBER IS MIRRORED, NOT REASONED. 1_000 bps is the `maxBidBpsOfSpot` the siblings are actually
    ///      deployed with (`script/v2/DevDeploy.s.sol:868`, `MM_MAX_BID_BPS_OF_SPOT` default 1_000), which
    ///      `MakerVault._checkPrice` (src/v2/mm/MakerVault.sol:762) and `HouseVault._checkPrice`
    ///      (src/v2/periphery/house/HouseVault.sol:966) apply to the identical capability.
    ///
    ///      THE SHAPE IS NOT THE SIBLINGS' AND THAT IS DELIBERATE. They bound a bid at `spot * bps / BPS` with no
    ///      intrinsic term, which forbids buying back a deep-ITM option at anything near fair value. Adding
    ///      intrinsic keeps a fair buy-back legal while bounding the only part a quoter can overpay -- the time
    ///      value. It is strictly tighter than the old bound at every strike.
    uint16 public constant MAX_BID_BPS_OF_SPOT = 1_000;

    /// @notice Compiled ceiling of {skimBps}: 10 % of realised gain (v8 design §8.2). A configured rate above this
    ///         reverts `CeilingExceeded`, so no key can ever raise the skim past it.
    uint16 public constant SKIM_BPS_CEIL = 1_000;

    /// @notice Most live orders the vault keeps on one series; {place} reverts `CeilingExceeded` beyond it. MIRRORED
    ///         from `MakerVault.MAX_LIVE_ORDERS_PER_SERIES` (src/v2/mm/MakerVault.sol:159), for the same reason:
    ///         it bounds the gas of every live-order scan.
    uint256 public constant MAX_LIVE_ORDERS_PER_SERIES = 16;

    /// @notice Most series the vault may hold orders on at once; {place} on a new series reverts `CeilingExceeded`
    ///         beyond it, after first dropping series with nothing left in the book. T-299.
    /// @dev WHY IT EXISTS: {totalAssets} now reads the vault's refundable Bid escrow out of the book by walking every
    ///      tracked order id (see {_bookEscrow}), and {totalAssets} sits on {deposit}, {redeem}, {processQueue},
    ///      {convertToShares} and {convertToAssets}. An unbounded walk there could brick all of them. The walk is
    ///      at most `MAX_ORDER_SERIES * MAX_LIVE_ORDERS_PER_SERIES` = 128 ids in ONE {IOrderBook.getOrders} call.
    ///      WHAT IT COSTS: the quoter can rest orders on at most 8 series at once, and each NAV read pays that
    ///      walk -- about 128 cold order reads the first time in a transaction, warm thereafter.
    uint256 public constant MAX_ORDER_SERIES = 8;

    /// @notice The window {MAX_DAILY_OUTFLOW} refills over: a full bucket refills linearly in this much time.
    ///         MIRRORED from `MakerVault.OUTFLOW_WINDOW` (src/v2/mm/MakerVault.sol:199).
    uint256 public constant OUTFLOW_WINDOW = 1 days;

    /// @notice Net asset base units the quoting path may pay out at once before {place} reverts
    ///         `OutflowCapExceeded`; refills linearly per {OUTFLOW_WINDOW}.
    /// @dev SEC-05. MIRRORED from the `maxDailyOutflow` the siblings are deployed with
    ///      (`script/v2/DevDeploy.s.sol:871`, `MM_MAX_DAILY_OUTFLOW` default 2_500e6) and from the leaky bucket
    ///      behind it (`MakerVault.sol:214`, `:658`). This is the load-bearing bound of this row: the price check
    ///      bounds ONE order, the bucket bounds what every order together can move out per day.
    ///
    ///      COMPILED RATHER THAN SETTABLE, AND THAT IS A SCOPE LIMIT, NOT A DESIGN CLAIM. The siblings read this
    ///      from a `Limits` struct a key may rewrite. This vault has no such struct, and a setter would need a new
    ///      selector mapped in `script/v2/roles.v8.json`, which is outside this task's `scope_paths` -- an
    ///      unmapped restricted selector is reachable by ADMIN alone, which is a different guard with different
    ///      behaviour. A compiled bound is the fail-closed half of that choice and needs no key to be correct.
    ///      A settable cap is the follow-up; it needs the roles file in the same commit.
    uint256 public constant MAX_DAILY_OUTFLOW = 2_500e6;

    /// @notice Most 0.01-share units one {place} may put on the book in a single order.
    ///         MIRRORED from the deployed `maxSeriesUnits` (`script/v2/DevDeploy.s.sol:865`, default 10_000).
    uint256 public constant MAX_SERIES_UNITS = 10_000;

    /// @notice Most notional (`units * strike / UNITS_PER_SHARE`, asset base units) one {place} may put on the
    ///         book in a single order. MIRRORED from the deployed `maxTotalNotional`
    ///         (`script/v2/DevDeploy.s.sol:866`, default 250_000e6).
    /// @dev PER ORDER. It stops one oversized order and nothing else; the aggregate the siblings enforce through
    ///      `MakerVault._enforce` (src/v2/mm/MakerVault.sol:844) lives here in {MAX_WRITTEN_UNITS_PER_SERIES} and
    ///      {MAX_WRITTEN_NOTIONAL}, checked by {_checkWritten} on every AskWrite (T-OP-039). {MAX_DAILY_OUTFLOW}
    ///      is NOT an aggregate bound on writes: it is the Bid-side outflow bucket, and a write moves no asset out.
    uint256 public constant MAX_ORDER_NOTIONAL = 250_000e6;

    /// @notice Most 0.01-share units the vault may have WRITTEN on one series: resting AskWrite orders plus open
    ///         shorts, net of longs it holds on that series (the sibling's `down` side, `MakerVault:83-84`).
    ///         MIRRORED from the deployed `maxSeriesUnits` (`script/v2/DevDeploy.s.sol:865`, default 10_000),
    ///         which in MakerVault bounds the WHOLE per-series exposure and here had only its per-order copy.
    /// @dev T-OP-039 (docs/V8-SECURITY-SWEEP.md F-1). Sixteen orders of {MAX_SERIES_UNITS} on one series used to
    ///      pass {_checkSize} one at a time; this is the sum they are checked against. A COMPILED bound, like the
    ///      constant above it, so a QUOTER key cannot raise it and there is no new restricted selector.
    uint256 public constant MAX_WRITTEN_UNITS_PER_SERIES = 10_000;

    /// @notice Most written notional (Σ over every series the vault is short or resting a write on of written
    ///         units x strike / UNITS_PER_SHARE, asset base units). MIRRORED from the deployed `maxTotalNotional`
    ///         (`script/v2/DevDeploy.s.sol:866`, default 250_000e6), which in MakerVault sums across series.
    /// @dev T-OP-039. Equal to {MAX_ORDER_NOTIONAL} on purpose: one full-size order is the whole budget, so the
    ///      "sixteen large orders spread over eight series" shape F-1 describes is refused at the second one.
    ///      Bounded by a constant rather than by TVL, which is what the finding said was missing.
    uint256 public constant MAX_WRITTEN_NOTIONAL = 250_000e6;

    /// @notice Share of the book's `V2Constants.FUNDING_GAS` stipend that {fund} keeps back for the Clearinghouse
    ///         deposit rather than handing to the venue, bps.
    /// @dev WHY IT EXISTS. {fund} is called with a hard gas cap. An adapter that consumes everything it is given
    ///      would leave the withdrawn assets sitting in this vault's wallet with no gas left to deposit them, and
    ///      the book -- which measures the `free` DELTA -- would correctly see a delivery of zero while the vault
    ///      had really moved the money. Reserving a quarter of the stipend (a `forceApprove` plus
    ///      `IClearinghouse.deposit` is comfortably inside it) makes that outcome impossible.
    uint16 public constant FUND_DEPOSIT_RESERVE_BPS = 2_500;

    /// @dev One whole share, the scale {highWaterMark} is quoted in: 10 ** decimals(), and `decimals()` is ERC20's
    ///      default 18, which is not overridden here.
    uint256 private constant ONE_SHARE = 1e18;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The OrderBook this vault makes a market on, and THE ONLY ADDRESS {fund} will answer.
    IOrderBook public immutable orderBook;
    /// @notice The Clearinghouse the OrderBook trades, read from the book at deployment.
    IClearinghouse public immutable clearinghouse;
    /// @notice The FeeSplitter: the ONLY address the yield skim can ever reach, fixed at deployment.
    address public immutable splitter;

    IERC20 private immutable _asset;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The venue the idle balance is parked in. Zero means the vault holds everything itself, which is the
    ///      state it is DEPLOYED in: the venue flag defaults OFF and a venue is wired later by TREASURY_ADMIN.
    ///      Private, with {adapter} as the `address` getter {IEarnVault} declares.
    IEarnVenueAdapter private _adapter;

    /// @inheritdoc IEarnVault
    uint16 public override skimBps;

    /// @notice This vault's own just-in-time funding switch. False makes {fundable} answer 0 and {fund} deliver
    ///         nothing, whatever the book's allow-list says. Defaults OFF.
    /// @dev Two-sided opt-in, and this is the side that always works: `CONFIG_ADMIN` allows the maker on the book
    ///      (`setFundingAllowed`) and the maker turns it on for itself (`setFunding`, forwarded by {setBookFunding}).
    ///      This local flag is checked FIRST and needs nothing from the book, so it cannot be blocked by a book that
    ///      has de-allowed the vault -- an off switch that can be jammed is not an off switch.
    bool public fundingEnabled;

    /// @inheritdoc IEarnVault
    uint256 public override highWaterMark;

    /// @dev Next queue id to serve, the last id issued, and how many outstanding entries still OWE A WITHDRAWAL,
    ///      packed into ONE slot so the test {fundable} makes still costs a single SLOAD -- {fundable} is on the
    ///      book's gas-capped quote path and cannot afford a second. The queue is EMPTY when `_head > _tail`; the
    ///      constructor starts it at (1, 0), and ids therefore begin at 1 so that 0 can mean "paid in this call"
    ///      in {redeem}.
    ///      WHY uint96 AND NOT uint128: only to make room for `_openWithdrawals` beside them. One id is issued per
    ///      queued request, so uint96 is past any reachable count, and holding all three in one slot is what lets
    ///      the funding gate ask "do we owe a withdrawal" for the same gas the old gate spent asking "is the queue
    ///      open".
    uint96 private _head;
    uint96 private _tail;

    /// @dev Outstanding entries that still owe a withdrawal. {fundable} and {fund} gate on THIS rather than on
    ///      {_queueOpen}, because since T-184 (`d9e9ac5a`) deposits share the same FIFO and a queued DEPOSIT is
    ///      money coming IN -- no reason to tell the book this vault has nothing to fund with, and a reason
    ///      anyone could manufacture for the price of gas by queueing one base unit and cancelling it.
    ///      Maintained at exactly the four places a withdrawal enters or leaves the queue: {_enqueue} on the way
    ///      in; in {processQueue}, when one is served IN FULL and when SEC-41 releases one that prices to zero;
    ///      and {cancelQueued} when one is withdrawn. A PARTIAL service does not decrement -- that entry is still
    ///      owed, which is the whole point of the gate. A cancelled entry is decremented at the cancel, so the
    ///      zero-share entry {processQueue} later drops must NOT be decremented again.
    uint64 private _openWithdrawals;

    mapping(uint256 id => Request) private _requests;

    /// @dev Assets escrowed by QUEUED DEPOSITS. Held by this contract but owned by the depositors until their
    ///      entries are served, so {totalAssets} subtracts it and every spending path measures against
    ///      {_unescrowed} rather than the raw wallet balance. Getting this wrong would let a queued deposit inflate
    ///      the share price for everyone the moment it arrived -- the mirror image of the defect T-184 exists to fix.
    uint256 private _escrowedAssets;

    /// @dev THE FLAT BOUNDARY, T-184. Long ids this vault still holds a short on. The vault has no other way to
    ///      know: `IClearinghouse.locked` is keyed by series and not by account, and `_orderIds` tracks live ORDERS
    ///      rather than filled writes. Appended by {_noteIncoming} ONLY FOR A MINT of a short to this vault, which
    ///      is the only moment the vault learns an `AskWrite` of its own was filled (T-298), and pruned lazily by
    ///      {_pruneShorts} against its own short balance.
    uint256[] private _openShorts;
    /// @dev `longId` to its 1-based index in {_openShorts}; 0 means absent, so a re-received short is not double
    ///      counted and a removal is O(1).
    mapping(uint256 longId => uint256) private _openShortAt;

    /// @dev T-433. Long ids this vault ACQUIRED THROUGH THE BOOK and may still hold: a fill of its own Bid (a transfer
    ///      from the seller, or a `writeToSell` mint), or the return of its own AskResale escrow. Longs are option
    ///      value {totalAssets} has no term for -- no mark this vault can trust exists -- so while any is held the
    ///      NAV is incomplete and the T-184 boundary queues pricing, exactly as for an open short. Appended by
    ///      {_noteIncoming}, pruned lazily by {_pruneLongs} against the vault's own long balance.
    uint256[] private _heldLongs;
    /// @dev `longId` to its 1-based index in {_heldLongs}; 0 means absent.
    mapping(uint256 longId => uint256) private _heldLongAt;

    /// @dev Order ids this vault has placed per series. Compacted lazily by {place}; see {_pruneAndCount}.
    mapping(uint256 longId => uint256[]) private _orderIds;

    /// @dev T-299. Series with a non-empty {_orderIds} list, so {_bookEscrow} can find every order without a
    ///      series index in the book. Bounded by {MAX_ORDER_SERIES}; a series leaves only when its list is empty.
    uint256[] private _orderSeries;
    /// @dev `longId` to its 1-based index in {_orderSeries}; 0 means absent.
    mapping(uint256 longId => uint256) private _orderSeriesAt;

    /// @dev The leaky bucket behind {MAX_DAILY_OUTFLOW}: net asset base units charged to the quoting path,
    ///      multiplied by {OUTFLOW_WINDOW} so the refill of the cap per window is exact and needs no rounding, as
    ///      of {_outflowAt} and before that refill. One slot with {_outflowAt}, and it follows a mapping so the
    ///      pair starts a fresh slot. MIRRORED from `MakerVault._outflowScaled` (src/v2/mm/MakerVault.sol:216).
    uint216 private _outflowScaled;
    uint40 private _outflowAt;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param orderBook_ The OrderBook; its `clearinghouse()` becomes immutable and it is the only {fund} caller.
    /// @param authority_ The `AccessManager` that gates every `restricted` selector (`NoSource` with no code).
    /// @param asset_ The ERC-20 depositors pay in. USDG (6 dp) at launch; a constructor argument rather than a
    ///        hard-wired USDG so the same contract can run a Stock Token vault without a second implementation.
    /// @param splitter_ The FeeSplitter, the only address {skim} can ever pay.
    /// @param name_ Share token name.
    /// @param symbol_ Share token symbol.
    constructor(
        IOrderBook orderBook_,
        address authority_,
        address asset_,
        address splitter_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Managed(authority_) {
        if (asset_.code.length == 0 || splitter_.code.length == 0) revert V2Errors.NoSource();
        orderBook = orderBook_;
        clearinghouse = IClearinghouse(orderBook_.clearinghouse());
        _asset = IERC20(asset_);
        splitter = splitter_;
        _head = 1;
        _approveBook();
    }

    /*//////////////////////////////////////////////////////////////
                             DEPOSIT / REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEarnVault
    /// @dev ANYONE. Prices against {totalAssets} MEASURED BEFORE the pull, and credits the MEASURED balance delta,
    ///      so a fee-on-transfer asset mints for what arrived. See FIRST DEPOSITOR on the contract for the inflation
    ///      guard. `BadUnits` for a zero amount, a rounding result of zero shares, or a vault that has lost everything
    ///      while shares are still outstanding (SEC-17, below); `NotAuthorized` for a zero receiver.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert V2Errors.BadUnits();
        if (receiver == address(0)) revert V2Errors.NotAuthorized();

        // T-184. THE PRICE IS TAKEN BEFORE THE PULL, so the order here matters: prune first, so a series that has
        // settled since the last call stops holding the queue open, and only then decide.
        _prunePositions();
        bool wait = _positionOpen() || _queueOpen();
        // BEFORE the NAV is read, so the depositor is priced against a number that includes the premium already
        // earned rather than one that is missing it.
        _claimOwed();

        uint256 supply = totalSupply();
        uint256 before = totalAssets();
        uint256 balBefore = _asset.balanceOf(address(this));
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = _asset.balanceOf(address(this)) - balBefore;
        if (received == 0) revert V2Errors.BadUnits();

        // WHILE A SERIES IS WRITTEN THERE IS NO SHARE PRICE TO MINT AT. `before` is understated by the locked
        // collateral and no correction exists that is not a mark, so this QUEUES rather than pricing -- the owner's
        // ruling of 2026-09-20. It joins the SAME FIFO as a redemption, behind anything already waiting, because a
        // deposit that stepped over a queued redemption would be priced at a NAV that redemption is still inside.
        if (wait) {
            // RETURNS ZERO, NOT A REVERT AND NOT AN ID. The selector is unchanged by owner ruling, so the id has no
            // return channel and rides {DepositQueued} instead. Zero here means QUEUED, not failed.
            _enqueueDeposit(received, receiver);
            return 0;
        }

        if (supply == 0) {
            // FIXED 1:1, never a rate derived from `before`. A donation made before this point raises the share
            // price for everyone and buys the donor nothing.
            shares = received;
            _update(address(0), DEAD_SHARES, MIN_SHARES);
        } else if (before != 0) {
            shares = Math.mulDiv(received, supply, before);
        }
        // SEC-17. `before == 0` with shares outstanding is TOTAL LOSS, and there is no rate that is fair to both
        // sides: the wiped-out holders keep their full share count, so reopening at the fixed 1:1 rate handed them
        // supply/(supply + minted) of the newcomer's money. {DEAD_SHARES} keep the supply above zero for good, so
        // this is not a reopening that could ever become safe later -- a wiped vault is closed to new money, and
        // `shares` stays zero here and reverts on the line below like any other deposit that prices to nothing.
        if (shares == 0) revert V2Errors.BadUnits();
        _mint(receiver, shares);

        // The first mark is set once the vault has a price at all, so the first depositor is never charged a skim
        // on the act of depositing.
        if (highWaterMark == 0) highWaterMark = _pricePerShare();
        emit Deposited(msg.sender, receiver, received, shares);
    }

    /// @inheritdoc IEarnVault
    /// @dev ANYONE, for the caller's own shares. NEVER REVERTS FOR LACK OF LIQUIDITY -- see property 3 on the
    ///      contract. Two things make it queue: the vault and the venue together cannot raise what is owed, or a
    ///      queue is already open, in which case this joins the back of it rather than stepping over it.
    function redeem(uint256 shares, address receiver) external nonReentrant returns (uint256 assets, uint256 id) {
        if (shares == 0) revert V2Errors.BadUnits();
        if (receiver == address(0)) revert V2Errors.NotAuthorized();

        uint256 supply = totalSupply();
        if (supply == 0) revert V2Errors.BadUnits();

        // T-184: the same boundary as {deposit}, for the same reason. Pricing an exit against an understated NAV
        // pays the redeemer LESS than fair and hands the difference to whoever stays, which is the mirror of the
        // over-mint -- so a written series queues the exit instead of pricing it.
        _prunePositions();
        if (_positionOpen()) {
            return (0, _enqueue(shares, receiver, 0));
        }
        _claimOwed();

        uint256 owed = Math.mulDiv(shares, totalAssets(), supply);

        if (!_queueOpen()) {
            // Raising cash does not move the share price: assets only travel from the venue into this wallet, and
            // {totalAssets} counts both. So `owed`, priced above, is still the right number afterwards.
            uint256 have = _raise(owed);
            if (have >= owed) {
                _burn(msg.sender, shares);
                _asset.safeTransfer(receiver, owed);
                emit Redeemed(msg.sender, receiver, shares, owed);
                return (owed, 0);
            }
            // Fall through to the queue with whatever was raised left sitting in the wallet, where the next
            // {processQueue} will find it. Nothing has been burned and nothing has been paid.
            id = _enqueue(shares, receiver, owed - have);
            return (0, id);
        }
        id = _enqueue(shares, receiver, owed);
    }

    /// @inheritdoc IEarnVault
    /// @dev PERMISSIONLESS. Prices every entry at the share price of THIS moment (property 3). Stops at the first
    ///      entry it cannot pay in full, after paying that entry as much as it can -- the head keeps its place.
    function processQueue(uint256 maxEntries) external nonReentrant returns (uint256 served) {
        // T-184. THE BOUNDARY IS ENFORCED HERE TOO, and this is the load-bearing half: queueing only defers the
        // pricing, so serving the queue while a series is still written would price at exactly the understated NAV
        // the queue exists to avoid, and do it to every waiting entry at once. Prune first so a settled series
        // releases the queue without anyone having to poke it.
        _prunePositions();
        if (_positionOpen()) return 0;
        // AC-3 says the queue processes at an EXACT NAV. Unlocking the collateral is only half of exact; the
        // premium the vault earned writing the series has to be in the measurement too.
        _claimOwed();

        uint256 head = _head;
        uint256 tail = _tail;
        for (uint256 i; i < maxEntries && head <= tail; ++i) {
            Request storage r = _requests[head];

            // A DEPOSIT ENTRY, served at the exact NAV of this block now that the vault is provably flat.
            uint256 queuedAssets = r.assets;
            if (queuedAssets != 0) {
                uint256 dSupply = totalSupply();
                // Priced BEFORE the escrow is released, mirroring {deposit}'s "price before the pull": the incoming
                // assets must not be part of the NAV they are priced against.
                uint256 dBefore = totalAssets();
                address dReceiver = r.receiver;
                uint256 minted;
                if (dSupply == 0) {
                    minted = queuedAssets;
                    _update(address(0), DEAD_SHARES, MIN_SHARES);
                } else if (dBefore != 0) {
                    minted = Math.mulDiv(queuedAssets, dSupply, dBefore);
                }
                // SEC-17: `dBefore == 0` with shares outstanding is total loss and leaves `minted` at zero, the same
                // refusal {deposit} makes. It is a REFUND and not a revert because a revert here would wedge the
                // FIFO behind this entry for every redemption queued after it.
                r.assets = 0;
                _escrowedAssets -= queuedAssets;
                if (minted == 0) {
                    // Rounds to nothing at this price, or there is no price (SEC-17 above). Return the assets rather
                    // than confiscating them; the entry is spent either way and the depositor may come back.
                    _asset.safeTransfer(r.owner, queuedAssets);
                    emit DepositCancelled(head, r.owner, queuedAssets);
                } else {
                    _mint(dReceiver, minted);
                    if (highWaterMark == 0) highWaterMark = _pricePerShare();
                    emit DepositServed(head, dReceiver, queuedAssets, minted);
                }
                delete _requests[head];
                unchecked {
                    ++head;
                    ++served;
                }
                continue;
            }

            uint256 shares = r.shares;
            if (shares == 0) {
                // Cancelled, or already served in full. Drop it and move on; it costs nobody anything.
                delete _requests[head];
                unchecked {
                    ++head;
                }
                continue;
            }

            uint256 supply = totalSupply();
            uint256 assetsNow = totalAssets();
            uint256 owed = Math.mulDiv(shares, assetsNow, supply);
            // SEC-41. `owed == 0` and `have == 0` look the same one line down and mean opposite things. `have == 0`
            // with something owed is ILLIQUIDITY: the entry is still payable, FIFO must not step over it, and the
            // break below is right. `owed == 0` is a price, not a liquidity problem -- after a total venue loss
            // `assetsNow` is 0, so EVERY redemption prices to nothing and no amount of waiting changes it. Breaking
            // there parks the head on this entry permanently and starves every entry behind it, including deposit
            // entries the arm above would have refunded. Return the escrowed shares exactly as {cancelQueued} does
            // -- the holder keeps the exposure and may queue again if the price recovers -- and step the head.
            if (owed == 0) {
                r.shares = 0;
                address zeroOwner = r.owner;
                _transfer(address(this), zeroOwner, shares);
                emit WithdrawalCancelled(head, zeroOwner, shares);
                delete _requests[head];
                unchecked {
                    ++head;
                    // The entry leaves the queue owing nothing, exactly as a cancel does, so it stops holding the
                    // funding gate shut. Without this a total venue loss would leave `_openWithdrawals` counting
                    // entries that no longer exist, and {fundable}/{fund} would answer 0 for good.
                    --_openWithdrawals;
                }
                continue;
            }

            uint256 have = _raise(owed);
            if (have == 0) break;

            address receiver = r.receiver;
            if (have >= owed) {
                r.shares = 0;
                _burn(address(this), shares);
                _asset.safeTransfer(receiver, owed);
                emit WithdrawalServed(head, receiver, shares, owed, true);
                delete _requests[head];
                unchecked {
                    ++head;
                    ++served;
                    --_openWithdrawals;
                }
                continue;
            }

            // PARTIAL, priced at the same instant as the full case would have been: turn the cash on hand back into
            // shares, then those shares back into cash, and clamp so rounding can never pay out more than is held.
            uint256 part = Math.mulDiv(have, supply, assetsNow);
            if (part == 0) break;
            if (part > shares) part = shares;
            uint256 pay = Math.mulDiv(part, assetsNow, supply);
            if (pay > have) pay = have;
            r.shares = shares - part;
            _burn(address(this), part);
            _asset.safeTransfer(receiver, pay);
            emit WithdrawalServed(head, receiver, part, pay, false);
            break; // the head is still owed; FIFO is never stepped over
        }
        // casting to 'uint96' is safe because `head` starts at `_head` and only ever walks up to `_tail`, both
        // uint96, so it cannot exceed `_tail + 1`.
        // forge-lint: disable-next-line(unsafe-typecast)
        _head = uint96(head);
    }

    /// @inheritdoc IEarnVault
    /// @dev The request's owner only (`NotAuthorized`). Returns the escrowed shares, so the holder keeps the
    ///      exposure and cancelling is no more an escape from a loss than queueing is. The entry is left in place
    ///      with zero shares and is dropped by the next {processQueue} that reaches it.
    function cancelQueued(uint256 id) external nonReentrant {
        Request storage r = _requests[id];
        if (r.owner != msg.sender) revert V2Errors.NotAuthorized();

        // T-184 (AC-3): a queued DEPOSITOR can still cancel, and gets the assets back rather than shares. Escrowed
        // assets were never minted against, so returning them moves nobody else's share price -- unlike cancelling
        // a redemption, which returns exposure the holder never stopped carrying.
        uint256 queuedAssets = r.assets;
        if (queuedAssets != 0) {
            r.assets = 0;
            _escrowedAssets -= queuedAssets;
            _asset.safeTransfer(msg.sender, queuedAssets);
            emit DepositCancelled(id, msg.sender, queuedAssets);
            return;
        }

        uint256 shares = r.shares;
        if (shares == 0) revert V2Errors.BadUnits();
        r.shares = 0;
        unchecked {
            --_openWithdrawals;
        }
        _transfer(address(this), msg.sender, shares);
        emit WithdrawalCancelled(id, msg.sender, shares);
    }

    /*//////////////////////////////////////////////////////////////
                                  SKIM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEarnVault
    /// @dev PERMISSIONLESS. See property 2 on the contract. Two refusals that are easy to get wrong:
    ///      - a flat or LOSING period takes ZERO and leaves the mark, so a recovery is not charged twice;
    ///      - a gain the vault cannot pay the fee out of (a frozen venue) takes NOTHING AND LEAVES THE MARK, rather
    ///        than taking what it can and marking up. Marking up on a short payment would let anyone burn the
    ///        protocol's claim on a real gain by calling this at the wrong moment.
    ///      And a third: WHILE A QUEUE IS OPEN it takes NOTHING AND LEAVES THE MARK (SEC-16). The queue head's
    ///      payout is priced against the cash this function would raise the fee from, so a fee paid now comes out
    ///      of money already owed to a waiting redeemer. {fundable} and {fund} refuse in the same state for the
    ///      same reason. What this costs: shares that exit through the queue leave with their slice of the gain
    ///      uncharged; the slice on shares that stay is still above the mark and is charged once the queue drains.
    function skim() external nonReentrant returns (uint256 fee) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        if (_queueOpen()) {
            emit Skimmed(0, 0, highWaterMark);
            return 0;
        }

        uint256 mark = highWaterMark;
        uint256 priceNow = _pricePerShare();
        if (priceNow <= mark) {
            emit Skimmed(0, 0, mark);
            return 0;
        }

        uint256 gain = Math.mulDiv(priceNow - mark, supply, ONE_SHARE);
        fee = (gain * skimBps) / V2Constants.BPS;
        if (fee == 0) {
            highWaterMark = priceNow;
            emit Skimmed(gain, 0, priceNow);
            return 0;
        }

        if (_raise(fee) < fee) {
            emit Skimmed(gain, 0, mark);
            return 0;
        }
        _asset.safeTransfer(splitter, fee);
        uint256 marked = _pricePerShare();
        highWaterMark = marked;
        emit Skimmed(gain, fee, marked);
    }

    /// @notice Sets the yield skim rate. TREASURY_ADMIN. `CeilingExceeded` above {SKIM_BPS_CEIL}.
    /// @param bps Bps of realised gain.
    function setSkimBps(uint16 bps) external nonReentrant restricted {
        if (bps > SKIM_BPS_CEIL) revert V2Errors.CeilingExceeded();
        skimBps = bps;
        emit SkimBpsSet(bps);
    }

    /*//////////////////////////////////////////////////////////////
                             IFundingSource
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFundingSource
    /// @dev DERIVED FROM `IEarnVenueAdapter.withdrawable()` AND THIS VAULT'S OWN TOKEN BALANCE, AND FROM NOTHING
    ///      ELSE. Not {totalAssets}, not {convertToAssets}, not a share balance: see property 1 on the contract.
    ///      Both terms are cash that can move in THIS block. Answers 0, cheaply and early, for a foreign asset, for
    ///      a vault whose own funding switch is off, and WHILE A WITHDRAWAL QUEUE IS OPEN -- queued depositors are
    ///      paid before takers are quoted, and a vault that owes money should be invisible rather than attractive.
    ///      THE BOUND, IN ONE SENTENCE (T-OP-042): the answer is the wallet MINUS queued-deposit escrow, plus the
    ///      venue, which is exactly what {fund} can deliver -- both read {_deliverable}, so this view cannot quote
    ///      an amount {fund} will then clamp. Until T-OP-042 this returned the RAW wallet while {fund} (T-440/F5)
    ///      clamped to the unescrowed part, so with a deposit queued the book was quoted `escrow` more than it
    ///      could ever be given, and `quoteTake` promised units `take` did not fill.
    function fundable(address asset_) external view returns (uint256) {
        if (asset_ != address(_asset)) return 0;
        if (!fundingEnabled) return 0;
        if (_owesWithdrawal()) return 0;
        IEarnVenueAdapter a = _adapter;
        uint256 venue = address(a) == address(0) ? 0 : a.withdrawable();
        return _deliverable(_asset.balanceOf(address(this)), venue);
    }

    /// @inheritdoc IFundingSource
    /// @dev THE IMMUTABLE {orderBook} ONLY; every other caller reverts `V2Errors.NotAuthorized()`. Everything else
    ///      that can go wrong RETURNS NORMALLY with `delivered == 0` in {Funded} -- see property 4 on the contract.
    ///      The book measures this vault's Clearinghouse `free` delta, so a normal return that delivered nothing
    ///      costs the vault the fills it would have made and costs the take nothing else, while a revert costs the
    ///      vault every fill in that take.
    ///      GAS. The book forwards `V2Constants.FUNDING_GAS`. The venue call is capped so that
    ///      {FUND_DEPOSIT_RESERVE_BPS} of that stipend is still available for the `forceApprove` and
    ///      `IClearinghouse.deposit` that follow it; an adapter that burns everything it is handed therefore cannot
    ///      strand withdrawn assets in this wallet.
    function fund(address asset_, uint256 amount) external nonReentrant {
        if (msg.sender != address(orderBook)) revert V2Errors.NotAuthorized();
        if (asset_ != address(_asset) || !fundingEnabled || _owesWithdrawal() || amount == 0) {
            emit Funded(asset_, amount, 0);
            return;
        }

        uint256 have = _asset.balanceOf(address(this));
        // THE SHORTFALL IS MEASURED AGAINST THE UNESCROWED WALLET, NOT THE RAW ONE (T-OP-042). The clamp below
        // will not hand out escrow, so a pull sized to `amount - have` while a deposit is queued leaves the
        // clamp `escrow` short of `amount` even when the venue could have covered it -- and then {fundable},
        // which promises `unescrowed + venue`, would be a promise this path cannot keep. One rule, {_deliverable},
        // on both sides.
        uint256 spendable = _deliverable(have, 0);
        if (spendable < amount) {
            IEarnVenueAdapter a = _adapter;
            if (address(a) != address(0)) {
                uint256 reserve = (V2Constants.FUNDING_GAS * FUND_DEPOSIT_RESERVE_BPS) / V2Constants.BPS;
                uint256 left = gasleft();
                if (left > reserve) {
                    // MEASURED, and the adapter is never believed: a revert, a lie or a short answer all end at the
                    // re-read below.
                    try a.withdraw{gas: left - reserve}(amount - spendable, address(this)) returns (uint256) {} catch {}
                    have = _asset.balanceOf(address(this));
                }
            }
        }

        // THE SAME ESCROW CLAMP {depositToClearinghouse} MAKES, and it is load-bearing HERE ONLY BECAUSE THE
        // GATE ABOVE NARROWED. Until F5 this path was reachable only when nothing was queued, and escrow exists
        // only while a deposit entry is queued, so the old `_queueOpen()` gate hid this. Gating on owed
        // WITHDRAWALS lets a take fund from the wallet while a queued DEPOSIT's escrow is sitting in it -- which
        // is the F4 defect arriving through the book instead of through the QUOTER. A short answer here is
        // normal and costs the vault only the fills it would have made (property 4); moving escrow would cost a
        // queued depositor their cancel.
        uint256 give = _deliverable(have, 0);
        if (give > amount) give = amount;
        if (give == 0) {
            emit Funded(asset_, amount, 0);
            return;
        }
        _asset.forceApprove(address(clearinghouse), give);
        clearinghouse.deposit(asset_, give, address(this));
        emit Funded(asset_, amount, give);
    }

    /// @notice Turns this vault's own just-in-time funding switch on or off. CONFIG_ADMIN.
    /// @dev The local half of the two-sided opt-in, and the half that can never be jammed: it touches no other
    ///      contract, so switching funding OFF always succeeds. {setBookFunding} is the other half.
    /// @param on True to offer funding.
    function setFundingEnabled(bool on) external nonReentrant restricted {
        fundingEnabled = on;
        emit FundingEnabledSet(on);
    }

    /// @notice Tells the OrderBook whether this vault is funding (`IOrderBook.setFunding`). CONFIG_ADMIN.
    /// @dev Separate from {setFundingEnabled} on purpose. The book reverts `NotAuthorized` when `CONFIG_ADMIN` has
    ///      not allowed this vault, and reads {fundable} when funding is switched on; folding that into the local
    ///      switch would make the vault's own off switch depend on the book answering.
    /// @param on What to tell the book.
    function setBookFunding(bool on) external nonReentrant restricted {
        orderBook.setFunding(on);
    }

    /*//////////////////////////////////////////////////////////////
                                 VENUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Points the vault at a venue adapter, or at none (`address(0)`). TREASURY_ADMIN.
    /// @dev Pulls everything out of the OLD adapter first and refuses to move on while it still holds anything
    ///      (`InsufficientCollateral(0, remaining)`), so a swap can never orphan depositor assets in a venue the
    ///      vault has stopped counting. `UnsupportedAsset` when the new adapter is denominated in something else --
    ///      the check `IEarnVenueAdapter.asset` exists for, so a wrong adapter is a failed transaction and not a
    ///      silent custody move. `NotAuthorized` when the new adapter does not name THIS vault as its owner, or
    ///      cannot say (SEC-30): the asset check alone accepts a sibling vault's adapter.
    /// @param adapter_ The new adapter, or zero to hold everything in the vault.
    function setAdapter(address adapter_) external nonReentrant restricted {
        IEarnVenueAdapter old = _adapter;
        if (address(old) != address(0)) {
            uint256 w = old.withdrawable();
            if (w != 0) _pull(old, w);
            uint256 left = old.totalAssets();
            if (left != 0) revert V2Errors.InsufficientCollateral(0, left);
        }
        if (adapter_ != address(0)) {
            if (IEarnVenueAdapter(adapter_).asset() != address(_asset)) revert V2Errors.UnsupportedAsset();
            // SEC-30. THE ASSET CHECK IS NOT AN OWNERSHIP CHECK. An adapter built for a SIBLING EarnVault has the
            // same asset, so it passes the line above -- and then this vault counts that sibling's venue balance in
            // its own {totalAssets}, inflating its share price against money it cannot move, while the sibling can
            // still withdraw it out from under the price. The adapter's `vault` is immutable and is the adapter's
            // own whole authorisation (Erc4626VenueAdapter.sol:52-58), so it is the thing to check against.
            //
            // PROBED, NOT TYPED: `vault()` is on the implementations, not on {IEarnVenueAdapter}, which is outside
            // this task's scope_paths. A raw staticcall lets an adapter that does not answer be REFUSED rather
            // than reverting on a decode, and refusing is the safe direction: the two shipped adapters both answer,
            // and a third-party adapter that cannot say which vault owns it is exactly the one not to wire.
            (bool ok, bytes memory ret) = adapter_.staticcall(abi.encodeWithSignature("vault()"));
            if (!ok || ret.length < 32) revert V2Errors.NotAuthorized();
            // Truncating rather than `abi.decode`: a return with dirty high bits would make decode revert, and a
            // silent refusal is better than a revert that reads like a broken vault.
            if (address(uint160(uint256(bytes32(ret)))) != address(this)) revert V2Errors.NotAuthorized();
        }
        _adapter = IEarnVenueAdapter(adapter_);
        emit AdapterSet(adapter_);
    }

    /// @notice Parks up to `assets` base units of the idle balance in the venue. QUOTER.
    /// @dev Clamped to what the vault actually holds, and credited as the MEASURED balance delta rather than the
    ///      adapter's return, so a venue with a deposit cap or a fee simply takes less. The allowance is set for the
    ///      call and cleared after it, so no standing allowance to the venue ever exists.
    /// @param assets Base units to offer.
    /// @return deposited Base units that actually left this vault.
    function sweepToVenue(uint256 assets) external nonReentrant restricted returns (uint256 deposited) {
        IEarnVenueAdapter a = _adapter;
        if (address(a) == address(0)) revert V2Errors.NoSource();
        // T-184: never sweep escrowed deposits into the venue. They stay liquid here until their entries are
        // served or cancelled, so a cancelling depositor is never waiting on a venue withdrawal.
        uint256 bal = _unescrowed();
        if (assets > bal) assets = bal;
        if (assets == 0) revert V2Errors.BadUnits();
        _asset.forceApprove(address(a), assets);
        a.deposit(assets);
        _asset.forceApprove(address(a), 0);
        deposited = bal - _asset.balanceOf(address(this));
        emit SweptToVenue(assets, deposited);
    }

    /// @notice Pulls up to `assets` base units back out of the venue. QUOTER.
    /// @param assets Base units requested.
    /// @return withdrawn Base units that actually arrived, MEASURED.
    function pullFromVenue(uint256 assets) external nonReentrant restricted returns (uint256 withdrawn) {
        IEarnVenueAdapter a = _adapter;
        if (address(a) == address(0)) revert V2Errors.NoSource();
        if (assets == 0) revert V2Errors.BadUnits();
        withdrawn = _pull(a, assets);
    }

    /*//////////////////////////////////////////////////////////////
                         CLEARINGHOUSE LEDGER
    //////////////////////////////////////////////////////////////*/

    /// @notice Moves `amount` base units of `asset_` from the vault's wallet into the vault's Clearinghouse ledger
    ///         (write collateral). QUOTER. MIRRORED from `MakerVault.depositToClearinghouse`
    ///         (src/v2/mm/MakerVault.sol:357).
    /// @param asset_ USDG or a registered underlying.
    /// @param amount Base units. CLAMPED to {_unescrowed} when `asset_` is this vault's own asset.
    /// @dev THE CLAMP IS THE SAME ONE {sweepToVenue} MAKES, for the same reason: escrowed assets belong to queued
    ///      depositors and every spending path measures against {_unescrowed} rather than the raw wallet balance.
    ///      Without it one QUOTER deposit moves escrow into the ledger, and then {cancelQueued} and the zero-mint
    ///      refund in {processQueue} -- both bare wallet transfers -- revert, stalling every entry behind them
    ///      until the QUOTER withdraws the ledger again.
    ///      ONLY FOR `_asset`. `asset_` may be a registered underlying, and escrow is denominated in `_asset`
    ///      alone, so clamping a Stock Token deposit would refuse ordinary quoting collateral and protect nothing.
    ///      A zero clamp is a refusal rather than a silent no-op: a QUOTER who asked to move collateral and moved
    ///      none should hear about it.
    function depositToClearinghouse(address asset_, uint256 amount) external nonReentrant restricted {
        if (asset_ == address(_asset)) {
            uint256 free = _unescrowed();
            if (amount > free) amount = free;
            if (amount == 0) revert V2Errors.BadUnits();
        }
        IERC20(asset_).forceApprove(address(clearinghouse), amount);
        clearinghouse.deposit(asset_, amount, address(this));
    }

    /// @notice Moves `amount` base units of `asset_` from the vault's Clearinghouse ledger back to its wallet.
    ///         QUOTER. The recipient is always the vault. MIRRORED from `MakerVault.withdrawFromClearinghouse`
    ///         (src/v2/mm/MakerVault.sol:366).
    /// @param asset_ USDG or a registered underlying.
    /// @param amount Base units (`InsufficientCollateral` above the free balance).
    function withdrawFromClearinghouse(address asset_, uint256 amount) external nonReentrant restricted {
        clearinghouse.withdraw(asset_, amount, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                QUOTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Places one of the vault's own orders on the book, with the vault as maker of record. QUOTER.
    /// @dev THE BOOK DOES NOT CHECK PRICE AGAINST ANYTHING. That sentence used to live here - "the book does every
    ///      price, tick, cutoff and pause check" - and it is false about price, which is why this gap survived
    ///      review: a reader who believes it has no reason to look. `OrderBook._checkPriceAndUnits` is declared
    ///      `private pure`, so it cannot consult an oracle even in principle; its entire check is that units are
    ///      non-zero, price is non-zero, and price is on the tick grid. A QUOTER key could therefore rest an
    ///      AskWrite at one wei against depositor collateral and have it filled, bounded only by vault TVL.
    ///
    ///      So this vault applies the guard its siblings already apply ({MakerVault._checkPrice},
    ///      {HouseVault._checkPrice}): a bid may not exceed intrinsic value plus a bounded band of time value
    ///      ({MAX_BID_BPS_OF_SPOT}), and an ask may not sit below the series' intrinsic value grossed up for the
    ///      seller fee the book will take. Both bounds are read live - spot from the SERIES' own oracle, the fee
    ///      from {IOrderBook.feeParams} - so neither can be staled by a compiled copy.
    ///
    ///      SEC-05 ADDED THE TWO BOUNDS A PRICE CHECK CANNOT PROVIDE. A price check bounds ONE order; it does not
    ///      bound how many. {MAX_DAILY_OUTFLOW} is a leaky bucket over the net assets the quoting path may move
    ///      out per {OUTFLOW_WINDOW} -- the Bid side; {_checkSize} bounds one order's units and notional. Both
    ///      are MIRRORED from `MakerVault`, which bounds the identical capability and which this vault was
    ///      asymmetrically missing. T-OP-039 ADDED THE WRITE-SIDE AGGREGATE: {_checkWritten} sums this vault's
    ///      resting AskWrites and open shorts on the series and its written notional across series against
    ///      {MAX_WRITTEN_UNITS_PER_SERIES} / {MAX_WRITTEN_NOTIONAL}, the bound {MAX_DAILY_OUTFLOW} never was.
    ///      The remaining guard is the live-order ceiling ({MAX_LIVE_ORDERS_PER_SERIES}, `CeilingExceeded`),
    ///      which bounds the gas of the scan itself.
    /// @param longId Long id of an existing series.
    /// @param kind Bid, AskResale or AskWrite.
    /// @param price USDG base units per whole share.
    /// @param units 0.01-share units.
    /// @param validUntil Unix seconds; 0 means the series default.
    /// @return orderId New order id.
    function place(uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units, uint40 validUntil)
        external
        nonReentrant
        restricted
        returns (uint256 orderId)
    {
        if (_pruneAndCount(longId) >= MAX_LIVE_ORDERS_PER_SERIES) revert V2Errors.CeilingExceeded();
        _trackSeries(longId);
        V2Types.Series memory s = clearinghouse.series(longId);
        bool bid = kind == V2Types.OrderKind.Bid;
        _checkPrice(s, bid, kind == V2Types.OrderKind.AskWrite, price);
        _checkSize(s.strike, units);
        if (kind == V2Types.OrderKind.AskWrite) _checkWritten(longId, s.strike, units);
        // T-299. The book pulls Bid escrow from the RAW WALLET by allowance, and the wallet also holds assets
        // escrowed by queued deposits, which belong to their depositors and can be reclaimed by {cancelQueued} at
        // any moment. A Bid may spend only what {_unescrowed} says is the vault's own. The book's own formula is
        // used, so the check and the pull cannot disagree about the amount.
        if (bid) {
            uint256 need = OptionMath.premium(price, units);
            uint256 have = _unescrowed();
            if (have < need) revert V2Errors.InsufficientCollateral(have, need);
        }
        // MIRRORED from `MakerVault.place` (src/v2/mm/MakerVault.sol:405): measure before the book call, charge
        // after it, and enforce only for a Bid -- a Bid escrows asset at placement and is the only kind that can
        // move money OUT of this vault on the quoting path.
        uint256 cashBefore = _cash();
        orderId = orderBook.place(longId, kind, price, units, validUntil);
        _orderIds[longId].push(orderId);
        if (bid) _bookOutflow(cashBefore, true);
    }

    /// @notice Cancels the vault's own orders and takes their escrow back. QUOTER.
    /// @dev Forwarded straight to the book, which refuses an order this vault does not own. The stored id list is
    ///      compacted lazily by the next {place} on that series rather than here, so a cancel can never be made
    ///      expensive by a long list.
    /// @param orderIds Orders to cancel.
    function cancel(uint256[] calldata orderIds) external nonReentrant restricted {
        // MIRRORED from `MakerVault.cancel` (src/v2/mm/MakerVault.sol:458): booked with `enforce` false. A cancel
        // returns escrow and can only CREDIT the bucket, so it must never be blocked by the cap -- a bound that
        // can block unwinding is a bound that can trap the vault's own money.
        uint256 cashBefore = _cash();
        orderBook.cancel(orderIds);
        _bookOutflow(cashBefore, false);
    }

    /// @notice Re-grants the OrderBook the operator rights, ERC-1155 approval and USDG allowance it needs. QUOTER.
    /// @dev MIRRORED from `MakerVault.refreshApprovals`; needed after an OrderBook upgrade or a manual revoke.
    function refreshApprovals() external nonReentrant restricted {
        _approveBook();
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEarnVault
    function asset() external view returns (address) {
        return address(_asset);
    }

    /// @inheritdoc IEarnVault
    /// @dev FOUR MEASURED TERMS, no assumptions and no cached figure: the wallet, the free Clearinghouse ledger, the
    ///      venue, and the refundable Bid escrow the book holds for this vault. A venue loss therefore lands here,
    ///      lowers the share price and is borne pro rata by every holder -- it moves nobody's share balance and
    ///      touches no other account.
    ///      T-299, THE FOURTH TERM. A Bid moves CUSTODY of its escrow to the book, not ownership away from the vault:
    ///      cancel or prune pays it straight back. Without this term every live Bid depressed the share price by
    ///      its escrow, so a deposit in that window was over-minted and an exit under-paid, and the difference
    ///      landed on the other side when the Bid came off. {_bookEscrow} READS the book rather than keeping a
    ///      counter, because fills and permissionless prunes move escrow without calling this vault -- a local
    ///      counter would drift with nothing to correct it. It is NOT `orderBook.owed`, which is failed-payment
    ///      credit and a different quantity. NO OVERLAP WITH `_escrowedAssets`: that is money in this vault's
    ///      wallet or venue, already inside the first and third terms, and subtracted once below; book escrow is
    ///      money in the BOOK'S balance, in none of the first three terms. A base unit is in exactly one place.
    ///      NO FIFTH TERM FOR AN OPEN SHORT, DELIBERATELY (SEC-19 / F-CP-03, T-OP-026). A fill of this vault's own
    ///      AskWrite moves `units x collateralPerUnit + rent` out of `clearinghouse.free` and only the premium comes
    ///      back, so this number drops by about the locked notional and recovers when the short is redeemed. The
    ///      review's conservative count (locked minus worst-case payout) is zero for a fully collateralised write,
    ///      and a mark is forbidden by {IEarnVault.totalAssets}; so the correction is the flat boundary -- {deposit},
    ///      {redeem} and {processQueue} refuse to price while {_positionOpen} -- and not a term. {skim} is the one
    ///      pricing path outside that boundary; an understated price can only defer its fee, never inflate it.
    ///      `test/v2/unit/EarnVaultNav.t.sol` pins the gap's arithmetic and every price paid across an episode.
    function totalAssets() public view returns (uint256) {
        uint256 t = _asset.balanceOf(address(this)) + clearinghouse.free(address(this), address(_asset));
        t += _bookEscrow();
        IEarnVenueAdapter a = _adapter;
        if (address(a) != address(0)) t += a.totalAssets();
        // T-184: assets escrowed by queued deposits sit in this wallet (or, after a sweep, in the venue) but are
        // NOT the vault's. Counting them would raise the share price for existing holders on arrival and drop it
        // again on service. Saturating rather than checked: a wallet drained below the escrow by something
        // unforeseen must not brick every read that depends on this.
        uint256 esc = _escrowedAssets;
        return t > esc ? t - esc : 0;
    }

    /// @inheritdoc IEarnVault
    /// @dev Zero with shares outstanding and nothing behind them: {deposit} refuses that state (SEC-17), so quoting
    ///      the old 1:1 reopening rate here would advertise a price nobody can get.
    ///      T-OP-065. FAILS LOUD WHILE A POSITION IS OPEN. {totalAssets} is then the flat-NAV floor, understated by
    ///      the locked collateral (T-OP-026 pins the gap), and this view used to quote that number as if it were the
    ///      price. Nothing was ever settled at it -- the boundary in {deposit} / {redeem} / {processQueue} sees to
    ///      that -- but an ERC-4626-shaped view IS read as a price by integrators, and the owner ruled the quote out.
    ///      The check is {_positionOpen}, the same predicate the boundary uses, so the view refuses exactly when
    ///      the paths that could act on its answer would have queued instead. {indicativeTotalAssets} is the figure
    ///      to display meanwhile; it is a mark and never a price.
    function convertToShares(uint256 assets) external view returns (uint256) {
        if (_positionOpen()) revert PositionOpen();
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        uint256 t = totalAssets();
        if (t == 0) return 0;
        return Math.mulDiv(assets, supply, t);
    }

    /// @inheritdoc IEarnVault
    /// @dev Reverts PositionOpen while a position is open, for the reason {convertToShares} gives.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (_positionOpen()) revert PositionOpen();
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(shares, totalAssets(), supply);
    }

    /// @inheritdoc IEarnVault
    /// @dev DISPLAY ONLY -- read by nothing that mints, burns, pays or skims, and by no boundary; `grep indicative`
    ///      in this file finds only these two views and their NatSpec, and that is the invariant T-OP-026 built
    ///      ({IEarnVault.totalAssets}). The mark per unit is `collateralPerUnit - grossPayoutPerUnit(spot)`, both
    ///      from {OptionMath} so the intrinsic here is the same arithmetic settlement will use, evaluated at the
    ///      series oracle's spot instead of the settlement price. Conservative in every branch: a short whose
    ///      collateral is not this vault's asset is skipped (it never lowered {totalAssets}), a short with no ok spot
    ///      is skipped (worst case: the whole collateral is intrinsic), longs and resale escrow are valued at zero,
    ///      the mint rent already paid is gone. Walks {_openShorts}, the T-184 tracker {_positionOpen} walks.
    function indicativeTotalAssets() public view returns (uint256 t) {
        t = totalAssets();
        uint256 n = _openShorts.length;
        for (uint256 i; i < n; ++i) {
            uint256 longId = _openShorts[i];
            uint256 units = clearinghouse.balanceOf(address(this), V2Ids.shortIdOf(longId));
            if (units == 0) continue;
            V2Types.Series memory s = clearinghouse.series(longId);
            address collateral = s.isPut ? clearinghouse.usdg() : s.underlying;
            if (collateral != address(_asset)) continue;
            (bool ok, uint256 spot,) = ISettlementOracle(s.oracle).trySpot(s.underlying);
            if (!ok || spot == 0) continue;
            uint256 perUnit = OptionMath.collateralPerUnit(s.isPut, s.strike);
            uint256 intrinsic = OptionMath.grossPayoutPerUnit(s.isPut, s.strike, spot);
            if (intrinsic < perUnit) t += units * (perUnit - intrinsic);
        }
    }

    /// @inheritdoc IEarnVault
    /// @dev DISPLAY ONLY; see {indicativeTotalAssets}.
    function indicativeAssetsPerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 0 : Math.mulDiv(indicativeTotalAssets(), 1e18, supply);
    }

    /// @inheritdoc IEarnVault
    function adapter() external view returns (address) {
        return address(_adapter);
    }

    /// @notice Net assets the quoting path has paid out inside the window, and what it may still pay out before
    ///         a {place} reverts `OutflowCapExceeded`.
    /// @dev MIRRORED from `MakerVault.outflow` (src/v2/mm/MakerVault.sol:546). `used` is rounded UP, so
    ///      `available` is never overstated. NOT on {IEarnVault}: that interface is outside this task's
    ///      `scope_paths`, so this is declared on the contract only and an interface-level getter is a follow-up.
    /// @return used Asset base units charged and not yet refilled.
    /// @return available Asset base units still spendable at once.
    function outflow() external view returns (uint256 used, uint256 available) {
        used = (_refilled(MAX_DAILY_OUTFLOW) + OUTFLOW_WINDOW - 1) / OUTFLOW_WINDOW;
        available = MAX_DAILY_OUTFLOW > used ? MAX_DAILY_OUTFLOW - used : 0;
    }

    /// @inheritdoc IEarnVault
    function queue() external view returns (uint256 head, uint256 tail) {
        return (_head, _tail);
    }

    /// @inheritdoc IEarnVault
    function request(uint256 id) external view returns (Request memory) {
        return _requests[id];
    }

    /// @inheritdoc IEarnVault
    /// @dev READ FROM `V2Constants`, never retyped. The three numbers exist once, at
    ///      src/v2/interfaces/V2Constants.sol:121, :124 and :127.
    function fundingBudget() external pure returns (uint256 fundGas, uint256 fundableReadGas, uint256 maxFundedMakers) {
        return (V2Constants.FUNDING_GAS, V2Constants.FUNDABLE_READ_GAS, V2Constants.MAX_FUNDED_MAKERS_PER_TAKE);
    }

    /*//////////////////////////////////////////////////////////////
                             ERC-1155 INBOX
    //////////////////////////////////////////////////////////////*/

    /// @notice Accepts option tokens from the Clearinghouse only (fills, escrow refunds, prunes). MIRRORED from
    ///         `MakerVault.onERC1155Received` (src/v2/mm/MakerVault.sol:610).
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata)
        external
        returns (bytes4)
    {
        if (msg.sender != address(clearinghouse)) revert V2Errors.NotAuthorized();
        _noteIncoming(operator, from, id, value);
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @notice Batch twin of {onERC1155Received}.
    /// @dev T-257. NOT `view`, and that is the fix. This hook used to be the auth check and a `return` with no
    ///      recording, so a short delivered in a BATCH left {hasOpenShort} answering false while the vault really
    ///      held it -- and {deposit}, {redeem} and {processQueue} all price and pay off that answer, so the T-184
    ///      boundary opened straight back up. It did not revert; it behaved normally and was wrong.
    ///      `IERC1155Receiver` declares this hook non-view, so dropping `view` conforms to the interface, and
    ///      mutability is not part of a selector, so the selector cannot move.
    ///      ONE CONCERN, ONE IMPLEMENTATION: both hooks route through {_noteIncoming} rather than each carrying
    ///      their own copy of the short test. Two hooks for one concern, only one of which recorded, is why this
    ///      survived review, and patching the second copy would have left the shape in place for the next reader.
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata
    ) external returns (bytes4) {
        if (msg.sender != address(clearinghouse)) revert V2Errors.NotAuthorized();
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            // Duplicate or repeated ids in one batch are safe: {_recordShort} returns early once the series is
            // tracked, so this is idempotent per series within a call as well as across calls. `values` is
            // indexed alongside `ids`; OpenZeppelin's `_update` reverts ERC1155InvalidArrayLength before any hook
            // runs if the two lengths differ.
            _noteIncoming(operator, from, ids[i], values[i]);
        }
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /// @dev THE ONE PLACE THE VAULT LEARNS IT IS SHORT, reached by both ERC-1155 hooks.
    ///      T-184. A fill is the only moment the vault learns an AskWrite of its own was filled: the Clearinghouse
    ///      mints the short to the writer, and ERC-1155 calls a receiver hook on that mint. `_orderIds` cannot
    ///      answer it -- an order is not a fill -- and `IClearinghouse.locked` is keyed by series rather than by
    ///      account. Longs arrive here too, for resale escrow, so the short test is what makes this a write and not
    ///      a purchase.
    ///      MUST NOT REVERT: this runs inside the mint, so a revert here would fail the fill rather than record it.
    ///      The long id of a short is the short with its low bit cleared -- V2Ids' own scheme, mirrored rather than
    ///      re-derived: "longId = keccak256(...) with the low bit cleared; shortId sets it". V2Ids has shortIdOf and
    ///      isShortId but no inverse, so it is spelled out here against that sentence.
    ///
    ///      T-298. ONLY A MINT IS A WRITE. The `msg.sender == clearinghouse` check in both hooks proves only that
    ///      the TOKEN CONTRACT called -- which every transfer of a Clearinghouse token does, and
    ///      {Clearinghouse.safeTransferFrom} / {Clearinghouse.safeBatchTransferFrom} are permissionless. So that
    ///      check alone let any account append series to {_openShorts}: a zero-value transfer passes OpenZeppelin's
    ///      `fromBalance < value` test from an empty balance, and nothing here read the amount. The fact this path
    ///      exists to learn is "an AskWrite of MINE was filled", and the one event that carries it is the mint:
    ///      `from == address(0)` is reachable only through {Clearinghouse.mint}, which requires an authorised minter
    ///      acting as this vault or as its operator (the book) and debits THIS VAULT'S free collateral. A short that
    ///      arrives by TRANSFER was written against someone else's collateral: it does not lower {totalAssets}, so it
    ///      is not the understated NAV the T-184 boundary exists for, and recording it would let any holder of one
    ///      unit hold the queue shut until that series settles and is redeemed. It is deliberately NOT recorded.
    ///      The book never moves a short id (`OrderBook` refuses short ids as order series), so no legitimate short
    ///      of the vault's own reaches it by transfer.
    ///      `value != 0` is implied by the mint (`BadUnits` on zero units) and is checked anyway, so a zero-unit
    ///      delivery can never become a tracker entry whatever route reaches this line.
    ///      DECLINE, NEVER THROW: an unrecorded delivery is accepted and simply not tracked, per MUST NOT REVERT above.
    ///
    ///      T-433. LONGS ARE RECORDED WHEN THE BOOK DELIVERS THEM. `operator` is whoever called the Clearinghouse,
    ///      and the book is the operator exactly when it moves a long to this vault: filling this vault's Bid (from
    ///      the seller's inventory, or by a `writeToSell` mint) or returning this vault's own AskResale escrow on
    ///      cancel or prune. Each of those is a long the vault paid for or already owned. A long any other account
    ///      TRANSFERS in directly carries some other `operator` and is not recorded, for the same reason a
    ///      transferred short is not: one gifted unit would otherwise hold deposits, exits and the queue shut. The
    ///      book never moves a long to a maker except to fill that maker's Bid or refund that maker's escrow.
    ///      DELIVERY_GAS (500k in `OrderBook`) caps the fill's transfer and this hook with it; recording is at most
    ///      three storage writes.
    function _noteIncoming(address operator, address from, uint256 id, uint256 value) private {
        if (value == 0) return;
        if (V2Ids.isShortId(id)) {
            if (from == address(0)) _recordShort(id & ~uint256(1));
        } else if (operator == address(orderBook)) {
            _recordLong(id);
        }
    }

    /// @inheritdoc IERC165
    /// @dev INTERFACE_VERSION 8: {Managed} declares no `supportsInterface`, so this target does not report
    ///      `type(IAccessControl).interfaceId`. Roles are not on the target any more.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Assets per {ONE_SHARE}, the scale {highWaterMark} is kept in. Zero supply has no price and answers 0.
    function _pricePerShare() private view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(totalAssets(), ONE_SHARE, supply);
    }

    /// @dev True while at least one queue slot is outstanding. ONE packed SLOAD -- {fundable} is on the book's
    ///      gas-capped quote path and cannot afford more.
    function _queueOpen() private view returns (bool) {
        return _head <= _tail;
    }

    /// @dev True while at least one outstanding entry still owes a withdrawal. ONE SLOAD, packed beside
    ///      `_head`/`_tail`. This is the funding gate, NOT {_queueOpen}: see `_openWithdrawals`. {skim} keeps
    ///      {_queueOpen} on purpose -- its refusal (SEC-16) is about the queue head being priced against the cash
    ///      the fee would come out of, which a queued DEPOSIT affects just as much as a withdrawal does.
    function _owesWithdrawal() private view returns (bool) {
        return _openWithdrawals != 0;
    }

    /// @inheritdoc IEarnVault
    function hasOpenShort() public view returns (bool) {
        uint256 n = _openShorts.length;
        for (uint256 i; i < n; ++i) {
            if (clearinghouse.balanceOf(address(this), V2Ids.shortIdOf(_openShorts[i])) != 0) return true;
        }
        return false;
    }

    /// @notice True while the vault holds any option position {totalAssets} cannot value: a short it wrote, a long
    ///         it bought through the book, or longs of its own escrowed in a live AskResale. While true, {deposit}
    ///         and {redeem} queue and {processQueue} serves nothing.
    /// @dev T-433. {hasOpenShort} keeps its exact meaning (shorts only) because {IEarnVault} documents it that way;
    ///      this is the whole boundary. NOT on {IEarnVault}: that interface is outside this task's `scope_paths`,
    ///      so it is declared on the contract only, like {outflow}.
    function hasOpenPosition() external view returns (bool) {
        return _positionOpen();
    }

    /// @inheritdoc IEarnVault
    function escrowedAssets() external view returns (uint256) {
        return _escrowedAssets;
    }

    /// @dev SWEEPS THE VAULT'S OWN PREMIUM OUT OF THE BOOK BEFORE ANYTHING IS PRICED. T-184, found by the AC-6
    ///      pair: with the queue working and the vault flat again, a queued depositor was minted at EXACTLY 1.0
    ///      share price -- the premium the vault had just earned was nowhere in {totalAssets}.
    ///
    ///      WHAT THE BOOK ACTUALLY DOES, and the sentence that used to be here had it backwards. `OrderBook`
    ///      PAYS A MAKER'S FILL PROCEEDS DIRECTLY: `_payOrOwe` (`OrderBook.sol:1235-1238`) attempts the USDG
    ///      transfer and credits `owed[maker]` ONLY when that transfer reverts or returns false
    ///      (`_tryTransfer`, `OrderBook.sol:1243-1246`). `owed` is therefore a FALLBACK for a payment that could
    ///      not be made, not the normal settlement path, and {IOrderBook.claimOwed} is how a maker collects one.
    ///      So the old claim -- that every premium this vault ever earned would sit in the book forever without
    ///      this call -- was too strong: ordinary fills land in this wallet and {totalAssets} sees them.
    ///
    ///      THE CALL IS STILL LOAD-BEARING, for the case that survives the correction. Anything the book could
    ///      not pay is in `owed` and is invisible to all three terms of {totalAssets} until it is claimed, so a
    ///      depositor or redeemer priced while a balance sits there is priced against an understated NAV -- which
    ///      is the T-184 AC-6 failure this was added for. {MakerVault.claimOwed} and {HouseVault.claimOwed} exist
    ///      for the same reason; this vault had no such path at all.
    ///
    ///      CALLED FROM EVERY PATH THAT PRICES, not from a keeper-only entry point, so the number a depositor or a
    ///      redeemer is measured against is complete at the instant they are measured. `claimOwed` returns silently
    ///      when nothing is owed (`OrderBook.sol:502`), so this is safe to call unconditionally and costs one SLOAD
    ///      when there is nothing to collect. It is deliberately NOT called from {fundable} or {fund}, which run
    ///      under the book's gas cap.
    function _claimOwed() private {
        orderBook.claimOwed();
    }

    /// @dev Wallet balance MINUS escrowed deposits: what this vault may actually spend. Every path that pays a
    ///      redeemer or moves assets to the venue measures against this, never against `balanceOf`.
    function _unescrowed() private view returns (uint256) {
        return _deliverable(_asset.balanceOf(address(this)), 0);
    }

    /// @dev THE ONE RULE {fundable} AND {fund} BOTH DERIVE FROM (T-OP-042): what this vault can put on the ledger
    ///      is a wallet balance MINUS the queued-deposit escrow sitting in it, plus whatever venue cash is offered.
    ///      Saturating: a wallet drained below the escrow by something unforeseen answers 0 rather than reverting
    ///      every read that depends on this. {fundable} passes the live wallet and the venue's `withdrawable`;
    ///      {fund} passes the wallet it measured and 0, before and after its venue pull. T-440 clamped {fund} and
    ///      not its mirrored view because the two computed the amount separately; with one helper they cannot
    ///      drift apart again.
    /// @param wallet A measured `_asset.balanceOf(address(this))`.
    /// @param venue Venue cash to count on top, or 0.
    function _deliverable(uint256 wallet, uint256 venue) private view returns (uint256) {
        uint256 total = wallet + venue;
        uint256 esc = _escrowedAssets;
        return total > esc ? total - esc : 0;
    }

    /// @dev Drops long ids this vault no longer holds a short on. Walks DOWNWARD and swaps the tail in, so a
    ///      removal never disturbs an entry the loop has yet to read -- the same shape as {_pruneAndCount}.
    function _pruneShorts() private {
        uint256 n = _openShorts.length;
        for (uint256 i = n; i != 0; --i) {
            uint256 longId = _openShorts[i - 1];
            if (clearinghouse.balanceOf(address(this), V2Ids.shortIdOf(longId)) != 0) continue;
            uint256 last = _openShorts.length - 1;
            if (i - 1 != last) {
                uint256 moved = _openShorts[last];
                _openShorts[i - 1] = moved;
                _openShortAt[moved] = i;
            }
            _openShorts.pop();
            delete _openShortAt[longId];
        }
    }

    /// @dev Records one written series. Idempotent: a second short on a series already tracked changes nothing.
    function _recordShort(uint256 longId) private {
        if (_openShortAt[longId] != 0) return;
        _openShorts.push(longId);
        _openShortAt[longId] = _openShorts.length;
    }

    /// @dev T-433. THE FLAT BOUNDARY, WHOLE. T-184 queued pricing while a short was open because the collateral it
    ///      locks leaves {totalAssets}; a Bid fill is the same shape from the other side -- its escrow leaves NAV as
    ///      a long no term can value -- so every option position the vault holds closes the boundary. A long in the
    ///      vault's own resale escrow is still the vault's, so it counts until it sells or comes back.
    ///      THE ALTERNATIVE WAS REJECTED, NOT MISSED: valuing longs in NAV needs a mark this vault can trust, and a
    ///      quoter-supplied or oracle-derived option mark is exactly what must never move the share price
    ///      ({IEarnVault.totalAssets}). Premium paid is stale the moment spot moves. Queueing keeps NAV cash-only.
    function _positionOpen() private view returns (bool) {
        return hasOpenShort() || _holdsLongs() || _resaleEscrowOpen();
    }

    /// @dev Both lazy prunes, run by every path that reads {_positionOpen} to decide.
    function _prunePositions() private {
        _pruneShorts();
        _pruneLongs();
    }

    /// @dev T-433. True while the vault still holds a long it acquired through the book.
    function _holdsLongs() private view returns (bool) {
        uint256 n = _heldLongs.length;
        for (uint256 i; i < n; ++i) {
            if (clearinghouse.balanceOf(address(this), _heldLongs[i]) != 0) return true;
        }
        return false;
    }

    /// @dev T-433. Drops long ids this vault no longer holds. The same shape as {_pruneShorts}.
    function _pruneLongs() private {
        uint256 n = _heldLongs.length;
        for (uint256 i = n; i != 0; --i) {
            uint256 longId = _heldLongs[i - 1];
            if (clearinghouse.balanceOf(address(this), longId) != 0) continue;
            uint256 last = _heldLongs.length - 1;
            if (i - 1 != last) {
                uint256 moved = _heldLongs[last];
                _heldLongs[i - 1] = moved;
                _heldLongAt[moved] = i;
            }
            _heldLongs.pop();
            delete _heldLongAt[longId];
        }
    }

    /// @dev T-433. Records one series the vault acquired longs on. Idempotent, like {_recordShort}.
    function _recordLong(uint256 longId) private {
        if (_heldLongAt[longId] != 0) return;
        _heldLongs.push(longId);
        _heldLongAt[longId] = _heldLongs.length;
    }

    /// @dev Escrows `assets` here, records the request and discloses it. Mirrors {_enqueue} for the other direction.
    function _enqueueDeposit(uint256 assets, address receiver) private returns (uint256 id) {
        _escrowedAssets += assets;
        unchecked {
            id = ++_tail;
        }
        _requests[id] = Request({owner: msg.sender, receiver: receiver, shares: 0, assets: assets});
        emit DepositQueued(id, msg.sender, receiver, assets);
    }

    /// @dev Escrows `shares` here, records the request and discloses it. The shares STAY IN `totalSupply`, which is
    ///      what makes the exit priced at service time rather than at request time.
    function _enqueue(uint256 shares, address receiver, uint256 shortfall) private returns (uint256 id) {
        _transfer(msg.sender, address(this), shares);
        unchecked {
            id = ++_tail;
            ++_openWithdrawals;
        }
        _requests[id] = Request({owner: msg.sender, receiver: receiver, shares: shares, assets: 0});
        emit WithdrawalQueued(id, msg.sender, receiver, shares, shortfall);
    }

    /// @dev Tops the wallet up towards `want` out of the venue and returns what the wallet holds AFTERWARDS,
    ///      MEASURED. Never reverts for a short venue: the caller decides what a short answer means.
    function _raise(uint256 want) private returns (uint256) {
        // T-184: escrowed deposits are not a source of liquidity for a redeemer. Measuring the raw wallet here
        // would pay one depositor with another's un-minted money.
        uint256 have = _unescrowed();
        if (have >= want) return have;
        IEarnVenueAdapter a = _adapter;
        if (address(a) == address(0)) return have;
        _pull(a, want - have);
        return _unescrowed();
    }

    /// @dev One venue withdrawal, credited as this vault's own balance delta and never as the adapter's return.
    function _pull(IEarnVenueAdapter a, uint256 assets) private returns (uint256 withdrawn) {
        uint256 before = _asset.balanceOf(address(this));
        a.withdraw(assets, address(this));
        withdrawn = _asset.balanceOf(address(this)) - before;
        emit PulledFromVenue(assets, withdrawn);
    }

    /// @dev Drops the vault's finished orders on `longId` and returns how many are still live. Walks DOWNWARD and
    ///      swaps the tail in, so a removal never disturbs a position the loop has yet to read.
    /// @dev BadPrice when a buying price is above intrinsic value plus {MAX_BID_BPS_OF_SPOT} of spot, or a
    ///      selling price below the ask floor of its kind. MIRRORED from {MakerVault._checkPrice} /
    ///      {HouseVault._checkPrice} rather than re-derived.
    ///
    ///      THE ASK TOLERANCE IS ZERO HERE AND THAT IS DELIBERATE. The siblings read `askToleranceBps` from a
    ///      stored `Limits` struct written at deploy time (DeployV8.s.sol:365, DevDeploy.s.sol:880). This vault
    ///      has no such struct, and inventing a compiled number would be exactly the re-reasoning the workspace
    ///      forbids - a tolerance is a tuned value, not a derivable one. So the ask floor used is the strictest
    ///      SOUND one, which needs no tuning to be correct: an ask may not sit below intrinsic value grossed for
    ///      the seller fee. A configurable tolerance is a clean follow-up once someone owns the numbers.
    ///
    ///      THE BID SIDE IS NO LONGER ZERO-TOLERANCE, AND THE OLD TEXT HERE WAS WRONG ABOUT WHY. It claimed a bid
    ///      capped at 100 % of spot was "the strictest SOUND" bound. It was not: `spot` prices the UNDERLYING
    ///      SHARE while `price` is an option premium, so that bound permitted paying a whole share's price for
    ///      one option. SEC-05 replaced it with intrinsic plus a bounded band of time value, and the band is
    ///      MIRRORED from the siblings' deployed `maxBidBpsOfSpot` (`script/v2/DevDeploy.s.sol:868`) rather than
    ///      chosen here. See {MAX_BID_BPS_OF_SPOT}.
    /// @param buying True for a Bid.
    /// @param primary Whether a sale at this price would MINT (AskWrite). Ignored when `buying`, because a
    ///        purchase pays no seller fee.
    function _checkPrice(V2Types.Series memory s, bool buying, bool primary, uint256 price) private view {
        (uint256 spot,) = ISettlementOracle(s.oracle).spot(s.underlying);
        if (spot == 0) revert V2Errors.NoSource();
        uint256 strike = s.strike;
        uint256 intrinsic;
        if (s.isPut) {
            if (strike > spot) intrinsic = strike - spot;
        } else if (spot > strike) {
            intrinsic = spot - strike;
        }
        if (buying) {
            // SEC-05. Intrinsic value plus a bounded band of time value. `intrinsic` is what the option is worth
            // if it settled now, so paying it is never an overpayment; everything above it is time value, which
            // is the only part a quoter can inflate. Bounding the BAND rather than the total is what keeps a
            // deep-ITM buy-back legal while still refusing a bid at the whole share price.
            if (price > intrinsic + spot * MAX_BID_BPS_OF_SPOT / V2Constants.BPS) revert V2Errors.BadPrice();
            return;
        }
        uint256 tolerance = spot * ASK_TOLERANCE_BPS / V2Constants.BPS;
        intrinsic = intrinsic > tolerance ? intrinsic - tolerance : 0;
        if (intrinsic == 0) return;
        V2Types.FeeParams memory f = orderBook.feeParams();
        uint256 sellerFeeBps = primary ? f.premiumFeeBps : f.resaleFeeBps;
        if (price < Math.ceilDiv(intrinsic * V2Constants.BPS, V2Constants.BPS - sellerFeeBps)) {
            revert V2Errors.BadPrice();
        }
    }

    /// @dev CeilingExceeded when a single order is larger than {MAX_SERIES_UNITS} units or {MAX_ORDER_NOTIONAL}
    ///      notional. Notional uses the siblings' formula, `units * strike / UNITS_PER_SHARE`
    ///      (`MakerVault._enforce`, src/v2/mm/MakerVault.sol:845). Read {MAX_ORDER_NOTIONAL} before relying on
    ///      this: it is a PER-ORDER bound, not the siblings' measured aggregate exposure.
    /// @param strike The series' strike, asset base units per whole share.
    /// @param units Order size, 0.01-share units.
    function _checkSize(uint256 strike, uint64 units) private pure {
        if (units > MAX_SERIES_UNITS) revert V2Errors.CeilingExceeded();
        if (uint256(units) * strike / V2Constants.UNITS_PER_SHARE > MAX_ORDER_NOTIONAL) {
            revert V2Errors.CeilingExceeded();
        }
    }

    /// @dev T-OP-039. THE AGGREGATE WRITE-SIDE BOUND, checked before an AskWrite is rested. Refuses
    ///      WrittenUnitsExceeded when the vault's written units on `longId` -- {_writtenUnits} plus this order --
    ///      would pass {MAX_WRITTEN_UNITS_PER_SERIES}, and WrittenNotionalExceeded when written notional summed over
    ///      every series the vault rests a write on ({_orderSeries}) or is short ({_openShorts}) would pass
    ///      {MAX_WRITTEN_NOTIONAL}. Both are the sibling's `_enforce` shape (`MakerVault:844`) restated over this
    ///      vault's own bookkeeping; no second ledger of shorts is introduced -- {_openShorts} is the one T-184 keeps
    ///      for {_positionOpen}, and the resting orders are read from the book the same way {_pruneAndCount} reads
    ///      them. A series in both lists is counted once. Bids and resales are not written exposure and skip this.
    function _checkWritten(uint256 longId, uint256 strike, uint64 units) private view {
        uint256 onSeries = _writtenUnits(longId) + units;
        if (onSeries > MAX_WRITTEN_UNITS_PER_SERIES) {
            revert WrittenUnitsExceeded(onSeries, MAX_WRITTEN_UNITS_PER_SERIES);
        }
        uint256 total = onSeries * strike / V2Constants.UNITS_PER_SHARE;
        uint256 n = _orderSeries.length;
        for (uint256 i; i < n; ++i) {
            uint256 other = _orderSeries[i];
            if (other != longId) total += _writtenNotional(other);
        }
        n = _openShorts.length;
        for (uint256 i; i < n; ++i) {
            uint256 other = _openShorts[i];
            if (other != longId && _orderSeriesAt[other] == 0) total += _writtenNotional(other);
        }
        if (total > MAX_WRITTEN_NOTIONAL) revert WrittenNotionalExceeded(total, MAX_WRITTEN_NOTIONAL);
    }

    /// @dev Written notional of one series: {_writtenUnits} x strike / UNITS_PER_SHARE, asset base units.
    function _writtenNotional(uint256 longId) private view returns (uint256) {
        uint256 units = _writtenUnits(longId);
        if (units == 0) return 0;
        return units * clearinghouse.series(longId).strike / V2Constants.UNITS_PER_SHARE;
    }

    /// @dev The vault's written units on `longId`: the unfilled remainder of every LIVE AskWrite it rests there
    ///      (read from the book, dead ids skipped rather than pruned -- this is a view) plus the shorts it holds,
    ///      net of the longs it holds on the same series, which offset them one for one (the sibling's `down`
    ///      side, `MakerVault._units`). Saturating at zero: a vault long more than it is short has written nothing.
    function _writtenUnits(uint256 longId) private view returns (uint256 written) {
        uint256[] storage ids = _orderIds[longId];
        uint256 n = ids.length;
        if (n != 0) {
            uint256[] memory snapshot = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                snapshot[i] = ids[i];
            }
            V2Types.Order[] memory orders = orderBook.getOrders(snapshot);
            for (uint256 i; i < n; ++i) {
                V2Types.Order memory o = orders[i];
                if (o.kind != V2Types.OrderKind.AskWrite) continue;
                if (o.maker == address(0) || o.cancelled || o.filled >= o.units || o.validUntil <= block.timestamp) {
                    continue;
                }
                written += o.units - o.filled;
            }
        }
        written += clearinghouse.balanceOf(address(this), V2Ids.shortIdOf(longId));
        uint256 longs = clearinghouse.balanceOf(address(this), longId);
        return written > longs ? written - longs : 0;
    }

    /// @dev The USDG the outflow cap measures: the wallet MINUS queued-deposit escrow, plus fill proceeds the book
    ///      still owes it. MIRRORED from `MakerVault._cash` (src/v2/mm/MakerVault.sol:638), which is
    ///      `usdg.balanceOf(this) + orderBook.owed(this)`. ONE TERM DIFFERS AND IT IS DELIBERATE: {_unescrowed}
    ///      replaces the raw wallet balance because assets escrowed by queued deposits belong to the depositors and
    ///      not to this vault (the same rule {totalAssets} follows).
    ///      THE CLEARINGHOUSE LEDGER IS EXCLUDED, AS THE SIBLING EXCLUDES IT (T-OP-042, from T-OP-020 F-3). An
    ///      earlier revision added `clearinghouse.free` here on the sentence "this vault funds bids from its
    ///      Clearinghouse balance", which {place} contradicts four lines above its own Bid check: the book pulls
    ///      Bid escrow from the RAW WALLET by allowance, and a Bid may spend only what {_unescrowed} says. No booked
    ///      call ({place}, {cancel}) moves `free`, so the term was inert -- and had a booked call ever moved it, it
    ///      would have credited collateral freed inside the call that was never charged, the loop the sibling's
    ///      contract NatSpec (MakerVault.sol:119-122) closes by excluding the ledger. The bucket charges NET WALLET
    ///      OUTFLOW, nothing else.
    function _cash() private view returns (uint256) {
        return _unescrowed() + orderBook.owed(address(this));
    }

    /// @dev The scaled bucket after the refill owed since {_outflowAt}, floored at 0. MIRRORED from
    ///      `MakerVault._refilled` (src/v2/mm/MakerVault.sol:644). `cap * elapsed` cannot overflow: cap is a
    ///      compiled constant below 2^128 and elapsed is below 2^40.
    function _refilled(uint256 cap) private view returns (uint256 s) {
        s = _outflowScaled;
        uint256 refill = cap * (block.timestamp - _outflowAt);
        s = s > refill ? s - refill : 0;
    }

    /// @dev Books the change of {_cash} across a booked call. A decrease is charged and, with `enforce`, reverts
    ///      `OutflowCapExceeded` when it would leave the bucket above the cap; an increase is credited and never
    ///      takes the bucket below 0. MIRRORED from `MakerVault._bookOutflow` (src/v2/mm/MakerVault.sol:658),
    ///      including its rule that `msg.sender` is NOT consulted -- the bound is a property of this contract
    ///      rather than of who holds which key. The bucket is kept scaled by {OUTFLOW_WINDOW} so the refill is
    ///      exact, and clamped to uint216 (unreachable at any supply: the clamp only makes a charge cheaper,
    ///      never a revert weaker).
    /// @param before {_cash} measured immediately before the call to the book.
    /// @param enforce Whether the cap may block this call. False for {cancel}, which can only credit.
    function _bookOutflow(uint256 before, bool enforce) private {
        uint256 cashAfter = _cash();
        if (cashAfter == before) return;
        uint256 s = _refilled(MAX_DAILY_OUTFLOW);
        if (cashAfter < before) {
            uint256 out = before - cashAfter;
            uint256 next = s + out * OUTFLOW_WINDOW;
            if (enforce && next > MAX_DAILY_OUTFLOW * OUTFLOW_WINDOW) {
                uint256 used = (s + OUTFLOW_WINDOW - 1) / OUTFLOW_WINDOW;
                revert V2Errors.OutflowCapExceeded(MAX_DAILY_OUTFLOW > used ? MAX_DAILY_OUTFLOW - used : 0, out);
            }
            s = next > type(uint216).max ? type(uint216).max : next;
        } else {
            uint256 back = (cashAfter - before) * OUTFLOW_WINDOW;
            s = s > back ? s - back : 0;
        }
        // casting is safe: `s` is clamped to uint216 above, and a credit only lowers it
        // forge-lint: disable-next-line(unsafe-typecast)
        _outflowScaled = uint216(s);
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        _outflowAt = uint40(block.timestamp);
    }

    /// @dev Drops dead ids from one series' list and returns how many are still live.
    ///      T-299: an EXPIRED order that was never cancelled still holds its escrow in the book -- {IOrderBook.prune}
    ///      is what hands it back. Dropping its id without pruning it would take that escrow out of {_bookEscrow}'s
    ///      sight while the book still held it, and NAV would step back up whenever anyone pruned it later. So such
    ///      orders are pruned here, in the same call, before their ids are forgotten. A prune the book skips (a
    ///      resale delivery that fails) holds longs, never asset, so it cannot hide NAV.
    function _pruneAndCount(uint256 longId) private returns (uint256 live) {
        uint256[] storage ids = _orderIds[longId];
        uint256 n = ids.length;
        if (n == 0) return 0;
        uint256[] memory snapshot = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            snapshot[i] = ids[i];
        }
        V2Types.Order[] memory orders = orderBook.getOrders(snapshot);
        uint256[] memory expired = new uint256[](n);
        uint256 nExpired;
        for (uint256 i = n; i != 0; --i) {
            V2Types.Order memory o = orders[i - 1];
            bool open = o.maker != address(0) && !o.cancelled && o.filled < o.units;
            if (open && o.validUntil > block.timestamp) {
                unchecked {
                    ++live;
                }
                continue;
            }
            if (open) expired[nExpired++] = snapshot[i - 1];
            ids[i - 1] = ids[ids.length - 1];
            ids.pop();
        }
        if (nExpired != 0) {
            assembly ("memory-safe") {
                mstore(expired, nExpired)
            }
            orderBook.prune(expired);
        }
    }

    /// @dev T-299. Adds `longId` to {_orderSeries} if absent. At the {MAX_ORDER_SERIES} bound it first drops every
    ///      tracked series whose list prunes to empty, and reverts `CeilingExceeded` only if none can go.
    function _trackSeries(uint256 longId) private {
        if (_orderSeriesAt[longId] != 0) return;
        if (_orderSeries.length >= MAX_ORDER_SERIES) {
            for (uint256 i = _orderSeries.length; i != 0; --i) {
                uint256 other = _orderSeries[i - 1];
                _pruneAndCount(other);
                if (_orderIds[other].length == 0) _untrackSeries(other);
            }
            if (_orderSeries.length >= MAX_ORDER_SERIES) revert V2Errors.CeilingExceeded();
        }
        _orderSeries.push(longId);
        _orderSeriesAt[longId] = _orderSeries.length;
    }

    /// @dev Swap-and-pop removal from {_orderSeries}; the same shape as {_pruneShorts}.
    function _untrackSeries(uint256 longId) private {
        uint256 at = _orderSeriesAt[longId];
        uint256 last = _orderSeries.length;
        if (at != last) {
            uint256 moved = _orderSeries[last - 1];
            _orderSeries[at - 1] = moved;
            _orderSeriesAt[moved] = at;
        }
        _orderSeries.pop();
        delete _orderSeriesAt[longId];
    }

    /// @dev T-299. Asset the book holds for this vault's Bids and would refund on cancel or prune: for each of the
    ///      vault's own Bids not cancelled and not fully filled -- INCLUDING ones past `validUntil` that nobody has
    ///      pruned yet, which are still refundable -- the book's own escrow formula over the unfilled units. The
    ///      same `OptionMath.premium` the book used to pull it and uses to refund it. ONE {IOrderBook.getOrders} call
    ///      over at most `MAX_ORDER_SERIES * MAX_LIVE_ORDERS_PER_SERIES` ids.
    ///      Ids already filled or cancelled contribute zero, so lazy compaction cannot inflate this; an id can
    ///      leave a list only through {_pruneAndCount}, which prunes an expired order before forgetting it.
    function _bookEscrow() private view returns (uint256 escrow) {
        V2Types.Order[] memory orders = _trackedOrders();
        uint256 n = orders.length;
        for (uint256 i; i < n; ++i) {
            V2Types.Order memory o = orders[i];
            if (o.kind != V2Types.OrderKind.Bid || !_holdsEscrow(o)) continue;
            escrow += OptionMath.premium(o.price, o.units - o.filled);
        }
    }

    /// @dev T-433. True while an AskResale of this vault's still escrows longs in the book -- live or expired and
    ///      unpruned, the same liveness {_bookEscrow} uses for asset. Same walk, same bound.
    function _resaleEscrowOpen() private view returns (bool) {
        V2Types.Order[] memory orders = _trackedOrders();
        uint256 n = orders.length;
        for (uint256 i; i < n; ++i) {
            if (orders[i].kind == V2Types.OrderKind.AskResale && _holdsEscrow(orders[i])) return true;
        }
        return false;
    }

    /// @dev An order of this vault's the book still holds escrow for: not cancelled, not fully filled.
    function _holdsEscrow(V2Types.Order memory o) private view returns (bool) {
        return !o.cancelled && o.filled < o.units && o.maker == address(this);
    }

    /// @dev Every order id the vault tracks, read in ONE {IOrderBook.getOrders} call over at most
    ///      `MAX_ORDER_SERIES * MAX_LIVE_ORDERS_PER_SERIES` ids. Shared by {_bookEscrow} and {_resaleEscrowOpen}.
    function _trackedOrders() private view returns (V2Types.Order[] memory orders) {
        uint256 nSeries = _orderSeries.length;
        uint256 total;
        for (uint256 i; i < nSeries; ++i) {
            total += _orderIds[_orderSeries[i]].length;
        }
        if (total == 0) return orders;
        uint256[] memory all = new uint256[](total);
        uint256 k;
        for (uint256 i; i < nSeries; ++i) {
            uint256[] storage ids = _orderIds[_orderSeries[i]];
            uint256 m = ids.length;
            for (uint256 j; j < m; ++j) {
                all[k++] = ids[j];
            }
        }
        orders = orderBook.getOrders(all);
    }

    /// @dev MIRRORED from `MakerVault._approveBook` (src/v2/mm/MakerVault.sol:708): operator rights so the book can
    ///      mint an AskWrite from this vault's ledger, ERC-1155 approval for resale escrow, and the asset allowance
    ///      for bid escrow.
    function _approveBook() private {
        address book = address(orderBook);
        clearinghouse.setOperator(book, true);
        clearinghouse.setApprovalForAll(book, true);
        _asset.forceApprove(book, type(uint256).max);
    }
}
