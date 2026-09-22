// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Managed} from "./access/Managed.sol";
import {IClearinghouse} from "./interfaces/IClearinghouse.sol";
import {IFeeDiscount} from "./interfaces/IFeeDiscount.sol";
import {IFundingSource} from "./interfaces/IFundingSource.sol";
import {IMakerRegistry} from "./interfaces/IMakerRegistry.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {V2Constants} from "./interfaces/V2Constants.sol";
import {V2Errors} from "./interfaces/V2Errors.sol";
import {V2Ids} from "./interfaces/V2Ids.sol";
import {V2Types} from "./interfaces/V2Types.sol";
import {OptionMath} from "./lib/OptionMath.sol";

/// @title OrderBook
/// @notice On-chain order board for Clearinghouse longs (ADR-03, ADR-08, architecture §3.6): bids that escrow USDG,
///         resale asks that escrow long tokens, and write-on-fill asks that mint from the maker's free collateral when
///         they are hit. Takers name the order ids they hit; there is no on-chain sorting and no matchOrders, so every
///         execution goes through {take} and pays the taker fee.
/// @dev UNITS (ADR-04). Prices are USDG base units (6 dp) per whole share on the PRICE_TICK (100) grid, so
///      premium = price * units / 100 is exact. Units are 0.01-share units (ERC-1155 amounts). Fees and rebates are
///      USDG base units; rates are bps of BPS = 10_000.
///
///      LIVENESS. An order trades while it is not cancelled, has unfilled units and `now < validUntil`. validUntil is
///      resolved at placement and is never beyond the series' mint cutoff (AskWrite) or expiry (Bid, AskResale), so
///      "trading stops at expiry" and "no write after the cutoff" both reduce to that one comparison, and so does
///      {prune}: a settled series is past its expiry, hence past every validUntil on it.
///
///      TAKE = PLAN, THEN EXECUTE. 02-interfaces §1.8 fixes the log order of a take: per filled order its delivery logs
///      then its OrderFilled, USDG transfers after the loop, Taken last. OrderFilled carries the maker's rebate, and a
///      rebate is a pro-rata share of the call's taker fee, which depends on the premium of the WHOLE take. So the book
///      first plans the take with views ({_plan}: the same skip rules, and a per-account budget of free collateral or
///      long inventory so two write-on-fill asks of one maker cannot both count the same collateral), prices the taker
///      fee on the planned premium, and then executes the plan in order, emitting each OrderFilled right after its
///      delivery. {quoteTake} is exactly the first plan.
///      Two things no view can predict make an execution fail: a receiver that rejects ERC-1155 tokens (a bid maker, or
///      the short leg's writer) and anything else inside a mint the Clearinghouse refuses. Such a fill is skipped (its
///      state change undone, nothing emitted). Its units were reserved out of the wanted size and later fills were sized
///      around it, so the round stops there and the book plans again from the next id for the units still missing. The
///      take therefore fills exactly as if the refusing order had not been named: a bid that refuses tokens at the top
///      of the book costs the taker gas, instead of short-filling (or, with minUnits, reverting) every sale that names
///      it. That gas is bounded: every delivery the book catches runs with DELIVERY_GAS, receiver hooks included, so a
///      hook that burns whatever it is given costs at most that per order named, and one that needs more is refused.
///      Each id is tried at most once per take, so an order never fills twice in one call and a refusing order is
///      not retried; rounds follow the caller's order, so the §1.8 log order holds across them.
///      FEE SHARES. A round's fills share the fee on (premium already filled + the round's planned premium), less the
///      shares already handed to executed fills, pro rata by premium, the last planned fill absorbing the flooring dust.
///      On the normal path there is one round, so the shares add up to the taker fee exactly. After a skip they are
///      only guaranteed not to exceed the fee on what actually filled, so each rebate is clamped to that bound as it is
///      emitted: Σ rebates <= taker fee always holds.
///
///      ESCROW AND SETTLEMENT. The constructor opts the book out of third-party redemption, so nobody can redeem the
///      escrowed longs from under their makers; {prune} (anyone) and {cancel} hand them back after expiry, and the
///      makers are then redeemed like any other holder. The book accepts ERC-1155 tokens only from its Clearinghouse,
///      only as the escrow transfer it is itself making inside {place} / {replace}.
///
///      PAYMENTS NEVER BLOCK. Every USDG payment out of the book except {claimOwed} is best effort: a transfer that
///      reverts or returns false (USDG paused, recipient frozen) credits {owed} instead, with no log of its own
///      (§1.8). So a frozen maker cannot make a take, a cancel or a prune revert.
///
///      TRUST (ADR-09, INTERFACE_VERSION 8). One `AccessManager` gates every privileged call
///      ({Managed}, `script/v2/roles.v8.json`): FEE_MANAGER schedules fee parameters under the V2Constants ceilings,
///      which take effect FEE_CHANGE_DELAY (48 h) after they are scheduled ({setFeeParams}), and sets the optional
///      IMakerRegistry and the optional IFeeDiscount module; TREASURY_ADMIN sets the fee recipient; GUARDIAN alone
///      pauses {place}, {placeFor}, {replace} and {take}.
///      Nothing pauses {cancel}, {prune} or {claimOwed}, and no role can move an order's escrow anywhere but back to its
///      maker.
contract OrderBook is IOrderBook, IERC1155Receiver, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev V2Types.Order packed into three slots (the frozen struct's field order takes four). Same units.
    struct StoredOrder {
        address maker;
        V2Types.OrderKind kind;
        bool cancelled;
        uint64 units; // original size, 0.01-share units
        uint256 longId;
        uint128 price; // USDG 6 dp per whole share
        uint64 filled; // 0.01-share units
        uint40 validUntil; // unix seconds, exclusive
    }

    /// @dev One planned fill of {take} / {quoteTake}.
    struct Fill {
        uint256 index; // position of the order id in p.orderIds
        uint256 orderId;
        address maker;
        V2Types.OrderKind kind;
        bool primary; // units are minted in this fill (AskWrite hit, or writeToSell)
        uint64 units; // 0.01-share units
        uint128 price; // USDG 6 dp per whole share
        uint256 premium; // USDG base units
        uint256 sellerFee; // USDG base units
    }

    /// @dev What an account can still deliver inside one plan: free collateral (asset base units) for a mint, or long
    ///      tokens (units) for a sale from inventory. `usable` is the operator / ERC-1155 approval of the book.
    ///      `funded` is the fundable term added for a dry plan (0 on a real plan and on inventory budgets).
    struct Budget {
        address account;
        bool usable;
        uint256 left;
        uint256 funded;
    }

    /// @dev One planning round of a take. Arrays are sized to the order-id list; `count` / `budgetCount` are the used
    ///      parts.
    struct Plan {
        Fill[] fills;
        uint256 count;
        uint64 units; // 0.01-share units
        uint256 premium; // USDG base units
        uint256 takerFee; // USDG base units, on `premium`
        uint256 sellerFees; // USDG base units, the round's fills' seller-fee sum (the taker's own when selling)
        uint256 next; // index into p.orderIds of the first id this round did not consider
        Budget[] budgets;
        uint256 budgetCount;
        uint256 fundedCount; // INTERFACE_VERSION 8: fundable reads made this plan, including answers of 0
        bool mintLoaded; // the six mint fields below were read
        bool mintOpen; // market enabled, not mint-paused, the book a minter, before the cutoff
        address collateralAsset;
        uint256 collateralPerUnit; // collateral-asset base units
        uint32 mintFeePpm; // v7: the series' pinned collateral-rent rate
        uint40 expiry; // v7: the series' expiry, unix seconds, for the rent's remaining life
    }

    /// @dev Running totals of a take across its rounds. `payees` / `amounts` aggregate USDG owed to makers in first-fill
    ///      order; `tried` holds every order id already delivered or skipped at execution.
    struct Exec {
        uint64 units; // 0.01-share units delivered
        uint256 premium; // USDG base units filled
        uint256 sellerFees; // USDG base units
        uint256 shares; // taker-fee shares (USDG base units) handed to fills that executed
        uint256 rebates; // USDG base units emitted as rebates
        uint256 discountBps; // INTERFACE_VERSION 8: the take's discount, read once and carried (clamped, <= MAX_DISCOUNT_BPS)
        uint256[] tried;
        uint256 triedCount;
        address[] payees;
        uint256[] amounts;
        uint256 payeeCount;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Gas forwarded to each delivery the book catches: the mints and sales from inventory of {_deliver} and the
    ///      resale refunds of {prune}, the receivers' acceptance hooks included. Uncapped, a hook that burns all the gas
    ///      it is given took 63/64 of the call's gas at each such order, so two of them ran any take or prune batch out
    ///      of gas (sweep contracts-c06); capped, each costs the caller at most this. A fill that mints a series' first
    ///      supply to fresh balances uses about 160k of it, which leaves the two hooks of a mint over 300k between them.
    ///      A delivery that needs more is skipped like a refusal.
    uint256 private constant DELIVERY_GAS = 500_000;

    /// @dev Gas forwarded to the maker registry's rebateBps read ({_rebateBps}), once per executed fill. MakerRegistry
    ///      answers from one mapping slot; a registry that needs more reads as the book default (sweep contracts-c08).
    uint256 private constant REBATE_READ_GAS = 30_000;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The Clearinghouse whose longs this book trades. Exposed as {clearinghouse} (the interface returns address).
    IClearinghouse private immutable _ch;

    /// @notice USDG (6 dp): bid escrow, premiums, fees, rebates. The Clearinghouse's `usdg()` at deployment.
    IERC20 public immutable usdg;

    /// @notice Id of the most recently placed order. Ids start at 1; 0 is never an order.
    uint256 public lastOrderId;

    /// @inheritdoc IOrderBook
    mapping(address account => uint256) public owed;

    /// @notice Whether `delegate` may place, replace and cancel `maker`'s AskWrite orders.
    mapping(address maker => mapping(address delegate => bool)) public isDelegate;

    /// @notice Optional per-maker rebate tiers; address(0) = every maker gets FeeParams.makerRebateBps.
    IMakerRegistry public makerRegistry;

    /// @notice Receives the protocol's share of every take: seller fees plus taker fee minus rebates, USDG.
    address public feeRecipient;

    /// @notice GUARDIAN switch over {place}, {placeFor}, {replace} and {take}.
    bool public tradingPaused;

    /// @dev When `_pendingFees` take effect (unix seconds); 0 = nothing was ever scheduled. Packed with
    ///      {tradingPaused}, which every take reads first anyway.
    uint40 private _pendingFeesAt;

    /// @dev The fees in effect until `_pendingFees` are due. Read through {_effectiveFees} only.
    V2Types.FeeParams private _fees;
    /// @dev The most recently scheduled fees. Once block.timestamp >= `_pendingFeesAt` they are the fees in effect;
    ///      {setFeeParams} copies them into `_fees` before it schedules the next change.
    V2Types.FeeParams private _pendingFees;
    mapping(uint256 orderId => StoredOrder) private _orders;
    /// @dev Append-only; pages may contain dead orders (callers filter with {getOrders}).
    mapping(uint256 longId => uint256[]) private _seriesOrderIds;
    /// @dev Append-only, as above.
    mapping(address maker => uint256[]) private _makerOrderIds;

    /// @inheritdoc IOrderBook
    /// @dev INTERFACE_VERSION 8. Stored as `address`, not `IFeeDiscount`, so the generated getter is exactly the
    ///      frozen `discountModule() returns (address)`. address(0) at launch: the whole seam is then one check.
    address public discountModule;

    /// @dev INTERFACE_VERSION 8. `allowed` is CONFIG_ADMIN's half of the opt-in, `on` is the maker's own. Both must
    ///      be true before the pre-fund stage ever calls a maker. Packed: one SLOAD per named order.
    struct Funding {
        bool allowed;
        bool on;
    }

    /// @dev Read through {fundingOf}.
    mapping(address maker => Funding) private _funding;

    /// @dev keccak256(abi.encode(from, id, value)) of the escrow transfer the book is making right now; 0 otherwise.
    ///      {onERC1155Received} accepts exactly that transfer, once.
    bytes32 private transient _escrowExpected;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice TREASURY_ADMIN set the fee recipient.
    event FeeRecipientSet(address indexed recipient);
    /// @notice FEE_MANAGER set (or cleared, address(0)) the maker registry.
    event MakerRegistrySet(address indexed registry);
    /// @notice `account` withdrew `amount` USDG base units of {owed}.
    event OwedClaimed(address indexed account, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param clearinghouse_ The Clearinghouse whose longs are traded. Its `usdg()` becomes {usdg}.
    /// @param authority_ The `AccessManager` that gates this contract's restricted functions ({Managed}; a code-less
    ///        authority reverts NoSource).
    /// @param feeRecipient_ Receives protocol fees (NotAuthorized when zero or the book itself).
    /// @param fees Initial fee parameters, under the V2Constants ceilings (CeilingExceeded). In effect at once, with no
    ///        delay; logged as FeeParamsSet.
    constructor(IClearinghouse clearinghouse_, address authority_, address feeRecipient_, V2Types.FeeParams memory fees)
        Managed(authority_)
    {
        address usdg_ = clearinghouse_.usdg();
        // The best-effort payout treats empty return data as success, which a code-less token would always give.
        if (usdg_.code.length == 0) revert V2Errors.UnsupportedAsset();
        _ch = clearinghouse_;
        usdg = IERC20(usdg_);
        _setFeeRecipient(feeRecipient_);
        _checkFeeCeilings(fees);
        _fees = fees;
        emit FeeParamsSet(fees);
        // Escrowed longs belong to their makers: nobody but the book may redeem them (architecture §3.5 / §3.6).
        clearinghouse_.setThirdPartyRedeem(false);
    }

    /*//////////////////////////////////////////////////////////////
                                 PLACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderBook
    /// @dev Also reverts DeadlinePassed for a non-zero validUntil <= now, and PastCutoff for one beyond the series limit.
    ///      Bid escrow is pulled with a balance-delta check (UnsupportedAsset when less arrives). Logs: the escrow
    ///      transfer (USDG Transfer or ERC-1155 TransferSingle maker -> book), then OrderPlaced.
    function place(uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units, uint40 validUntil)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        _whenTrading();
        return _place(msg.sender, longId, kind, price, units, validUntil);
    }

    /// @inheritdoc IOrderBook
    function placeFor(
        address maker,
        uint256 longId,
        V2Types.OrderKind kind,
        uint128 price,
        uint64 units,
        uint40 validUntil
    ) external nonReentrant returns (uint256 orderId) {
        _whenTrading();
        _authorize(maker, kind);
        return _place(maker, longId, kind, price, units, validUntil);
    }

    /// @inheritdoc IOrderBook
    function setDelegate(address delegate, bool approved) external nonReentrant {
        isDelegate[msg.sender][delegate] = approved;
        emit DelegateSet(msg.sender, delegate, approved);
    }

    /// @inheritdoc IOrderBook
    /// @dev Unknown ids revert OrderNotLive. Orders already cancelled or fully filled are skipped (nothing to refund),
    ///      so a cancel list that races a fill does not revert. Expired orders with units left are cancelled and
    ///      refunded like live ones. A USDG refund that cannot be transferred is credited to {owed}; an ERC-1155 refund
    ///      the maker's address rejects reverts (the maker's own call; {prune} skips such an order instead).
    function cancel(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 id = orderIds[i];
            StoredOrder storage o = _orders[id];
            if (o.maker == address(0)) revert V2Errors.OrderNotLive(id);
            _authorize(o.maker, o.kind);
            uint64 remaining = o.units - o.filled;
            if (o.cancelled || remaining == 0) continue;
            o.cancelled = true;
            if (o.kind == V2Types.OrderKind.Bid) {
                _payOrOwe(o.maker, OptionMath.premium(o.price, remaining));
            } else if (o.kind == V2Types.OrderKind.AskResale) {
                _ch.safeTransferFrom(address(this), o.maker, o.longId, remaining, "");
            }
            emit OrderCancelled(id, remaining, false);
        }
    }

    /// @inheritdoc IOrderBook
    /// @dev The replacement keeps the old order's maker, series, kind and resolved validUntil. Escrow: an AskResale is
    ///      fully refunded and re-escrowed, so its logs are TransferSingle(book -> maker), OrderCancelled,
    ///      TransferSingle(maker -> book), OrderPlaced, exactly a cancel followed by a place; a Bid moves only the USDG
    ///      difference (pulled before OrderCancelled, or paid back after OrderPlaced); an AskWrite moves nothing.
    function replace(uint256 orderId, uint128 newPrice, uint64 newUnits)
        external
        nonReentrant
        returns (uint256 newOrderId)
    {
        _whenTrading();
        StoredOrder storage o = _orders[orderId];
        if (o.maker == address(0)) revert V2Errors.OrderNotLive(orderId);
        _authorize(o.maker, o.kind);
        uint64 remaining = o.units - o.filled;
        if (o.cancelled || remaining == 0 || block.timestamp >= o.validUntil) revert V2Errors.OrderNotLive(orderId);
        _checkPriceAndUnits(newPrice, newUnits);

        address maker = o.maker;
        uint256 longId = o.longId;
        V2Types.OrderKind kind = o.kind;
        uint128 oldPrice = o.price;
        uint40 validUntil = o.validUntil;
        o.cancelled = true;
        newOrderId = _store(maker, longId, kind, newPrice, newUnits, validUntil);

        if (kind == V2Types.OrderKind.Bid) {
            uint256 oldEscrow = OptionMath.premium(oldPrice, remaining);
            uint256 newEscrow = OptionMath.premium(newPrice, newUnits);
            if (newEscrow > oldEscrow) _pullUsdg(maker, newEscrow - oldEscrow);
            emit OrderCancelled(orderId, remaining, false);
            emit OrderPlaced(newOrderId, maker, longId, kind, newPrice, newUnits, validUntil);
            if (oldEscrow > newEscrow) _payOrOwe(maker, oldEscrow - newEscrow);
        } else {
            if (kind == V2Types.OrderKind.AskResale) {
                _ch.safeTransferFrom(address(this), maker, longId, remaining, "");
            }
            emit OrderCancelled(orderId, remaining, false);
            if (kind == V2Types.OrderKind.AskResale) _escrowLongs(maker, longId, newUnits);
            emit OrderPlaced(newOrderId, maker, longId, kind, newPrice, newUnits, validUntil);
        }
    }

    /// @inheritdoc IOrderBook
    /// @dev Prunable = not cancelled, units left, and now >= validUntil (which covers expired series, AskWrite past its
    ///      cutoff and settled series; see LIVENESS). Unknown, cancelled, filled and live ids are skipped. A resale
    ///      refund the maker's address rejects, or that does not complete within DELIVERY_GAS, leaves that order as it
    ///      was (skipped, not counted, no log) so one maker cannot block a keeper's batch; the maker can {cancel} it
    ///      later.
    function prune(uint256[] calldata orderIds) external nonReentrant returns (uint256 pruned) {
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 id = orderIds[i];
            StoredOrder storage o = _orders[id];
            if (o.maker == address(0) || o.cancelled || block.timestamp < o.validUntil) continue;
            uint64 remaining = o.units - o.filled;
            if (remaining == 0) continue;
            o.cancelled = true;
            if (o.kind == V2Types.OrderKind.AskResale) {
                try _ch.safeTransferFrom{gas: DELIVERY_GAS}(address(this), o.maker, o.longId, remaining, "") {}
                catch {
                    o.cancelled = false;
                    continue;
                }
            } else if (o.kind == V2Types.OrderKind.Bid) {
                _payOrOwe(o.maker, OptionMath.premium(o.price, remaining));
            }
            emit OrderCancelled(id, remaining, true);
            ++pruned;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  TAKE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderBook
    /// @dev Also reverts BadUnits for p.units == 0 and NotAuthorized when p.recipient is address(0) or the book (no
    ///      default: OrderFilled.recipient is always exactly p.recipient). p.writeToSell is ignored when buying.
    ///      Skips, besides those in the interface: an id named again, a write-on-fill mint the delivering account
    ///      cannot fully collateralise -- COLLATERAL PLUS THE CLEARINGHOUSE'S MINT RENT since INTERFACE_VERSION 7
    ///      ({_reserveCollateral}) -- or has not approved the book to make (or that the market cannot mint now: the
    ///      market off, the mint paused, the cutoff past, or the book off the minter allow-list since
    ///      INTERFACE_VERSION 8), a
    ///      sale from inventory the taker cannot fully deliver or has not approved, and any delivery that reverts or
    ///      runs out of its DELIVERY_GAS except the book's own AskResale transfer to the recipient (uncapped; a
    ///      recipient that rejects ERC-1155 tokens makes the take revert). A fill skipped at execution frees its units
    ///      for the ids after it (contract NatSpec, TAKE). Seller fee = premium * premiumFeeBps / BPS for primary fills,
    ///      resaleFeeBps otherwise: 500 bps on the FIRST SALE ONLY and 0 on a true resale at v8 launch, deliberate
    ///      so market makers and early exits are not taxed. It is NOT avoidable by minting outside the book: in v8
    ///      {Clearinghouse.mint} reverts NotMinter off the allow-list and the book is the only launch minter; the one
    ///      route is the owner-accepted self-trade (docs/AUDIT-SCOPE.md §7). Fee parameters and ceilings did not move
    ///      in v7; INTERFACE_VERSION 8 raised the change delay to 48 h and adds the taker-side `maxTotalFee` cap and
    ///      the discount seam. Rebate = the order's share of the taker fee (pro rata by premium) * rebateBps(maker)
    ///      / BPS. Logs (§1.8): per filled order its delivery logs then OrderFilled, in the caller's order; then USDG
    ///      transfers (the pull from a buying taker, or the taker's proceeds; maker payments in first-fill order; the
    ///      fee recipient); Taken last.
    function take(V2Types.TakeParams calldata p)
        external
        nonReentrant
        returns (uint64 unitsFilled, uint256 premium, uint256 takerFee)
    {
        _checkTake(p);
        V2Types.FeeParams memory fees = _effectiveFees();
        uint256 n = p.orderIds.length;
        Exec memory ex;
        ex.tried = new uint256[](n);
        ex.payees = new address[](n);
        ex.amounts = new uint256[](n);
        // INTERFACE_VERSION 8: the discount module is read ONCE for the whole take and carried on the exec state, so
        // all four {_takerFee} evaluations see the same figure and the rebate maths cannot underflow.
        ex.discountBps = _discountBps(msg.sender);

        // INTERFACE_VERSION 8: pre-fund once, before round one, only when a named maker has funding on. The dry
        // plan is discarded; every real round plans on real balances.
        _preFund(p, fees, ex);

        // Round one always runs; another runs only when the previous one stopped at a fill skipped at execution and
        // both units and ids remain. `from` strictly increases with every round that plans a fill, so this terminates.
        bool again = true;
        uint256 from;
        while (again && from < n && ex.units < p.units) {
            Plan memory plan = _plan(p, msg.sender, fees, from, p.units - ex.units, ex, false);
            (again, from) = _execute(p, fees, plan, ex);
        }
        if (ex.units < p.minUnits) revert V2Errors.BelowMinUnits(ex.units, p.minUnits);

        takerFee = _takerFee(ex.premium, fees, ex.discountBps);
        {
            // The hard cap, checked after the final taker-side fees are known and before any USDG moves
            // (03-INTERFACES §2.2): the taker fee when buying, plus the taker's own seller fees when selling into bids.
            uint256 totalFee = takerFee + (p.buying ? 0 : ex.sellerFees);
            if (totalFee > p.maxTotalFee) revert V2Errors.FeeAboveMax(totalFee, p.maxTotalFee);
        }
        if (p.buying) {
            _pullUsdg(msg.sender, ex.premium + takerFee);
        } else {
            // Cannot underflow: seller fees and the taker fee are each <= 10 % of the premium (compiled ceilings).
            _payOrOwe(p.recipient, ex.premium - ex.sellerFees - takerFee);
        }
        for (uint256 i; i < ex.payeeCount; ++i) {
            _payOrOwe(ex.payees[i], ex.amounts[i]);
        }
        _payOrOwe(feeRecipient, ex.sellerFees + takerFee - ex.rebates);
        emit Taken(msg.sender, p.longId, p.buying, ex.units, ex.premium, takerFee);
        return (ex.units, ex.premium, takerFee);
    }

    /// @inheritdoc IOrderBook
    /// @dev The taker is msg.sender (set `from` on eth_call). Reverts exactly where {take} would before executing:
    ///      TradingPaused, DeadlinePassed, BadUnits, NotAuthorized (recipient zero or the book), BelowMinUnits.
    ///      INTERFACE_VERSION 8 appended `sellerFees`, the sum the taker pays AS A SELLER (0 when buying: an ask hit's
    ///      seller fee is the maker's), so a selling taker can set `TakeParams.maxTotalFee` exactly. The taker fee is
    ///      discounted by the same single read of the module a {take} would make.
    ///
    ///      ON A FUNDED MAKER THIS IS AN UPPER BOUND, NOT AN EQUALITY. It plans with `assumeFunding = true`, so a
    ///      maker with funding on is budgeted its source's `fundable` ANSWER. {take} pre-funds first and then plans
    ///      its executing round with `assumeFunding = false`, on the collateral the source actually DELIVERED -- and
    ///      `_preFund` saturates that delivery at 0 and never reverts on a short one. A source that answers more than
    ///      it delivers therefore quotes units {take} will not fill. Every unfunded maker, which is every maker at
    ///      launch because none is `allowed`, quotes exactly.
    function quoteTake(V2Types.TakeParams calldata p)
        external
        view
        returns (uint64 unitsFilled, uint256 premium, uint256 takerFee, uint256 sellerFees)
    {
        _checkTake(p);
        Exec memory nothingTried;
        // The quote discounts the taker fee by the same single read of the module a {take} would make.
        nothingTried.discountBps = _discountBps(msg.sender);
        Plan memory plan = _plan(p, msg.sender, _effectiveFees(), 0, p.units, nothingTried, true);
        if (plan.units < p.minUnits) revert V2Errors.BelowMinUnits(plan.units, p.minUnits);
        return (plan.units, plan.premium, plan.takerFee, p.buying ? 0 : plan.sellerFees);
    }

    /// @inheritdoc IOrderBook
    /// @dev A zero balance is a no-op. Reverts if the transfer fails (the claimant's own call).
    function claimOwed() external nonReentrant {
        uint256 amount = owed[msg.sender];
        if (amount == 0) return;
        owed[msg.sender] = 0;
        emit OwedClaimed(msg.sender, amount);
        usdg.safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderBook
    function clearinghouse() external view returns (address) {
        return address(_ch);
    }

    /// @inheritdoc IOrderBook
    /// @dev The fees {take} and {quoteTake} price with in this block.
    function feeParams() external view returns (V2Types.FeeParams memory) {
        return _effectiveFees();
    }

    /// @inheritdoc IOrderBook
    function pendingFeeParams() external view returns (V2Types.FeeParams memory params, uint40 effectiveAt) {
        uint40 at = _pendingFeesAt;
        if (block.timestamp < at) return (_pendingFees, at);
    }

    /// @inheritdoc IOrderBook
    function getOrders(uint256[] calldata orderIds) external view returns (V2Types.Order[] memory orders) {
        orders = new V2Types.Order[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            StoredOrder storage o = _orders[orderIds[i]];
            orders[i] = V2Types.Order({
                maker: o.maker,
                longId: o.longId,
                kind: o.kind,
                price: o.price,
                units: o.units,
                filled: o.filled,
                validUntil: o.validUntil,
                cancelled: o.cancelled
            });
        }
    }

    /// @inheritdoc IOrderBook
    /// @dev `cursor` is a position in the series' append-only id list. limit == 0 or cursor past the end returns an
    ///      empty page with nextCursor 0.
    function ordersOfSeries(uint256 longId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 nextCursor)
    {
        return _page(_seriesOrderIds[longId], cursor, limit);
    }

    /// @inheritdoc IOrderBook
    function ordersOfMaker(address maker, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 nextCursor)
    {
        return _page(_makerOrderIds[maker], cursor, limit);
    }

    /// @notice Number of orders ever placed on `longId` (live or not): the length {ordersOfSeries} pages over.
    function seriesOrderCount(uint256 longId) external view returns (uint256) {
        return _seriesOrderIds[longId].length;
    }

    /// @notice Number of orders ever placed for `maker` (live or not): the length {ordersOfMaker} pages over.
    function makerOrderCount(address maker) external view returns (uint256) {
        return _makerOrderIds[maker].length;
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Schedules new fee parameters, in effect FEE_CHANGE_DELAY from now (48 h from INTERFACE_VERSION 8).
    ///         FEE_MANAGER, itself a 48 h lane on the manager.
    /// @dev CeilingExceeded, checked now, when premiumFeeBps or resaleFeeBps > PREMIUM_FEE_CEIL_BPS, takerFeeFlat >
    ///      TAKER_FEE_FLAT_CEIL, takerFeeCapBps > TAKER_FEE_CAP_CEIL_BPS, or makerRebateBps > BPS (a rebate is a share
    ///      of the taker fee). Nothing changes for takes before effectiveAt = block.timestamp + FEE_CHANGE_DELAY; from
    ///      the first block with block.timestamp >= effectiveAt every take, resting orders included, pays `fees`
    ///      ({feeParams}), and until then {pendingFeeParams} shows them. Logs FeeParamsScheduled(fees, effectiveAt).
    ///      A previous change that is already due stays in effect (it becomes the fees in effect until this one is
    ///      due). A previous change that is not due yet is replaced, and the delay restarts from this call. So
    ///      scheduling the fees in effect now is how the admin cancels a pending change: nothing else cancels one.
    /// @param fees Bps, and USDG base units for takerFeeFlat.
    function setFeeParams(V2Types.FeeParams calldata fees) external nonReentrant restricted {
        _checkFeeCeilings(fees);
        uint40 at = _pendingFeesAt;
        if (at != 0 && block.timestamp >= at) _fees = _pendingFees;
        // casting to 'uint40' is safe: a unix time below 2^40 until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 effectiveAt = uint40(block.timestamp) + V2Constants.FEE_CHANGE_DELAY;
        _pendingFees = fees;
        _pendingFeesAt = effectiveAt;
        emit FeeParamsScheduled(fees, effectiveAt);
    }

    /// @notice Sets the fee recipient (NotAuthorized when zero or the book itself). TREASURY_ADMIN.
    /// @param recipient Receiver of protocol fees.
    function setFeeRecipient(address recipient) external nonReentrant restricted {
        _setFeeRecipient(recipient);
    }

    /// @notice Sets the maker registry; address(0) turns tiers off. FEE_MANAGER.
    /// @dev Read on every fill with a bounded-trust staticcall capped at 30,000 gas, of whose answer only the first 32
    ///      bytes are copied: a reverting read, one that runs out of that gas, or short return data means the book
    ///      default, 0 means the book default, and an answer above BPS is clamped to BPS. So the worst a registry can
    ///      do is redirect rebates, plus at most 30,000 gas per fill.
    /// @param registry IMakerRegistry or address(0).
    function setMakerRegistry(IMakerRegistry registry) external nonReentrant restricted {
        makerRegistry = registry;
        emit MakerRegistrySet(address(registry));
    }

    /// @notice Pauses or resumes {place}, {placeFor}, {replace} and {take}. GUARDIAN only since INTERFACE_VERSION 8
    ///         (v7 accepted the admin too).
    /// @param paused True to pause.
    function setTradingPaused(bool paused) external nonReentrant restricted {
        tradingPaused = paused;
        emit TradingPausedSet(paused);
    }

    /*//////////////////////////////////////////////////////////////
          SEAMS, INTERFACE_VERSION 8 (03-INTERFACES §2.2)
    //////////////////////////////////////////////////////////////*/

    // BOTH READ SIDES ARE PRESENT. The discount read side lives in {_discountBps} and is taken once per {take} /
    // {quoteTake}. The pre-fund read side landed with C8-13: {take} calls {_preFund} before round one;
    // {_preFund} builds a discarded dry plan (`_plan(..., assumeFunding = true)`) and acts on makers whose funding
    // is on; {_reserveCollateral}, not {_plan}, reads `_funding[writer].on` under MAX_FUNDED_MAKERS_PER_TAKE. Both
    // seams are still OFF AT LAUNCH -- no discount module is set and no maker has funding on -- so a v8 deployment
    // behaves identically either way until one exists: a statement about configuration, not about missing code.

    /// @inheritdoc IOrderBook
    function setDiscountModule(IFeeDiscount module) external nonReentrant restricted {
        discountModule = address(module);
        emit DiscountModuleSet(address(module));
    }

    /// @inheritdoc IOrderBook
    function setFundingAllowed(address maker, bool allowed) external nonReentrant restricted {
        _funding[maker].allowed = allowed;
        if (!allowed) _funding[maker].on = false; // revoking the permission also stops the calls
        emit FundingAllowedSet(maker, allowed);
    }

    /// @inheritdoc IOrderBook
    /// @dev Switching on staticcalls `IFundingSource(msg.sender).fundable(address(usdg))` capped at
    ///      `V2Constants.FUNDABLE_READ_GAS` and requires success AND `returndatasize() >= 32`. A codeless address
    ///      (an EOA) returns success with zero data, so the length check is what keeps it out. A source answering 0
    ///      is a valid answer. Switching off never probes: it is the safety valve.
    ///
    ///      THE PROBE ASKS ABOUT USDG AND THE RUNTIME DOES NOT. `_preFund` reads `fundable(plan.collateralAsset)`,
    ///      which is USDG only for a PUT; a CALL collateralises in the underlying. This opt-in therefore establishes
    ///      that the caller is a contract that answers the interface AT ALL, and nothing about the asset any series
    ///      will actually ask it for -- a source that answers only for USDG enables funding here and then contributes
    ///      0 to every call series. That is deliberate: the opt-in cannot know which series the maker will quote, and
    ///      `_fundable` fails closed to 0 at run time, so the mismatch costs a maker its pre-funding rather than
    ///      costing a taker a bad fill. It is documented rather than enforced so nobody reads this call as proof that
    ///      the seam works for a given market.
    function setFunding(bool on) external nonReentrant {
        if (!_funding[msg.sender].allowed) revert V2Errors.NotAuthorized();
        if (on && !_fundableAnswered(msg.sender, address(usdg))) revert V2Errors.NotAuthorized();
        _funding[msg.sender].on = on;
        emit FundingSet(msg.sender, on);
    }

    /// @inheritdoc IOrderBook
    function fundingOf(address maker) external view returns (bool allowed, bool on) {
        Funding storage f = _funding[maker];
        return (f.allowed, f.on);
    }

    /*//////////////////////////////////////////////////////////////
                             ERC-1155 RECEIVER
    //////////////////////////////////////////////////////////////*/

    /// @notice Accepts exactly the escrow transfer the book is making inside {place} / {replace}; reverts NotAuthorized
    ///         for every other transfer, so nobody can park tokens in the book.
    /// @dev Not nonReentrant: it runs inside the guarded {place}. Consumes the expectation, so it accepts once.
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata)
        external
        returns (bytes4)
    {
        bytes32 expected = _escrowExpected;
        if (
            msg.sender != address(_ch) || operator != address(this) || expected == bytes32(0)
                || keccak256(abi.encode(from, id, value)) != expected
        ) revert V2Errors.NotAuthorized();
        _escrowExpected = bytes32(0);
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @notice Batch transfers are never accepted (NotAuthorized): the book escrows one id at a time.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert V2Errors.NotAuthorized();
    }

    /// @inheritdoc IERC165
    /// @dev INTERFACE_VERSION 8: the manager holds the roles, so the book no longer reports IAccessControl
    ///      ({Managed}); what remains is the receiver id and ERC-165 itself.
    function supportsInterface(bytes4 interfaceId) public view override(IERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: ORDERS
    //////////////////////////////////////////////////////////////*/

    function _whenTrading() private view {
        if (tradingPaused) revert V2Errors.TradingPaused();
    }

    /// @dev The maker itself for any kind; a delegate of the maker for AskWrite only (NotAuthorized otherwise).
    function _authorize(address maker, V2Types.OrderKind kind) private view {
        if (msg.sender == maker) return;
        if (kind == V2Types.OrderKind.AskWrite && isDelegate[maker][msg.sender]) return;
        revert V2Errors.NotAuthorized();
    }

    /// @dev BadUnits for 0 units; BadPrice for 0 (checked on its own: 0 is on the tick grid) or an off-grid price.
    function _checkPriceAndUnits(uint128 price, uint64 units) private pure {
        if (units == 0) revert V2Errors.BadUnits();
        if (price == 0 || !OptionMath.isPriceTick(price)) revert V2Errors.BadPrice();
    }

    function _place(
        address maker,
        uint256 longId,
        V2Types.OrderKind kind,
        uint128 price,
        uint64 units,
        uint40 validUntil
    ) private returns (uint256 orderId) {
        _checkPriceAndUnits(price, units);
        if (V2Ids.isShortId(longId) || !_ch.seriesExists(longId)) revert V2Errors.UnknownSeries();
        // AskWrite trades until the mint cutoff (it mints); Bid and AskResale until expiry. The cutoff is defined as
        // expiry - SETTLEMENT_WINDOW (IClearinghouse.mintCutoff), so one small read gives both without copying the
        // whole Series struct out of the Clearinghouse.
        uint40 limit = _ch.mintCutoff(longId);
        if (kind != V2Types.OrderKind.AskWrite) limit += V2Constants.SETTLEMENT_WINDOW;
        if (block.timestamp >= limit) revert V2Errors.PastCutoff();
        if (validUntil == 0) {
            validUntil = limit;
        } else if (validUntil > limit) {
            revert V2Errors.PastCutoff();
        } else if (validUntil <= block.timestamp) {
            revert V2Errors.DeadlinePassed();
        }

        orderId = _store(maker, longId, kind, price, units, validUntil);
        if (kind == V2Types.OrderKind.Bid) {
            _pullUsdg(maker, OptionMath.premium(price, units));
        } else if (kind == V2Types.OrderKind.AskResale) {
            _escrowLongs(maker, longId, units);
        }
        emit OrderPlaced(orderId, maker, longId, kind, price, units, validUntil);
    }

    function _store(
        address maker,
        uint256 longId,
        V2Types.OrderKind kind,
        uint128 price,
        uint64 units,
        uint40 validUntil
    ) private returns (uint256 orderId) {
        orderId = ++lastOrderId;
        _orders[orderId] = StoredOrder({
            maker: maker,
            kind: kind,
            cancelled: false,
            units: units,
            longId: longId,
            price: price,
            filled: 0,
            validUntil: validUntil
        });
        _seriesOrderIds[longId].push(orderId);
        _makerOrderIds[maker].push(orderId);
    }

    /// @dev Pulls `units` longs from `maker` into escrow (ERC-1155 approval of the book). The callback verifies the
    ///      exact (from, id, value), which is the delivery proof for an ERC-1155 transfer.
    function _escrowLongs(address maker, uint256 longId, uint64 units) private {
        _escrowExpected = keccak256(abi.encode(maker, longId, uint256(units)));
        _ch.safeTransferFrom(maker, address(this), longId, units, "");
        if (_escrowExpected != bytes32(0)) revert V2Errors.NotAuthorized();
    }

    function _page(uint256[] storage ids, uint256 cursor, uint256 limit)
        private
        view
        returns (uint256[] memory page, uint256 nextCursor)
    {
        uint256 len = ids.length;
        if (cursor >= len || limit == 0) return (new uint256[](0), 0);
        uint256 end = len - cursor > limit ? cursor + limit : len;
        page = new uint256[](end - cursor);
        for (uint256 i = cursor; i < end; ++i) {
            page[i - cursor] = ids[i];
        }
        nextCursor = end < len ? end : 0;
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL: TAKE
    //////////////////////////////////////////////////////////////*/

    function _checkTake(V2Types.TakeParams calldata p) private view {
        _whenTrading();
        if (block.timestamp > p.deadline) revert V2Errors.DeadlinePassed();
        if (p.units == 0) revert V2Errors.BadUnits();
        if (p.recipient == address(0) || p.recipient == address(this)) revert V2Errors.NotAuthorized();
    }

    /// @dev min(takerFeeFlat, premium * takerFeeCapBps / BPS), less the take's discount, USDG base units.
    ///      `base - base * discount / BPS` is non-decreasing in `premium` for a fixed discount, which the rebate
    ///      maths rely on (the `room` clamp in {_execute} would underflow otherwise).
    function _takerFee(uint256 premium, V2Types.FeeParams memory fees, uint256 discountBps)
        private
        pure
        returns (uint256)
    {
        uint256 byCap = premium * fees.takerFeeCapBps / V2Constants.BPS;
        uint256 base = byCap < fees.takerFeeFlat ? byCap : fees.takerFeeFlat;
        return base - base * discountBps / V2Constants.BPS;
    }

    /// @dev The taker's discount for this take, bps of the taker fee: the module's answer clamped to
    ///      MAX_DISCOUNT_BPS, else 0. Read ONCE per {take} / {quoteTake} with the same bounded-trust staticcall
    ///      pattern as {_rebateBps}: DISCOUNT_READ_GAS capped, only the first word of the answer copied, so a revert,
    ///      an out-of-gas, a short or a dirty answer all read as 0 and a hostile module can neither break nor stall a
    ///      take. With no module set the whole path is the zero-address check.
    function _discountBps(address taker) private view returns (uint256) {
        address module = discountModule;
        if (module != address(0)) {
            bytes memory data = abi.encodeCall(IFeeDiscount.discountBps, (taker));
            uint256 gasCap = V2Constants.DISCOUNT_READ_GAS;
            bool ok;
            uint256 bps;
            assembly ("memory-safe") {
                ok := staticcall(gasCap, module, add(data, 0x20), mload(data), 0x00, 0x20)
                ok := and(ok, iszero(lt(returndatasize(), 0x20)))
                bps := mload(0x00)
            }
            if (ok) return bps > V2Constants.MAX_DISCOUNT_BPS ? V2Constants.MAX_DISCOUNT_BPS : bps;
        }
        return 0;
    }

    /// @dev Pre-fund stage: one dry plan that assumes funding, then one `fund` per budget with a positive need.
    ///      Need is the dry plan's consumed collateral-plus-rent minus current `free`, i.e. `funded - left`. A
    ///      `need == 0` budget is silent. `delivered` is the maker's `free` delta SATURATED AT 0, never the request:
    ///      a source that lowers its own `free` reports 0, it does not revert the take. The dry plan is discarded;
    ///      the caller re-plans on real balances.
    function _preFund(V2Types.TakeParams calldata p, V2Types.FeeParams memory fees, Exec memory ex) private {
        uint256 n = p.orderIds.length;
        bool any;
        for (uint256 i; i < n; ++i) {
            if (_funding[_orders[p.orderIds[i]].maker].on) {
                any = true;
                break;
            }
        }
        if (!any) return;

        Plan memory dry = _plan(p, msg.sender, fees, 0, p.units, ex, true);
        for (uint256 i; i < dry.budgetCount; ++i) {
            Budget memory b = dry.budgets[i];
            if (b.funded == 0 || b.funded <= b.left) continue;
            uint256 need = b.funded - b.left;
            address asset = dry.collateralAsset;
            uint256 before = _ch.free(b.account, asset);
            try IFundingSource(b.account).fund{gas: V2Constants.FUNDING_GAS}(asset, need) {
                // SATURATING, NOT `after_ - before`. A source can LOWER its own `free` inside `fund` -- the book's
                // guard is held for the whole take but does not cover the Clearinghouse, so `withdraw` is reachable
                // from the callback. A panic in the `try`'s SUCCESS clause is not caught by the `catch` below, so an
                // underflow here would revert the ENTIRE take, including the fills of makers that had nothing to do
                // with this source. Funding must never block a take (IFundingSource.sol:15-21); a net-negative
                // delivery is a delivery of 0, and the maker is then skipped by the real plan for want of `free`.
                uint256 after_ = _ch.free(b.account, asset);
                emit Funded(b.account, asset, need, after_ > before ? after_ - before : 0);
            } catch {
                emit FundingFailed(b.account, asset, need);
            }
        }
    }

    /// @dev Capped one-word staticcall of `IFundingSource.fundable`. Revert, OOG or short data => 0.
    ///      Gas cap is `V2Constants.FUNDABLE_READ_GAS` (read from the library, never retyped).
    function _fundable(address source, address asset) private view returns (uint256 amount) {
        bytes memory data = abi.encodeCall(IFundingSource.fundable, (asset));
        uint256 gasCap = V2Constants.FUNDABLE_READ_GAS;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gasCap, source, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            amount := mload(0x00)
        }
        if (!ok) return 0;
    }

    /// @dev Same capped staticcall as {_fundable}, but reports whether an answer arrived. Used by {setFunding}
    ///      so an EOA (success + zero return data) cannot enable funding, while a source answering 0 can.
    function _fundableAnswered(address source, address asset) private view returns (bool ok) {
        bytes memory data = abi.encodeCall(IFundingSource.fundable, (asset));
        uint256 gasCap = V2Constants.FUNDABLE_READ_GAS;
        assembly ("memory-safe") {
            ok := staticcall(gasCap, source, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
        }
    }

    /// @dev The fills a take by `taker` would make now for `want` units, over p.orderIds from index `from`, in the
    ///      caller's order, with every skip rule and a per-account delivery budget read fresh from the Clearinghouse.
    ///      Ids in `ex.tried` are skipped. View only: {take} executes it round by round, {quoteTake} returns the totals
    ///      of the first round.
    function _plan(
        V2Types.TakeParams calldata p,
        address taker,
        V2Types.FeeParams memory fees,
        uint256 from,
        uint64 want,
        Exec memory ex,
        bool assumeFunding
    ) private view returns (Plan memory plan) {
        uint256 n = p.orderIds.length;
        plan.fills = new Fill[](n);
        plan.budgets = new Budget[](n);
        uint256 i = from;
        for (; i < n && plan.units < want; ++i) {
            uint256 id = p.orderIds[i];
            StoredOrder storage o = _orders[id];
            if (o.maker == address(0) || o.cancelled || o.longId != p.longId || block.timestamp >= o.validUntil) {
                continue;
            }
            if (o.maker == taker || o.filled == o.units) continue;
            if (p.buying) {
                if (o.kind == V2Types.OrderKind.Bid || o.price > p.limitPrice) continue;
            } else if (o.kind != V2Types.OrderKind.Bid || o.price < p.limitPrice) {
                continue;
            }
            if (_seen(plan, ex, id)) continue;

            uint64 left = o.units - o.filled;
            uint64 missing = want - plan.units;
            uint64 units = left < missing ? left : missing;
            bool primary;
            if (p.buying) {
                primary = o.kind == V2Types.OrderKind.AskWrite;
                if (primary && !_reserveCollateral(plan, p.longId, o.maker, units, assumeFunding)) continue;
            } else if (p.writeToSell) {
                primary = true;
                if (!_reserveCollateral(plan, p.longId, taker, units, false)) continue;
            } else if (!_reserveInventory(plan, p.longId, taker, units)) {
                continue;
            }

            uint256 premium = OptionMath.premium(o.price, units);
            uint256 feeBps = primary ? fees.premiumFeeBps : fees.resaleFeeBps;
            uint256 sellerFee = premium * feeBps / V2Constants.BPS;
            plan.fills[plan.count++] = Fill({
                index: i,
                orderId: id,
                maker: o.maker,
                kind: o.kind,
                primary: primary,
                units: units,
                price: o.price,
                premium: premium,
                sellerFee: sellerFee
            });
            plan.units += units;
            plan.premium += premium;
            plan.sellerFees += sellerFee;
        }
        plan.next = i;
        plan.takerFee = _takerFee(plan.premium, fees, ex.discountBps);
    }

    /// @dev True when `id` is already in this round's plan or was tried by an earlier round of the same take, so an id
    ///      named twice is tried once.
    function _seen(Plan memory plan, Exec memory ex, uint256 id) private pure returns (bool) {
        for (uint256 i; i < plan.count; ++i) {
            if (plan.fills[i].orderId == id) return true;
        }
        for (uint256 i; i < ex.triedCount; ++i) {
            if (ex.tried[i] == id) return true;
        }
        return false;
    }

    /// @dev Executes one round: per planned fill its delivery, then (when it went through) its OrderFilled, accruing
    ///      into `ex`. Stops at the first fill skipped at execution and returns (true, the index after that order's id)
    ///      so {take} plans the rest again; otherwise returns (false, plan.next).
    ///      Share budget of the round = fee on (premium already filled + this round's planned premium) - shares already
    ///      handed out, never below zero; each fill's share is cut from it pro rata by planned premium, the round's last
    ///      planned fill absorbing exactly the flooring dust.
    function _execute(V2Types.TakeParams calldata p, V2Types.FeeParams memory fees, Plan memory plan, Exec memory ex)
        private
        returns (bool again, uint256 resumeAt)
    {
        uint256 target = _takerFee(ex.premium + plan.premium, fees, ex.discountBps);
        uint256 budget = target > ex.shares ? target - ex.shares : 0;
        uint256 cut;
        for (uint256 i; i < plan.count; ++i) {
            Fill memory f = plan.fills[i];
            uint256 share = i + 1 == plan.count ? budget - cut : budget * f.premium / plan.premium;
            cut += share;
            ex.tried[ex.triedCount++] = f.orderId;
            if (!_deliver(p, f)) return (true, f.index + 1);

            ex.units += f.units;
            ex.premium += f.premium;
            ex.sellerFees += f.sellerFee;
            ex.shares += share;
            uint256 rebate = share * _rebateBps(f.maker, fees) / V2Constants.BPS;
            // Binds only after a skip: never hand out more than the fee on what has actually filled.
            uint256 room = _takerFee(ex.premium, fees, ex.discountBps) - ex.rebates;
            if (rebate > room) rebate = room;
            ex.rebates += rebate;
            _credit(ex, f.maker, p.buying ? f.premium - f.sellerFee + rebate : rebate);
            emit OrderFilled(
                f.orderId,
                p.longId,
                msg.sender,
                f.maker,
                f.units,
                f.price,
                f.premium,
                f.sellerFee,
                rebate,
                f.primary,
                p.buying,
                p.recipient
            );
        }
        return (false, plan.next);
    }

    /// @dev Index of `account`'s budget, or budgetCount when it has none yet.
    function _budgetIndex(Plan memory plan, address account) private pure returns (uint256 i) {
        for (; i < plan.budgetCount; ++i) {
            if (plan.budgets[i].account == account) return i;
        }
    }

    /// @dev Reserves `units` * collateralPerUnit PLUS the collateral rent that mint will charge, out of `writer`'s free
    ///      collateral. False (reserve nothing) when the series cannot mint now (the market off, the mint paused, the
    ///      cutoff past, or -- INTERFACE_VERSION 8 -- the book off the Clearinghouse's minter allow-list), the book is
    ///      not `writer`'s operator, or
    ///      the rest of the budget is short: a write-on-fill order is filled whole or skipped (architecture §3.6), never
    ///      cut to the collateral.
    ///      RENT (INTERFACE_VERSION 7, c05). {Clearinghouse.mint} charges the writer
    ///      `OptionMath.mintFee(collateral, series.mintFeePpm, expiry - now)` on top of the collateral, so an account
    ///      holding exactly `units * collateralPerUnit` can no longer mint and its order must be SKIPPED here rather
    ///      than reverted at delivery. `plan.mintOpen` already established `block.timestamp < expiry -
    ///      SETTLEMENT_WINDOW`, so the subtraction cannot underflow, and the amount budgeted is base unit for base unit
    ///      what the Clearinghouse charges in that same block -- for an AskWrite fill (the maker's budget) and for a
    ///      `writeToSell` (the taker's). {quoteTake} plans identically, so its answer stays exact.
    ///      Both mint fields come from the one Series read this function already made.
    function _reserveCollateral(Plan memory plan, uint256 longId, address writer, uint64 units, bool assumeFunding)
        private
        view
        returns (bool)
    {
        if (!plan.mintLoaded) {
            plan.mintLoaded = true;
            // The series exists: an order on it passed {_place}. Cutoff, collateral asset and collateral per unit are
            // the IClearinghouse definitions (expiry - SETTLEMENT_WINDOW; USDG for puts, the underlying for calls;
            // OptionMath.collateralPerUnit), derived here from the one Series read.
            V2Types.Series memory s = _ch.series(longId);
            V2Types.MarketConfig memory m = _ch.market(s.underlying);
            // INTERFACE_VERSION 8: the book must be on the Clearinghouse's minter allow-list, the same condition
            // {Clearinghouse.mint} enforces at delivery.
            plan.mintOpen = m.enabled && !m.mintPaused && _ch.isMinter(address(this))
                && block.timestamp < s.expiry - V2Constants.SETTLEMENT_WINDOW;
            plan.collateralAsset = s.isPut ? address(usdg) : s.underlying;
            plan.collateralPerUnit = OptionMath.collateralPerUnit(s.isPut, s.strike);
            plan.mintFeePpm = s.mintFeePpm;
            plan.expiry = s.expiry;
        }
        if (!plan.mintOpen) return false;
        uint256 b = _budgetIndex(plan, writer);
        if (b == plan.budgetCount) {
            bool usable = _ch.isOperator(writer, address(this));
            uint256 free_ = usable ? _ch.free(writer, plan.collateralAsset) : 0;
            uint256 funded;
            // Fundable is added only at budget creation, only when the budget is usable, only for a maker with
            // funding on, and only while under MAX_FUNDED_MAKERS_PER_TAKE. The counter increments whenever the
            // read is made, including when the answer is 0. Source: V2Constants.sol MAX_FUNDED_MAKERS_PER_TAKE.
            if (
                assumeFunding && usable && _funding[writer].on
                    && plan.fundedCount < V2Constants.MAX_FUNDED_MAKERS_PER_TAKE
            ) {
                funded = _fundable(writer, plan.collateralAsset);
                ++plan.fundedCount;
            }
            plan.budgets[plan.budgetCount++] =
                Budget({account: writer, usable: usable, left: free_ + funded, funded: funded});
        }
        uint256 collateral = uint256(units) * plan.collateralPerUnit;
        return _consume(
            plan.budgets[b], collateral + OptionMath.mintFee(collateral, plan.mintFeePpm, plan.expiry - block.timestamp)
        );
    }

    /// @dev Reserves `units` of `seller`'s long balance for a transfer by the book (ERC-1155 approval). Whole or
    ///      nothing, like {_reserveCollateral}.
    function _reserveInventory(Plan memory plan, uint256 longId, address seller, uint64 units)
        private
        view
        returns (bool)
    {
        uint256 b = _budgetIndex(plan, seller);
        if (b == plan.budgetCount) {
            bool usable = _ch.isApprovedForAll(seller, address(this));
            plan.budgets[plan.budgetCount++] =
                Budget({account: seller, usable: usable, left: usable ? _ch.balanceOf(seller, longId) : 0, funded: 0});
        }
        return _consume(plan.budgets[b], units);
    }

    function _consume(Budget memory budget, uint256 amount) private pure returns (bool) {
        if (!budget.usable || budget.left < amount) return false;
        budget.left -= amount;
        return true;
    }

    /// @dev Executes one planned fill's token delivery. Marks the units filled first (checks-effects-interactions) and
    ///      undoes that if a skippable delivery reverts. Delivery per §1.8:
    ///        buying, AskResale: book -> recipient (not caught: a recipient rejecting tokens reverts the take);
    ///        buying, AskWrite: Clearinghouse.mint(longId, units, maker, recipient), caught;
    ///        selling, writeToSell: Clearinghouse.mint(longId, units, taker, bidMaker), caught;
    ///        selling from inventory: taker -> bidMaker, caught.
    ///      Every caught delivery runs with DELIVERY_GAS, so a receiver hook cannot spend the rest of the take's gas.
    function _deliver(V2Types.TakeParams calldata p, Fill memory f) private returns (bool ok) {
        StoredOrder storage o = _orders[f.orderId];
        o.filled += f.units;
        ok = true;
        if (p.buying) {
            if (f.kind == V2Types.OrderKind.AskResale) {
                _ch.safeTransferFrom(address(this), p.recipient, p.longId, f.units, "");
            } else {
                try _ch.mint{gas: DELIVERY_GAS}(p.longId, f.units, f.maker, p.recipient) {}
                catch {
                    ok = false;
                }
            }
        } else if (p.writeToSell) {
            try _ch.mint{gas: DELIVERY_GAS}(p.longId, f.units, msg.sender, f.maker) {}
            catch {
                ok = false;
            }
        } else {
            try _ch.safeTransferFrom{gas: DELIVERY_GAS}(msg.sender, f.maker, p.longId, f.units, "") {}
            catch {
                ok = false;
            }
        }
        if (!ok) o.filled -= f.units;
    }

    /// @dev Rebate rate of `maker`, bps of its taker-fee share: the registry's non-zero answer clamped to BPS, else the
    ///      book default. A raw staticcall capped at REBATE_READ_GAS that copies only the first word of the answer,
    ///      decoded as uint256: a reverting, short or dirty answer cannot revert a take, and a registry that burns its
    ///      gas or answers at length costs each fill at most the cap.
    function _rebateBps(address maker, V2Types.FeeParams memory fees) private view returns (uint256) {
        address registry = address(makerRegistry);
        if (registry != address(0)) {
            bytes memory data = abi.encodeCall(IMakerRegistry.rebateBps, (maker));
            bool ok;
            uint256 bps;
            assembly ("memory-safe") {
                ok := staticcall(REBATE_READ_GAS, registry, add(data, 0x20), mload(data), 0x00, 0x20)
                ok := and(ok, iszero(lt(returndatasize(), 0x20)))
                bps := mload(0x00)
            }
            if (ok && bps != 0) return bps > V2Constants.BPS ? V2Constants.BPS : bps;
        }
        return fees.makerRebateBps;
    }

    /// @dev Adds `amount` USDG base units to `account`'s aggregated payment of this take.
    function _credit(Exec memory ex, address account, uint256 amount) private pure {
        uint256 i;
        while (i < ex.payeeCount && ex.payees[i] != account) {
            ++i;
        }
        if (i == ex.payeeCount) ex.payees[ex.payeeCount++] = account;
        ex.amounts[i] += amount;
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL: USDG
    //////////////////////////////////////////////////////////////*/

    /// @dev Pulls `amount` USDG base units from `from` (ERC-20 approval of the book) and checks the balance delta
    ///      (UnsupportedAsset when less arrives). Zero is a no-op.
    function _pullUsdg(address from, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(from, address(this), amount);
        if (usdg.balanceOf(address(this)) - before < amount) revert V2Errors.UnsupportedAsset();
    }

    /// @dev Pays `amount` USDG base units to `to`, or credits {owed} when the transfer reverts or returns false.
    ///      Zero is a no-op (the live USDG rejects even zero-value transfers to a frozen address).
    function _payOrOwe(address to, uint256 amount) private {
        if (amount == 0) return;
        if (!_tryTransfer(to, amount)) owed[to] += amount;
    }

    /// @dev Best-effort USDG transfer that never reverts the caller (KeeperRewards._tryTransfer): empty return data
    ///      counts as success (the constructor rules out a code-less token); the return word is compared with 1 rather
    ///      than decoded as bool, which would revert on a dirty bool.
    function _tryTransfer(address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(usdg).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
    }

    /// @dev CeilingExceeded unless every field is under its compiled ceiling (see {setFeeParams}).
    function _checkFeeCeilings(V2Types.FeeParams memory fees) private pure {
        if (
            fees.premiumFeeBps > V2Constants.PREMIUM_FEE_CEIL_BPS
                || fees.resaleFeeBps > V2Constants.PREMIUM_FEE_CEIL_BPS
                || fees.takerFeeFlat > V2Constants.TAKER_FEE_FLAT_CEIL
                || fees.takerFeeCapBps > V2Constants.TAKER_FEE_CAP_CEIL_BPS || fees.makerRebateBps > V2Constants.BPS
        ) revert V2Errors.CeilingExceeded();
    }

    /// @dev The fees in effect now: the scheduled ones once block.timestamp >= their effectiveAt, else the stored ones.
    ///      A view: nothing is written when a scheduled change becomes due ({setFeeParams} rolls it in later).
    function _effectiveFees() private view returns (V2Types.FeeParams memory) {
        uint40 at = _pendingFeesAt;
        return at != 0 && block.timestamp >= at ? _pendingFees : _fees;
    }

    /// @dev The book itself is refused too: fees paid to it would sit in its balance with no owner.
    function _setFeeRecipient(address recipient) private {
        if (recipient == address(0) || recipient == address(this)) revert V2Errors.NotAuthorized();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }
}
