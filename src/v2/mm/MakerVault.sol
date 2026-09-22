// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Managed} from "../access/Managed.sol";
import {IClearinghouse} from "../interfaces/IClearinghouse.sol";
import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {V2Ids} from "../interfaces/V2Ids.sol";
import {V2Types} from "../interfaces/V2Types.sol";

/// @title MakerVault
/// @notice The protocol's treasury-funded market maker (roadmap 1.4, architecture §3.10): it holds USDG and Stock
///         Tokens, and a bot key holding QUOTER on the manager quotes and trades them inside on-chain guard rails.
///         The vault is the maker and taker of record; every proceed, fill and payout lands in the vault.
/// @dev UNITS (ADR-04). Prices, spot, intrinsic value and notional are USDG base units (6 dp) per whole share or in
///      total; units are 0.01-share units (ERC-1155 amounts); rates are bps of BPS = 10_000.
///
///      WHO CAN DO WHAT (INTERFACE_VERSION 8). The vault holds no role table: it is {Managed}, and one
///      `AccessManager` maps (this contract, selector) to a role id per `script/v2/roles.v8.json`.
///        - ANYONE: {deposit}. It pulls from `msg.sender` and can only add funds, so the Treasury Safe funds the
///          vault with no role at all and a donation is just a donation.
///        - TREASURY_ADMIN (the Admin Safe, 24 h): {withdraw} any ERC-20 and {withdrawPosition} of option tokens --
///          both to {treasury} and nowhere else -- {setTreasury} and {setLimits}. It CANNOT quote.
///        - QUOTER (the mm-bot key, K2-04, and the Admin Safe so it can cancel and close in an emergency) can only:
///          move vault funds into the vault's Clearinghouse ledger ({depositToClearinghouse}) and back
///          ({withdrawFromClearinghouse}, recipient fixed to the vault); {place}, {replace} and {cancel} the vault's
///          own orders; {take} with the vault as recipient; {close} long/short pairs; {claimOwed}; {sync} the
///          exposure bookkeeping; {refreshApprovals}.
///      The two sets are disjoint: no selector is mapped to both, so the treasury lane can never quote and the
///      quoting lane can never reach the money. Rotating a compromised quoter key is OPS_ADMIN, instant, on the
///      manager, and it never touches this contract.
///      NO QUOTER CALL PAYS ANYONE BUT THE VAULT. No quoter entry point names a recipient other than the vault: the
///      Clearinghouse withdrawal goes to the vault, a take must name the vault as recipient, the vault is the maker of
///      every order (proceeds and refunds go to the maker), and close frees collateral to the vault's own ledger. The
///      vault never mints directly, never sets an OrderBook delegate, and grants the Clearinghouse operator right, the
///      ERC-1155 approval and the USDG allowance only to the immutable OrderBook, which pulls from an account only
///      inside calls that account makes (place / replace as maker, take as msg.sender; delegates may never place Bids
///      or resale asks). What the quoter does control is PRICE, and that is enough to move value out: a compromised key
///      can trade the vault's inventory badly inside the guards below, each trade bounded by them and repeated trades
///      not. Buying a partner's ask at the bid cap and selling the longs back into the partner's bid at one tick leaves
///      the vault's exposure where it was and pays the partner the difference, so round trips can move the vault's
///      whole USDG balance to a counterparty (sweep contracts-c14). OPS_ADMIN revoking QUOTER on the manager stops
///      it (instant, and it never touches this contract), and the bot's realised-loss stop (K2-04) is the
///      off-chain bound.
///
///      PRICE GUARDS (checked when an order is placed or replaced and when a take is sent, against the series' pinned
///      oracle's `spot`, which reverts when stale or paused, so a stale oracle stops quoting):
///        - asks (AskWrite, AskResale, and the limit price of a selling take) never below
///          floor = ceil(base x BPS / (BPS - sellerFeeBps)), base = max(0, intrinsic - spot x askToleranceBps / BPS),
///          intrinsic = max(spot - strike, 0) for calls and max(strike - spot, 0) for puts, per share;
///        - bids (and the limit price of a buying take) never above spot x maxBidBpsOfSpot / BPS.
///      A standing order is not re-checked when it fills (the book never calls back), so {Limits.maxOrderLifetime}
///      bounds how long a quote placed at an old spot can stay live.
///
///      THE ASK FLOOR IS NET OF THE SELLER FEE (INTERFACE_VERSION 8). The book takes `premium x sellerFeeBps / BPS`
///      out of what a seller receives -- `premiumFeeBps` (5 % at launch) when the fill MINTS (an AskWrite, or a
///      `writeToSell` take) and `resaleFeeBps` when it sells inventory. A floor at the bare intrinsic value would
///      therefore let the vault sell at `intrinsic` and keep only 95 % of it, handing the difference to the buyer:
///      the guard that exists to stop value leaving would be crossed by the protocol's own fee. So the floor is
///      grossed up by that fee, rounded UP, and the net the vault receives is never below `base`.
///      THE RATE IS READ FROM THE BOOK, never copied: {IOrderBook.feeParams} already resolves any scheduled change,
///      so a fee rise moves the floor with it rather than silently lowering it. `BPS - sellerFeeBps` underflows and
///      reverts if a book ever reported a fee of 100 % or more, which is fail-closed; the book's own
///      `PREMIUM_FEE_CEIL_BPS` (10 %) keeps it far from there.
///      NOT IN THE FLOOR: the taker fee a SELLING TAKE also pays (`min(takerFeeFlat, premium x takerFeeCapBps / BPS)`,
///      0.10 USDG at launch). It is a flat per-call charge, not a rate on the price, so folding it in would make the
///      floor depend on size and diverge for dust; the size guards and the outflow cap bound that instead.
///      ONE CASE THE FLOOR STILL DOES NOT COVER: a resting ask placed under the old rate stays live when a scheduled
///      fee change takes effect (the book never calls back). {Limits.maxOrderLifetime} bounds that window, and the
///      48 h fee delay makes it visible before it happens.
///
///      SIZE GUARDS. Per series the vault's worst-case NET position if its live orders fill, in units:
///        up   = longs + resale escrow + open bid units - shorts          (every bid fills)
///        down = shorts + open write-ask units - longs                    (every ask fills; escrowed longs leave)
///        exposure = max(up, down, 0)                 must stay <= maxSeriesUnits
///        notional = exposure x strike / 100 (USDG)   Σ over series must stay <= maxTotalNotional
///      Longs and shorts of one series offset because a pair can always be closed. Notional is priced at the strike so
///      it needs no oracle and is stable: for a put it is exactly the collateral per unit, for a call the strike value.
///      A guarded action measures the series before and after itself (post-condition, so no fill logic is copied from
///      the book) and reverts CeilingExceeded when it leaves a cap exceeded AND grew the series' exposure; an action
///      that does not grow exposure is always allowed, so selling inventory still works after the admin lowers a cap.
///      Cancel and close are never size-checked.
///      BOOKKEEPING. The vault remembers its order ids per series (at most MAX_LIVE_ORDERS_PER_SERIES open ones, which
///      bounds gas) and stores each series' last measured notional plus their sum {totalNotional}. Fills by takers,
///      order expiry and settlement happen without the vault being called, and each of them can only LOWER a series'
///      worst case (a fill moves units from an open order into a position on the same side), so the stored values are
///      upper bounds: the total cap stays conservative, and {sync} (or any guarded action on that series, {cancel},
///      {close}) brings a series back to its true value. An AskResale past its validUntil still counts, as resale
///      escrow and as an open order, until a cancel or prune returns its longs to the vault: expiry does not hand them
///      back, so dropping them would free the cap for a position that doubles once they return (sweep contracts-c15).
///      The only way to raise a series' true exposure without the vault is to give it option tokens.
///
///      OUTFLOW CAP (INTERFACE_VERSION 7, v7 design §4.6). The price and size guards bound one trade; they do not bound
///      repeated ones. {Limits.maxDailyOutflow} does: it is a leaky bucket over the net USDG a quoter call may move out
///      of CASH = `usdg.balanceOf(vault) + orderBook.owed(vault)`, refilling linearly over {OUTFLOW_WINDOW}, so the
///      quoter can pay out at most the cap at once and at most twice the cap in any 24 h. {outflow} reports what is
///      used and what is left, and a booked call that would exceed it reverts V2Errors.OutflowCapExceeded.
///        - BOOKED AND ENFORCED: {place} and {replace} of a Bid, and {take}. BOOKED, NEVER ENFORCED: {cancel} naming a
///          Bid — a cancel can only give escrow back, and it must never be blockable. NOT BOOKED AT ALL: the ask side
///          of {place} / {replace}, {close}, {depositToClearinghouse}, {withdrawFromClearinghouse}, {claimOwed},
///          {sync}, {refreshApprovals}, the permissionless {deposit}, and the treasury lane ({withdraw},
///          {withdrawPosition}, {setLimits}, {setTreasury}) -- that lane is not quoting and pays the Treasury Safe
///          by construction, so an exhausted cap must never trap protocol money in the vault.
///        - Every booked call measures CASH immediately before it calls the book and again after, and charges (or
///          credits) the difference: a decrease is spending, an increase is escrow coming back.
///        - Resting bids are charged AT PLACEMENT, because anyone can fill them between vault calls at the quoter's
///          price. Cancelling one, or replacing it down, credits that escrow back.
///        - Anything that happens BETWEEN vault calls is never booked: fills of resting orders, keeper prunes,
///          redemptions, plain transfers in and admin deposits. Income arriving that way cannot be told apart from
///          USDG anyone sends in, so crediting it would let a round trip pay for its own next leg.
///        - The Clearinghouse ledger is EXCLUDED deliberately. A put's collateral is locked by a fill that happens
///          between vault calls (not booked) and freed by {close} inside one, so a measure that counted
///          `clearinghouse.free` would credit collateral that was never charged and re-open the very loop this cap
///          closes (v7 design §4.6.4; `test_outflowCap_putCollateralFreedByCloseIsNotACredit` pins it).
///        - The COLLATERAL RENT of c05 is therefore invisible here, by construction (v7 design §3.1). A call's rent is
///          in Stock Tokens, outside a USDG measure altogether; a put's is debited from `clearinghouse.free` and
///          credited back there by {close}, which this measure excludes. So minting and closing in a loop costs the
///          vault seconds of rent (paid to the treasury, not to an attacker) and never moves this counter. What the
///          vault DOES need is ledger headroom: an AskWrite fill and a `writeToSell` take both charge
///          `units x collateralPerUnit + mintFee`, so a ledger funded for the collateral alone leaves the ask unable
///          to fill (`test_outflowCap_rentOn_*` pin all of it).
///        - No oracle is read, so cancels, closes and ledger moves never depend on a fresh spot.
///      GUARANTEE: the net USDG moved out through booked calls over any interval of length `t` is at most
///      maxDailyOutflow x (1 + t / OUTFLOW_WINDOW), FOR EVERY CALLER. NOT bounded by this: option value sold at or
///      above the ask floor inside maxSeriesUnits / maxTotalNotional, which is realised at settlement rather than
///      paid out in USDG.
///      NO CALLER IS EXEMPT (INTERFACE_VERSION 8). v7 booked the admin's calls but never checked them, which was
///      only safe while the mm-bot key never held DEFAULT_ADMIN_ROLE -- a property a test had to keep asserting
///      about a key. v8 removes the exemption: the cap is a property of the contract, not of who holds which key,
///      and the Admin Safe is itself a QUOTER member (roles.v8.json `holders`) so the exemption would have applied
///      to a quoting Safe anyway. Unwinding is not blocked by this, because unwinding only ever CREDITS the bucket:
///      {cancel} is booked and never enforced, and {close}, {claimOwed}, {sync} and the ledger moves are not booked
///      at all. {withdraw} and {withdrawPosition} are not booked either -- they are not quoting, and their recipient
///      is the Treasury Safe by construction.
///      THE ONE EXCEPTION, and it is the only booked call that can charge while selling: {take} books with
///      `enforce` true whichever side it is on, so a SELLING take whose premium does not cover the flat taker fee
///      is a net outflow and is charged like any other. At cap 0 that dust sale reverts OutflowCapExceeded. v7 hid
///      this behind the admin exemption; with no exemption there is no caller who can push it through.
///      Kill switches, in order: the bot's own kill (cancels everything, credits only) -> {setLimits} with
///      maxDailyOutflow 0, an on-chain spend freeze that still allows asks, cancels, closes, ledger moves and any
///      sale whose premium covers the taker fee (see THE ONE EXCEPTION above) ->
///      OPS_ADMIN revokes QUOTER on the manager (instant) -> the guardian's OrderBook trading pause.
///
///      APPROVALS. The constructor makes the OrderBook the vault's Clearinghouse operator (write-on-fill asks and
///      writeToSell), approves it for the vault's ERC-1155 tokens (resale escrow and selling from inventory) and grants
///      it an unlimited USDG allowance (bid escrow and buying). Deposits into the Clearinghouse approve exactly the
///      amount per call. The vault accepts ERC-1155 tokens from the Clearinghouse only (fills, escrow refunds, prunes),
///      and keeps the Clearinghouse defaults: anyone may redeem the vault's settled tokens, and payouts go to the vault.
contract MakerVault is IERC1155Receiver, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The admin-set guard rails. Two storage slots from INTERFACE_VERSION 7.
    /// @dev `maxDailyOutflow` was APPENDED in INTERFACE_VERSION 7, so `setLimits` changed selector (0x6693cc27) and
    ///      `LimitsSet` changed topic; `limits()` keeps its selector and returns six fields. Appended, never inserted,
    ///      for the reason V2Types gives: a decoder built on the v6 tuple keeps reading the first five correctly.
    struct Limits {
        uint64 maxSeriesUnits; // 0.01-share units: worst-case net position per series (see SIZE GUARDS)
        uint128 maxTotalNotional; // USDG base units: Σ over series of exposure x strike / 100
        uint16 askToleranceBps; // bps of spot subtracted from intrinsic value for the ask floor, <= BPS
        uint16 maxBidBpsOfSpot; // bid / buying-take price cap, bps of spot, <= BPS
        uint32 maxOrderLifetime; // seconds an order may stay live from placement; 0 = up to the series limit
        // v7: USDG base units the quoter may pay out net at once; refills linearly per OUTFLOW_WINDOW (see OUTFLOW
        // CAP). 0 freezes spending without blocking any unwinding
        uint128 maxDailyOutflow;
    }

    /// @notice What the vault holds and has open on one series, in 0.01-share units.
    struct Exposure {
        uint256 longs; // long tokens in the vault's wallet
        uint256 shorts; // short tokens in the vault's wallet
        uint256 bids; // unfilled units of live Bid orders
        uint256 resale; // unfilled units of AskResale orders not cancelled or pruned, expired too (escrowed longs)
        uint256 writes; // unfilled units of live AskWrite orders
        uint256 live; // number of open orders: the live ones plus expired AskResale orders still holding longs
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Most live orders the vault keeps on one series, counting an expired AskResale not yet cancelled or
    ///         pruned; {place} reverts CeilingExceeded beyond it. Bounds the gas of every exposure measurement.
    uint256 public constant MAX_LIVE_ORDERS_PER_SERIES = 16;

    /// @notice The window {Limits.maxDailyOutflow} refills over: a full bucket refills linearly in this much time
    ///         (INTERFACE_VERSION 7).
    uint256 public constant OUTFLOW_WINDOW = 1 days;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Clearinghouse the OrderBook trades (read from the book at deployment).
    IClearinghouse public immutable clearinghouse;
    /// @notice The OrderBook the vault quotes on.
    IOrderBook public immutable orderBook;
    /// @notice USDG (6 dp), the Clearinghouse's.
    IERC20 public immutable usdg;

    Limits private _limits;

    /// @dev The leaky bucket behind {Limits.maxDailyOutflow}: net USDG charged to the quoter, multiplied by
    ///      OUTFLOW_WINDOW so the refill of `cap` per window is exact and needs no rounding, as of {_outflowAt} and
    ///      before that refill. One slot with {_outflowAt}. INTERFACE_VERSION 7 (v7 design §4.6).
    uint216 private _outflowScaled;
    uint40 private _outflowAt;

    /// @notice Σ {seriesNotional}, USDG base units.
    uint256 public totalNotional;

    /// @notice Last measured notional of `longId` (exposure x strike / 100), USDG base units. An upper bound of the
    ///         current value between measurements (contract NatSpec, BOOKKEEPING).
    mapping(uint256 longId => uint256) public seriesNotional;

    /// @dev Order ids the vault placed on a series; dead ones are removed at the next measurement.
    mapping(uint256 longId => uint256[]) private _orderIds;

    /// @dev Series with non-zero stored notional, and 1-based positions in that list.
    uint256[] private _tracked;
    mapping(uint256 longId => uint256) private _trackedPos;

    /// @notice The only address {withdraw} and {withdrawPosition} can pay: the Treasury Safe
    ///         (INTERFACE_VERSION 8).
    /// @dev A constructor argument, changed only by TREASURY_ADMIN through {setTreasury}, and never zero. Protocol
    ///      money therefore has exactly one exit and no caller chooses where it goes.
    address public treasury;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice `from` added `amount` base units of `asset` to the vault (the measured balance delta). Anyone may.
    event Deposited(address indexed asset, address indexed from, uint256 amount);
    /// @notice TREASURY_ADMIN sent `amount` base units of `asset` from the vault to `to`, which is always
    ///         {treasury} from INTERFACE_VERSION 8.
    event Withdrawn(address indexed asset, address indexed to, uint256 amount);
    /// @notice TREASURY_ADMIN sent `units` of Clearinghouse token `tokenId` from the vault to `to`, which is always
    ///         {treasury} from INTERFACE_VERSION 8.
    event PositionWithdrawn(uint256 indexed tokenId, address indexed to, uint256 units);
    /// @notice TREASURY_ADMIN set the guard rails.
    event LimitsSet(Limits limits);
    /// @notice TREASURY_ADMIN set the only address {withdraw} and {withdrawPosition} can pay (INTERFACE_VERSION 8).
    event TreasurySet(address indexed treasury);
    /// @notice The stored exposure of `longId` changed: `units` (0.01-share), `notional` and the new `totalNotional`
    ///         (USDG base units).
    event ExposureSet(uint256 indexed longId, uint256 units, uint256 notional, uint256 totalNotional);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param orderBook_ The OrderBook; its `clearinghouse()` and that Clearinghouse's `usdg()` become immutable.
    /// @param authority_ The `AccessManager` that gates every privileged selector (NoSource when it has no code).
    ///        INTERFACE_VERSION 8: no role is granted here and none is held here.
    /// @param treasury_ The Treasury Safe: the only address {withdraw} and {withdrawPosition} can ever pay
    ///        (NotAuthorized when zero).
    /// @param limits_ Initial guard rails (CeilingExceeded when a bps field is above BPS).
    constructor(IOrderBook orderBook_, address authority_, address treasury_, Limits memory limits_)
        Managed(authority_)
    {
        IClearinghouse ch = IClearinghouse(orderBook_.clearinghouse());
        clearinghouse = ch;
        orderBook = orderBook_;
        usdg = IERC20(ch.usdg());
        _setTreasury(treasury_);
        _setLimits(limits_);
        _approveBook();
    }

    /*//////////////////////////////////////////////////////////////
                        FUNDING AND TREASURY EXITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pulls `amount` base units of `asset` from the caller into the vault. ANYONE (INTERFACE_VERSION 8).
    /// @dev PERMISSIONLESS ON PURPOSE. It pulls from `msg.sender` and can only ADD funds, so it hands no caller any
    ///      power the vault did not already give everyone: a plain ERC-20 transfer to the vault funds it just as
    ///      well and always could. Making it permissionless is what lets the Treasury Safe fund the vault with no
    ///      role and no 24 h delay. The selector does not move. Measures the balance delta, so {Deposited} reports
    ///      what actually arrived (a fee-on-transfer token credits less than `amount`).
    ///      A donation is NOT a budget: USDG that arrives this way is invisible to the outflow cap, which measures
    ///      only the change across a booked quoter call (see OUTFLOW CAP).
    /// @param asset USDG or a Stock Token.
    /// @param amount Base units of `asset` to pull (approve the vault first).
    /// @return received Base units that arrived.
    function deposit(address asset, uint256 amount) external nonReentrant returns (uint256 received) {
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - before;
        emit Deposited(asset, msg.sender, received);
    }

    /// @notice Sends `amount` base units of `asset` from the vault's wallet to {treasury}. TREASURY_ADMIN (24 h).
    /// @dev INTERFACE_VERSION 8 DELETED v7's `withdraw(address,uint256,address)`: the free `to` argument is gone, so
    ///      `withdraw` is no longer an overloaded name and vault money has exactly one exit. The
    ///      `Withdrawn(asset, to, amount)` topic is unchanged and now always reports {treasury}.
    ///      Funds in the vault's Clearinghouse ledger come back first with {withdrawFromClearinghouse}.
    /// @param asset Any ERC-20 the vault holds.
    /// @param amount Base units.
    function withdraw(address asset, uint256 amount) external nonReentrant restricted {
        address to = treasury;
        emit Withdrawn(asset, to, amount);
        IERC20(asset).safeTransfer(to, amount);
    }

    /// @notice Sets the only address {withdraw} and {withdrawPosition} can pay. TREASURY_ADMIN (24 h).
    /// @param treasury_ The Treasury Safe; zero is refused (`NotAuthorized`).
    function setTreasury(address treasury_) external nonReentrant restricted {
        _setTreasury(treasury_);
    }

    /// @notice Sends `units` of the vault's Clearinghouse token `tokenId` (long or short) to {treasury}.
    ///         TREASURY_ADMIN (24 h).
    /// @dev INTERFACE_VERSION 8 DELETED v7's `withdrawPosition(uint256,uint256,address)`: the free `to` argument is
    ///      gone, for the same reason as in {withdraw}, so a position can only be unwound INTO the Treasury Safe.
    ///      The design draft missed this one; 03-INTERFACES §2.7 names it explicitly. For unwinding by hand.
    ///      Refreshes the series' stored exposure afterwards, so the caps see the smaller position at once.
    /// @param tokenId Long or short id.
    /// @param units 0.01-share units.
    function withdrawPosition(uint256 tokenId, uint256 units) external nonReentrant restricted {
        address to = treasury;
        emit PositionWithdrawn(tokenId, to, units);
        clearinghouse.safeTransferFrom(address(this), to, tokenId, units, "");
        _refresh(tokenId & ~uint256(1));
    }

    /// @notice Sets the guard rails. TREASURY_ADMIN (24 h).
    /// @dev CeilingExceeded when askToleranceBps or maxBidBpsOfSpot is above BPS. Applies to the next guarded action;
    ///      live orders are not touched (cancel them to apply a tighter price guard at once). The outflow bucket is
    ///      settled against the OLD maxDailyOutflow first, so raising the cap never back-dates the faster refill and
    ///      lowering it (to 0, the spend freeze) never wipes what is already used.
    /// @param limits_ See {Limits}.
    function setLimits(Limits calldata limits_) external nonReentrant restricted {
        _setLimits(limits_);
    }

    /*//////////////////////////////////////////////////////////////
                         CLEARINGHOUSE LEDGER
    //////////////////////////////////////////////////////////////*/

    /// @notice Moves `amount` base units of `asset` from the vault's wallet into the vault's Clearinghouse ledger (write
    ///         collateral). QUOTER only.
    /// @param asset USDG or a registered underlying.
    /// @param amount Base units.
    function depositToClearinghouse(address asset, uint256 amount) external nonReentrant restricted {
        IERC20(asset).forceApprove(address(clearinghouse), amount);
        clearinghouse.deposit(asset, amount, address(this));
    }

    /// @notice Moves `amount` base units of `asset` from the vault's Clearinghouse ledger back to the vault's wallet.
    ///         QUOTER only. The recipient is always the vault.
    /// @param asset USDG or a registered underlying.
    /// @param amount Base units (InsufficientCollateral above the free balance).
    function withdrawFromClearinghouse(address asset, uint256 amount) external nonReentrant restricted {
        clearinghouse.withdraw(asset, amount, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                QUOTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Places a vault order on the book. QUOTER only.
    /// @dev Reverts, before the book is called: UnknownSeries; the oracle's spot revert (stale, paused, no source) or
    ///      NoSource for a zero spot; BadPrice for a Bid above the bid cap or an ask below the ask floor; PastCutoff for
    ///      a validUntil beyond now + maxOrderLifetime (a zero validUntil becomes that bound when it is earlier than
    ///      the series limit); CeilingExceeded with MAX_LIVE_ORDERS_PER_SERIES live orders on the series. After: the
    ///      size guards (CeilingExceeded), then the outflow cap for a Bid (OutflowCapExceeded — a Bid escrows USDG at
    ///      placement, see OUTFLOW CAP; an ask escrows no USDG and is never booked). Everything else is the book's own
    ///      validation.
    /// @param longId Series long id.
    /// @param kind Bid (escrows vault USDG), AskResale (escrows vault longs) or AskWrite (mints from the vault ledger).
    /// @param price USDG base units per whole share.
    /// @param units 0.01-share units.
    /// @param validUntil Unix seconds, exclusive; 0 = the latest allowed.
    /// @return orderId The book's order id.
    function place(uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units, uint40 validUntil)
        external
        nonReentrant
        restricted
        returns (uint256 orderId)
    {
        V2Types.Series memory s = _series(longId);
        bool bid = kind == V2Types.OrderKind.Bid;
        _checkPrice(s, bid, kind == V2Types.OrderKind.AskWrite, price);
        validUntil = _boundLifetime(s, kind, validUntil);
        Exposure memory before = _measure(longId);
        if (before.live >= MAX_LIVE_ORDERS_PER_SERIES) revert V2Errors.CeilingExceeded();

        uint256 cashBefore = bid ? _cash() : 0;
        orderId = orderBook.place(longId, kind, price, units, validUntil);
        _orderIds[longId].push(orderId);
        _enforce(longId, s.strike, _units(before), _units(_measure(longId)));
        if (bid) _bookOutflow(cashBefore, true);
    }

    /// @notice Replaces a vault order (the book cancels it and places a new one, same series, kind and validUntil).
    ///         QUOTER only.
    /// @dev OrderNotLive for an unknown id, NotAuthorized for an order the vault did not place; then the price guard of
    ///      the order's kind on `newPrice`, the book's replace, the size guards, and the outflow cap when the order is
    ///      a Bid (OutflowCapExceeded). Replacing a Bid books the NET escrow change, so a replacement that costs less
    ///      escrow than the order it cancels is a credit and never reverts on the cap.
    /// @param orderId A live vault order.
    /// @param newPrice USDG base units per whole share.
    /// @param newUnits 0.01-share units.
    /// @return newOrderId The replacement's id.
    function replace(uint256 orderId, uint128 newPrice, uint64 newUnits)
        external
        nonReentrant
        restricted
        returns (uint256 newOrderId)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        V2Types.Order memory o = orderBook.getOrders(ids)[0];
        if (o.maker == address(0)) revert V2Errors.OrderNotLive(orderId);
        if (o.maker != address(this)) revert V2Errors.NotAuthorized();
        V2Types.Series memory s = _series(o.longId);
        bool bid = o.kind == V2Types.OrderKind.Bid;
        _checkPrice(s, bid, o.kind == V2Types.OrderKind.AskWrite, newPrice);
        Exposure memory before = _measure(o.longId);

        uint256 cashBefore = bid ? _cash() : 0;
        newOrderId = orderBook.replace(orderId, newPrice, newUnits);
        _orderIds[o.longId].push(newOrderId);
        _enforce(o.longId, s.strike, _units(before), _units(_measure(o.longId)));
        if (bid) _bookOutflow(cashBefore, true);
    }

    /// @notice Cancels vault orders; refunds go to the vault. QUOTER only. Never price-, size- or cap-checked.
    /// @dev The book reverts OrderNotLive for an unknown id and NotAuthorized for an order that is not the vault's, and
    ///      skips ids already cancelled or filled. Refreshes the stored exposure of every series touched. When one of
    ///      the ids names a Bid the returned escrow is CREDITED to the outflow bucket, but the cap is never enforced
    ///      here: a cancel can only give USDG back and must stay callable while the bucket is empty or the cap is 0.
    /// @param orderIds Vault order ids.
    function cancel(uint256[] calldata orderIds) external nonReentrant restricted {
        V2Types.Order[] memory orders = orderBook.getOrders(orderIds);
        bool anyBid;
        for (uint256 i; i < orders.length; ++i) {
            if (orders[i].kind == V2Types.OrderKind.Bid) {
                anyBid = true;
                break;
            }
        }
        uint256 cashBefore = anyBid ? _cash() : 0;
        orderBook.cancel(orderIds);
        if (anyBid) _bookOutflow(cashBefore, false);
        for (uint256 i; i < orders.length; ++i) {
            uint256 longId = orders[i].longId;
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (orders[j].longId == longId) {
                    seen = true;
                    break;
                }
            }
            if (!seen) _refresh(longId);
        }
    }

    /// @notice Takes liquidity for the vault. QUOTER only.
    /// @dev NotAuthorized unless p.recipient is the vault (longs bought and USDG from a sale both come back here).
    ///      Price guard on p.limitPrice: buying never above the bid cap, selling never below the ask floor, so no fill
    ///      of the take can be priced outside them (the book fills asks <= and bids >= the limit). The book pulls USDG
    ///      for a purchase from the vault's wallet; writeToSell mints from the vault's ledger. Size guards after, then
    ///      the outflow cap (OutflowCapExceeded). Every take is booked, buying or selling: a buy spends USDG, a sale
    ///      brings it in net of the taker fee, and only the net of the call is charged.
    /// @param p The book's take parameters, with recipient = this vault.
    /// @return unitsFilled 0.01-share units.
    /// @return premium USDG base units.
    /// @return takerFee USDG base units.
    function take(V2Types.TakeParams calldata p)
        external
        nonReentrant
        restricted
        returns (uint64 unitsFilled, uint256 premium, uint256 takerFee)
    {
        if (p.recipient != address(this)) revert V2Errors.NotAuthorized();
        V2Types.Series memory s = _series(p.longId);
        _checkPrice(s, p.buying, p.writeToSell, p.limitPrice);
        Exposure memory before = _measure(p.longId);

        uint256 cashBefore = _cash();
        (unitsFilled, premium, takerFee) = orderBook.take(p);
        _enforce(p.longId, s.strike, _units(before), _units(_measure(p.longId)));
        _bookOutflow(cashBefore, true);
    }

    /// @notice Burns `units` long and short of `longId` from the vault's wallet and frees their collateral into the
    ///         vault's Clearinghouse ledger. QUOTER only. Never price- or size-checked.
    /// @param longId Series long id (unsettled).
    /// @param units 0.01-share units of each side.
    function close(uint256 longId, uint64 units) external nonReentrant restricted {
        clearinghouse.close(longId, units);
        _refresh(longId);
    }

    /// @notice Withdraws the vault's {IOrderBook.owed} USDG (payments the book could not make) to the vault.
    ///         QUOTER only.
    function claimOwed() external nonReentrant restricted {
        orderBook.claimOwed();
    }

    /// @notice Re-measures the stored exposure of each series (drops orders that filled, were cancelled or pruned, or
    ///         expired, except an expired AskResale whose longs the book still holds; positions that were redeemed).
    ///         QUOTER only.
    /// @param longIds Series long ids; {trackedSeries} lists every series with stored notional.
    function sync(uint256[] calldata longIds) external nonReentrant restricted {
        for (uint256 i; i < longIds.length; ++i) {
            _refresh(longIds[i]);
        }
    }

    /// @notice Re-issues the three OrderBook approvals made at deployment (operator, ERC-1155 approval, unlimited USDG
    ///         allowance). QUOTER only. Idempotent; only ever approves the immutable book.
    function refreshApprovals() external nonReentrant restricted {
        _approveBook();
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The guard rails.
    function limits() external view returns (Limits memory) {
        return _limits;
    }

    /// @notice Net USDG the quoter has paid out inside the window, and what it may still pay out before a call
    ///         reverts OutflowCapExceeded (INTERFACE_VERSION 7).
    /// @dev `used` is rounded up, so `available` is never overstated. The bucket refills linearly: `used` falls by
    ///      {Limits.maxDailyOutflow} per OUTFLOW_WINDOW of elapsed time and never below 0.
    /// @return used USDG base units charged and not yet refilled.
    /// @return available USDG base units still spendable at once.
    function outflow() external view returns (uint256 used, uint256 available) {
        uint256 cap = _limits.maxDailyOutflow;
        used = (_refilled(cap) + OUTFLOW_WINDOW - 1) / OUTFLOW_WINDOW;
        available = cap > used ? cap - used : 0;
    }

    /// @notice The vault's current exposure on `longId`, measured now (not the stored value).
    /// @param longId Series long id.
    /// @return units Worst-case net position, 0.01-share units.
    /// @return notional units x strike / 100, USDG base units.
    /// @return detail Holdings and open order units the figure is computed from.
    function exposure(uint256 longId) external view returns (uint256 units, uint256 notional, Exposure memory detail) {
        (detail,,) = _scan(longId);
        units = _units(detail);
        notional = units * clearinghouse.series(longId).strike / V2Constants.UNITS_PER_SHARE;
    }

    /// @notice Order ids the vault remembers on `longId`: every live vault order and every expired AskResale not yet
    ///         cancelled or pruned, plus dead ones not yet dropped.
    function orderIdsOf(uint256 longId) external view returns (uint256[] memory) {
        return _orderIds[longId];
    }

    /// @notice Series with non-zero stored notional (the input for a full {sync}).
    function trackedSeries() external view returns (uint256[] memory) {
        return _tracked;
    }

    /// @notice The lowest PRIMARY ask price the vault may place on `longId` now (an AskWrite, or the limit price of
    ///         a `writeToSell` take), USDG base units per share.
    /// @dev Grossed up by the book's `premiumFeeBps`, so the vault's NET is never below the bare floor (contract
    ///         NatSpec, THE ASK FLOOR IS NET OF THE SELLER FEE). Equal to `askFloorOf(longId, true)`. Reverts like the
    ///         oracle's spot when it is stale or paused, UnknownSeries for an unknown id.
    function askFloor(uint256 longId) external view returns (uint256) {
        V2Types.Series memory s = _series(longId);
        return _askFloor(s, _spot(s), _sellerFeeBps(true));
    }

    /// @notice The lowest ask price the vault may place on `longId` now for a sale of the given kind, USDG base
    ///         units per share.
    /// @dev A resale of inventory pays `resaleFeeBps` instead of `premiumFeeBps`, so its floor is lower whenever the
    ///      two rates differ (0 and 500 at launch). Named, not overloaded, so `askFloor.selector` stays unambiguous.
    /// @param longId Series long id.
    /// @param primary True for a fill that MINTS (AskWrite, or a `writeToSell` take), false for an AskResale or a
    ///        take that sells inventory.
    function askFloorOf(uint256 longId, bool primary) external view returns (uint256) {
        V2Types.Series memory s = _series(longId);
        return _askFloor(s, _spot(s), _sellerFeeBps(primary));
    }

    /// @notice The highest bid price the vault may place on `longId` now, USDG base units per share.
    /// @dev Reverts like {askFloor}.
    function bidCap(uint256 longId) external view returns (uint256) {
        V2Types.Series memory s = _series(longId);
        return _spot(s) * _limits.maxBidBpsOfSpot / V2Constants.BPS;
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-1155 RECEIVER
    //////////////////////////////////////////////////////////////*/

    /// @notice Accepts Clearinghouse tokens (bid fills, bought longs, shorts of write-on-fill asks, escrow refunds);
    ///         reverts NotAuthorized for any other ERC-1155 contract.
    /// @dev Not guarded and state-free: it runs inside the vault's own guarded calls and inside other people's takes.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(clearinghouse)) revert V2Errors.NotAuthorized();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @notice Batch twin of {onERC1155Received}.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(clearinghouse)) revert V2Errors.NotAuthorized();
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /// @inheritdoc IERC165
    /// @dev INTERFACE_VERSION 8: {Managed} declares no `supportsInterface`, so the vault no longer reports
    ///      `type(IAccessControl).interfaceId`. Roles are not on this target any more.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev The USDG the outflow cap measures: the vault's wallet plus what the book still owes it. The Clearinghouse
    ///      ledger is excluded on purpose (contract NatSpec, OUTFLOW CAP).
    function _cash() private view returns (uint256) {
        return usdg.balanceOf(address(this)) + orderBook.owed(address(this));
    }

    /// @dev The scaled bucket after the refill owed since {_outflowAt}, floored at 0. `cap * elapsed` cannot overflow:
    ///      cap < 2^128 and elapsed < 2^40.
    function _refilled(uint256 cap) private view returns (uint256 s) {
        s = _outflowScaled;
        uint256 refill = cap * (block.timestamp - _outflowAt);
        s = s > refill ? s - refill : 0;
    }

    /// @dev Books the change of {_cash} across a booked call (contract NatSpec, OUTFLOW CAP). A decrease is charged
    ///      and, with `enforce`, reverts OutflowCapExceeded when it would leave the bucket above the cap; an increase
    ///      is credited and never takes the bucket below 0. INTERFACE_VERSION 8: there is NO caller exemption --
    ///      `msg.sender` is not consulted at all, so the bound is a property of the contract rather than of who holds
    ///      which key. The bucket is kept scaled by OUTFLOW_WINDOW so the refill is exact, and clamped to uint216
    ///      (unreachable at any USDG supply: the clamp only makes a charge cheaper, never a revert weaker).
    /// @param before {_cash} measured immediately before the call to the book.
    /// @param enforce Whether the cap may block this call. False for {cancel}, which can only credit.
    function _bookOutflow(uint256 before, bool enforce) private {
        uint256 cashAfter = _cash();
        if (cashAfter == before) return;
        uint256 cap = _limits.maxDailyOutflow;
        uint256 s = _refilled(cap);
        if (cashAfter < before) {
            uint256 out = before - cashAfter;
            uint256 next = s + out * OUTFLOW_WINDOW;
            if (enforce && next > cap * OUTFLOW_WINDOW) {
                uint256 used = (s + OUTFLOW_WINDOW - 1) / OUTFLOW_WINDOW;
                revert V2Errors.OutflowCapExceeded(cap > used ? cap - used : 0, out);
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

    /// @dev Stores the Treasury Safe. Zero is refused, so {withdraw} and {withdrawPosition} never burn vault assets
    ///      and never need a "treasury unset" branch that could be reached with money in the vault.
    function _setTreasury(address treasury_) private {
        if (treasury_ == address(0)) revert V2Errors.NotAuthorized();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @dev Stores the guard rails. The outflow bucket is settled against the OLD cap first, so a new cap never
    ///      refills time that has already passed, a cap of 0 freezes the level instead of clearing it, and the
    ///      constructor (old cap 0, empty bucket) starts at 0.
    function _setLimits(Limits memory l) private {
        if (l.askToleranceBps > V2Constants.BPS || l.maxBidBpsOfSpot > V2Constants.BPS) {
            revert V2Errors.CeilingExceeded();
        }
        // casting is safe: {_refilled} only ever lowers the stored uint216
        // forge-lint: disable-next-line(unsafe-typecast)
        _outflowScaled = uint216(_refilled(_limits.maxDailyOutflow));
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        _outflowAt = uint40(block.timestamp);
        _limits = l;
        emit LimitsSet(l);
    }

    function _approveBook() private {
        address book = address(orderBook);
        clearinghouse.setOperator(book, true);
        clearinghouse.setApprovalForAll(book, true);
        usdg.forceApprove(book, type(uint256).max);
    }

    /// @dev The stored series of a long id, or UnknownSeries (a short id or an id never created).
    function _series(uint256 longId) private view returns (V2Types.Series memory s) {
        s = clearinghouse.series(longId);
        if (s.underlying == address(0)) revert V2Errors.UnknownSeries();
    }

    /// @dev Spot of the series' underlying from the oracle the series pinned, USDG base units per share. The oracle
    ///      reverts when the price is stale or the token's oracle is paused; a zero answer reverts NoSource.
    function _spot(V2Types.Series memory s) private view returns (uint256 spot) {
        (spot,) = ISettlementOracle(s.oracle).spot(s.underlying);
        if (spot == 0) revert V2Errors.NoSource();
    }

    /// @dev The seller fee the book would take out of the vault's proceeds, bps of premium: `premiumFeeBps` when
    ///      the fill mints (`primary`), `resaleFeeBps` otherwise (`OrderBook._plan`). READ FROM THE BOOK, never a
    ///      compiled copy, and {IOrderBook.feeParams} already resolves a scheduled change, so the floor moves with
    ///      the fee instead of being quietly crossed by it.
    function _sellerFeeBps(bool primary) private view returns (uint256) {
        V2Types.FeeParams memory f = orderBook.feeParams();
        return primary ? f.premiumFeeBps : f.resaleFeeBps;
    }

    /// @dev ceil(base x BPS / (BPS - sellerFeeBps)) with base = max(0, intrinsic - spot x askToleranceBps / BPS),
    ///      USDG base units per share. Rounded UP, so the vault's proceeds NET of the seller fee are never below
    ///      `base`: the book charges floor(premium x sellerFeeBps / BPS), which only ever leaves more.
    ///      `BPS - sellerFeeBps` underflows and reverts at a fee of 100 % or more -- fail-closed, and unreachable
    ///      while the book keeps `premiumFeeBps` and `resaleFeeBps` under its own `PREMIUM_FEE_CEIL_BPS` (10 %).
    function _askFloor(V2Types.Series memory s, uint256 spot, uint256 sellerFeeBps) private view returns (uint256) {
        uint256 strike = s.strike;
        uint256 intrinsic;
        if (s.isPut) {
            if (strike > spot) intrinsic = strike - spot;
        } else if (spot > strike) {
            intrinsic = spot - strike;
        }
        uint256 tolerance = spot * _limits.askToleranceBps / V2Constants.BPS;
        uint256 base = intrinsic > tolerance ? intrinsic - tolerance : 0;
        if (base == 0) return 0;
        return Math.ceilDiv(base * V2Constants.BPS, V2Constants.BPS - sellerFeeBps);
    }

    /// @dev BadPrice when a buying price is above the bid cap or a selling price below the ask floor of its kind.
    /// @param primary Whether a sale at this price would MINT (AskWrite, or a `writeToSell` take). Ignored when
    ///        `buying`, because a purchase pays no seller fee.
    function _checkPrice(V2Types.Series memory s, bool buying, bool primary, uint256 price) private view {
        uint256 spot = _spot(s);
        if (buying) {
            if (price > spot * _limits.maxBidBpsOfSpot / V2Constants.BPS) revert V2Errors.BadPrice();
        } else if (price < _askFloor(s, spot, _sellerFeeBps(primary))) {
            revert V2Errors.BadPrice();
        }
    }

    /// @dev Applies maxOrderLifetime to a placement's validUntil (see {place}). The series limit is the mint cutoff
    ///      for AskWrite and the expiry otherwise, as the book resolves a zero validUntil.
    function _boundLifetime(V2Types.Series memory s, V2Types.OrderKind kind, uint40 validUntil)
        private
        view
        returns (uint40)
    {
        uint256 life = _limits.maxOrderLifetime;
        if (life == 0) return validUntil;
        uint256 latest = block.timestamp + life;
        if (validUntil == 0) {
            uint256 limit = kind == V2Types.OrderKind.AskWrite ? s.expiry - V2Constants.SETTLEMENT_WINDOW : s.expiry;
            // casting to 'uint40' is safe because latest < limit, which is a uint40
            // forge-lint: disable-next-line(unsafe-typecast)
            return latest < limit ? uint40(latest) : 0;
        }
        if (validUntil > latest) revert V2Errors.PastCutoff();
        return validUntil;
    }

    /// @dev Reads the vault's holdings and open orders on `longId`. `dead[i]` flags ids[i] as cancelled, filled, or an
    ///      expired Bid or AskWrite (never live again; an expired Bid's USDG escrow is not exposure). An expired
    ///      AskResale is not dead until a cancel or prune returns its longs: it can no longer fill, but the book still
    ///      holds them for the vault, so they count as resale escrow and the id is kept (sweep contracts-c15).
    function _scan(uint256 longId) private view returns (Exposure memory e, uint256[] memory ids, bool[] memory dead) {
        ids = _orderIds[longId];
        dead = new bool[](ids.length);
        if (ids.length != 0) {
            V2Types.Order[] memory orders = orderBook.getOrders(ids);
            for (uint256 i; i < ids.length; ++i) {
                V2Types.Order memory o = orders[i];
                uint256 left = o.units - o.filled;
                if (
                    o.cancelled || left == 0
                        || (block.timestamp >= o.validUntil && o.kind != V2Types.OrderKind.AskResale)
                ) {
                    dead[i] = true;
                    continue;
                }
                ++e.live;
                if (o.kind == V2Types.OrderKind.Bid) e.bids += left;
                else if (o.kind == V2Types.OrderKind.AskResale) e.resale += left;
                else e.writes += left;
            }
        }
        e.longs = clearinghouse.balanceOf(address(this), longId);
        e.shorts = clearinghouse.balanceOf(address(this), V2Ids.shortIdOf(longId));
    }

    /// @dev {_scan}, then drops the dead ids from storage (swap-and-pop from the back, so every index still to be
    ///      visited holds its original id).
    function _measure(uint256 longId) private returns (Exposure memory e) {
        uint256[] memory ids;
        bool[] memory dead;
        (e, ids, dead) = _scan(longId);
        uint256[] storage stored = _orderIds[longId];
        for (uint256 i = ids.length; i > 0;) {
            --i;
            if (!dead[i]) continue;
            uint256 last = stored.length - 1;
            if (i != last) stored[i] = stored[last];
            stored.pop();
        }
    }

    /// @dev Worst-case net position of `e` in units (contract NatSpec, SIZE GUARDS).
    function _units(Exposure memory e) private pure returns (uint256) {
        uint256 longSide = e.longs + e.resale + e.bids;
        uint256 up = longSide > e.shorts ? longSide - e.shorts : 0;
        uint256 shortSide = e.shorts + e.writes;
        uint256 down = shortSide > e.longs ? shortSide - e.longs : 0;
        return up > down ? up : down;
    }

    /// @dev Size guards of a guarded action on `longId`, then stores the measured value. Growth past a cap reverts
    ///      CeilingExceeded; anything that does not grow the series' exposure passes.
    function _enforce(uint256 longId, uint256 strike, uint256 beforeUnits, uint256 afterUnits) private {
        uint256 notional = afterUnits * strike / V2Constants.UNITS_PER_SHARE;
        uint256 total = totalNotional - seriesNotional[longId] + notional;
        if (afterUnits > beforeUnits) {
            Limits memory l = _limits;
            if (afterUnits > l.maxSeriesUnits || total > l.maxTotalNotional) revert V2Errors.CeilingExceeded();
        }
        _record(longId, afterUnits, notional, total);
    }

    /// @dev Measures `longId` and stores it, unchecked (cancel, close, sync, withdrawPosition). An unknown series
    ///      measures and stores zero.
    function _refresh(uint256 longId) private {
        uint256 units = _units(_measure(longId));
        uint256 notional = units * clearinghouse.series(longId).strike / V2Constants.UNITS_PER_SHARE;
        _record(longId, units, notional, totalNotional - seriesNotional[longId] + notional);
    }

    /// @dev Stores a series' notional and the new total, keeps {trackedSeries} in step, and logs a change.
    function _record(uint256 longId, uint256 units, uint256 notional, uint256 total) private {
        uint256 previous = seriesNotional[longId];
        if (previous == notional) return;
        seriesNotional[longId] = notional;
        totalNotional = total;
        if (previous == 0) {
            _tracked.push(longId);
            _trackedPos[longId] = _tracked.length;
        } else if (notional == 0) {
            uint256 pos = _trackedPos[longId];
            uint256 lastId = _tracked[_tracked.length - 1];
            _tracked[pos - 1] = lastId;
            _trackedPos[lastId] = pos;
            _tracked.pop();
            delete _trackedPos[longId];
        }
        emit ExposureSet(longId, units, notional, total);
    }
}
