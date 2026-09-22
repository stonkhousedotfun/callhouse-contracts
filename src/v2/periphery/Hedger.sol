// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Managed} from "../access/Managed.sol";
import {IExpiryCalendar} from "../interfaces/IExpiryCalendar.sol";
import {IHedger} from "../interfaces/IHedger.sol";
import {IPayoutAdapter} from "../interfaces/IPayoutAdapter.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {MarketParams} from "./lending/MorphoDeps.sol";
import {StockLoanAdapter} from "./lending/StockLoanAdapter.sol";
import {V4Buy} from "./v4/V4Buy.sol";

/// @title Hedger
/// @notice Posts USDG, borrows stock, sells via {IPayoutAdapter.swapToUsdg}, buys back via {V4Buy}.
/// @dev Disabled per asset at construction. New shorts are blocked by a stale `trySpot` AND, once a calendar is
///      wired, outside the regular trading session (D29). UNWINDING IS NOT (T-OP-066, SEC-21c): an exit needs a
///      spot the oracle stands behind -- `trySpot` ok, which since T-OP-061 means "no older than the oracle's
///      thirty minutes, or corroborated by the market's live pool within its band" -- and, since T-OP-067, the
///      global {paused} freeze, and nothing else. The two spot rules are {_requireFresh} (new risk) and
///      {_requireUsable} (exits), and they are separate on purpose; {paused} sits above both.
contract Hedger is IHedger, Managed, ReentrancyGuardTransient, V4Buy {
    using SafeERC20 for IERC20;

    /// @dev MakerVault.sol:199 — leaky-bucket window. Copied as a window length, not re-derived maths.
    uint256 public constant OUTFLOW_WINDOW = 1 days;
    uint128 public constant MAX_BORROW_CEIL = 1e27;
    uint128 public constant MAX_COLLATERAL_CEIL = 1e15;
    uint16 public constant HF_FLOOR_CEIL_BPS = 20_000;
    uint16 public constant SLIPPAGE_CEIL_BPS = 2_000;
    uint128 public constant DAILY_NOTIONAL_CEIL = 1e15;
    /// @notice The oldest a spot may be allowed to be, whatever {setFreshnessSeconds} is set to. 1 day.
    /// @dev SEC-04. {freshnessSeconds} was written straight to storage with no bound, so a delay-0 role holder
    ///      could set it to `type(uint256).max` and make {_requireFresh} pass on ANY spot, however old -- which
    ///      turns the oracle floor in {hedge} into a floor against a stale number. The bound has to be
    ///      COMPILED IN rather than another settable limit, because a settable ceiling is the same key away.
    ///      T-OP-066: {unwind} no longer reads this at all. Its floor is bounded by the ORACLE's accuracy rule
    ///      (`trySpot` ok: thirty minutes, or pool-corroborated up to the market's `spotMaxAge`, itself capped at
    ///      `MAX_SPOT_MAX_AGE`), so no Hedger key can loosen the exit's floor through this setter.
    ///      One day, not one hour: this is the ceiling, not the policy. The default stays 1 hour and the operator
    ///      may loosen it for a market with thin quotes, but not past the point where "fresh" stops meaning
    ///      anything. A spot older than a day cannot legitimise a swap of treasury funds under any configuration.
    uint256 public constant FRESHNESS_CEIL = 1 days;

    ISettlementOracle public immutable oracle;
    IPayoutAdapter public immutable payout;
    StockLoanAdapter public immutable loan;

    /// @notice The ONLY address {withdraw} and {withdrawCollateral} can pay. Immutable, set at construction.
    /// @dev v8's single-exit rule: the exit is a property of the CONTRACT, not of each call. {MakerVault} and
    ///      {RewardsDistributor} already dropped their caller-supplied recipients for this reason. A free `to` on a
    ///      money path is the same shape as `F-CP-01`, where an unauthenticated withdraw with a caller-chosen
    ///      recipient was the whole vulnerability -- there the caller picked the address, here a delay-0 role holder
    ///      would, and every role on this contract is a hot key.
    address public immutable treasury;

    /// @notice Per-asset switch for NEW shorts. Every asset starts disabled; {setEnabled} flips one at a time.
    /// @dev PER ASSET, AND SEPARATE FROM {paused}. {hedge} refuses on {paused} first and then on this entry, so
    ///      "is the hedger switched off" is {paused} OR every asset's entry -- one asset's `false` says nothing
    ///      about another's. Neither {unwind} nor {repay} reads this per-asset entry; {unwind} DOES read the
    ///      global {paused} (T-OP-067). This line used to carry the notice of the `CalendarSet` event that T-265
    ///      deleted, so the flag's own documentation described the calendar.
    mapping(address asset => bool) public enabled;
    /// @notice Global freeze: {hedge} and {unwind} both refuse {Paused} while set. {repay} does not.
    /// @dev OWNER RULING 2026-09-22 item 13 (T-OP-067): pause freezes EVERYTHING that spends this contract's
    ///      money. Until then this was "NEW shorts only" and a paused Hedger still let the QUOTER key spend USDG
    ///      through {unwind} (T-553 ep3 suspicion 1). {repay} stays open on purpose: it only REDUCES the loan
    ///      with Stock Token the caller supplies, spends nothing of the vault's, and is the escape hatch "a brake
    ///      must never trap inventory" is about -- freezing it would turn a pause into a trap.
    bool public paused;
    Limits private _limits;
    uint256 public freshnessSeconds = 1 hours;

    /// @notice The trading-week authority, fixed at construction. New shorts are gated on it (D29).
    /// @dev CONSUMED, NOT REINVENTED. {IExpiryCalendar} already owns this protocol's notion of the trading week --
    ///      regular sessions, early closes and the New York offset across DST. A day-of-week computation inside this
    ///      contract would be a SECOND source of truth about when the market is open, and the two would drift
    ///      apart on exactly the days that matter (a half-day, a holiday, the week a DST boundary moves).
    ///
    ///      IMMUTABLE, AND THE SETTER IS GONE (T-265, option A). T-226 shipped a restricted setter because option A
    ///      was blocked by live lanes, not because a settable pointer was right. This contract decides WHEN NEW
    ///      SHORTS MAY OPEN, so a pointer to it is a lever over that decision; the contract is unlaunched, so the
    ///      lever has no operational reason to exist and costs nothing to remove now. Re-verified at this base
    ///      before changing it: `new Hedger(` appears only in test files, nothing under `script/` constructs one,
    ///      `DeployV8.s.sol` records that Hedger arrives by environment, and neither `ops/markets/dev.json` nor
    ///      `ops/markets/tier1.json` carries a hedger address. No deployed instance can be stranded by this.
    ///
    ///      A SECOND THING DIED WITH THE SETTER, worth recording because a later reader may go looking for it:
    ///      `setCalendar(address)` was `restricted` and was NOT listed in `script/v2/roles.v8.json` under Hedger,
    ///      so it answered to ADMIN by AccessManager's default. That is the finding WIRE-09 and BUG-05 F-05-02
    ///      both name. Removing the function removes the unmapped selector; no manifest edit was needed, and none
    ///      was made -- `roles.v8.json` never listed it.
    IExpiryCalendar public immutable calendar;

    /// @dev D29'S "LARGER COLLATERAL BUFFER" HALF IS DELIBERATELY NOT IMPLEMENTED, AND THIS COMMENT IS THE
    ///      DELIVERABLE FOR IT. The decision asks for two things: no new shorts after the Friday close, and a
    ///      larger collateral buffer while the equity oracle is frozen. I built the first and then could not
    ///      build the second honestly, because THE TWO OVERLAP UNTIL THE SECOND HAS NO WINDOW LEFT:
    ///
    ///        - {_requireFresh} already refuses a new short when the spot is older than {freshnessSeconds}. So a
    ///          buffer "while the oracle is frozen" has no new short to apply to -- the short was already refused.
    ///        - {_requireOpenSession} now refuses a new short outside the regular session. So a buffer for a short
    ///          "opened while the market is closed" has no new short to apply to either.
    ///
    ///      Between them, every state the buffer was meant to cover is a state where {hedge} reverts. Adding a
    ///      buffer term would have produced a storage slot, a setter, a ceiling and a test -- all unreachable, and
    ///      all looking like a risk control that is doing something. That is worse than the gap: an unreachable
    ///      guard is the thing a later reader trusts.
    ///
    ///      WHAT WOULD MAKE IT REAL, for whoever respecifies it: a buffer needs a state where a short is ALLOWED
    ///      but riskier -- for example a spot that is aging but still inside {freshnessSeconds}, or a session that
    ///      is open but within N minutes of the close. Both are new thresholds and neither is in the decision. It
    ///      is a product question, not a code one.

    uint216 private _notionalScaled;
    uint40 private _notionalAt;

    /// @param calendar_ The trading-week authority. Refused here if it is zero, codeless, or does not answer the
    ///        calendar surface -- the same three refusals the removed `setCalendar` made, moved to construction.
    constructor(
        address authority_,
        address usdg_,
        address poolManager_,
        address oracle_,
        address payout_,
        address morpho_,
        address treasury_,
        address calendar_
    ) Managed(authority_) V4Buy(poolManager_, usdg_) {
        if (oracle_.code.length == 0 || payout_.code.length == 0) revert V2Errors.NoSource();
        if (treasury_ == address(0)) revert V2Errors.NotAuthorized();
        // THE FAIL-CLOSED BEHAVIOUR T-226 ESTABLISHED, PRESERVED AND MOVED EARLIER. `code.length` alone accepts
        // any contract, and a pointer that is not a calendar would make {hedge} revert on every call with a
        // message about the market being closed, so the probe mirrors `Clearinghouse._requireSettlementOracle`
        // (SEC-07). A zero address has no code, so the first test covers it too. Refusing at construction rather
        // than at set time is strictly stronger: there is now no window in which a Hedger exists unwired.
        if (calendar_.code.length == 0) revert V2Errors.NoSource();
        // forge-lint: disable-next-line(unsafe-typecast)
        try IExpiryCalendar(calendar_).isRegularSession(uint40(block.timestamp)) returns (bool) {}
        catch {
            revert V2Errors.NoSource();
        }
        calendar = IExpiryCalendar(calendar_);
        treasury = treasury_;
        oracle = ISettlementOracle(oracle_);
        payout = IPayoutAdapter(payout_);
        loan = new StockLoanAdapter(morpho_, usdg_, address(this));
        IERC20(usdg_).forceApprove(address(loan), type(uint256).max);
    }

    function limits() external view returns (Limits memory) {
        return _limits;
    }

    function setEnabled(address asset, bool on) external nonReentrant restricted {
        enabled[asset] = on;
        emit EnabledSet(asset, on);
    }

    function pause(bool on) external nonReentrant restricted {
        paused = on;
        emit PausedSet(on);
    }

    function setLimits(Limits calldata next) external nonReentrant restricted {
        if (
            next.maxBorrowPerAsset > MAX_BORROW_CEIL || next.maxUsdgCollateral > MAX_COLLATERAL_CEIL
                || next.healthFactorFloorBps > HF_FLOOR_CEIL_BPS || next.slippageBps > SLIPPAGE_CEIL_BPS
                || next.maxDailyNotional > DAILY_NOTIONAL_CEIL
        ) revert CeilingExceeded();
        if (next.healthFactorFloorBps > V2Constants.BPS * 2) revert CeilingExceeded();
        if (next.slippageBps > V2Constants.BPS) revert CeilingExceeded();
        // SEC-33. SETTLE THE NOTIONAL BUCKET AT THE OLD CAP BEFORE THE NEW ONE IS STORED.
        //
        // {_refilled} computes `cap * (block.timestamp - _notionalAt)`, so the refill owed for time ALREADY
        // ELAPSED is priced at whatever cap is in storage when it is next read. Without this line, raising
        // `maxDailyNotional` re-prices the whole elapsed period at the new, higher rate and REFILLS THE BUCKET
        // RETROACTIVELY -- so the daily rate limit can be reset by CONFIG_ADMIN, the same key class it exists to
        // limit, by raising the cap and lowering it again. A rate limit its own key can clear is not a rate limit.
        //
        // MIRRORED, NOT INVENTED. `MakerVault._setLimits` (src/v2/mm/MakerVault.sol:694-706) already does exactly
        // this for its outflow bucket, and `_refilled` below cites `MakerVault.sol:644-677` as the shape it
        // copied. The refill half was copied and the settlement half was not; this restores the pair.
        //
        // casting is safe: {_refilled} only ever lowers the stored uint216
        // forge-lint: disable-next-line(unsafe-typecast)
        _notionalScaled = uint216(_refilled(_limits.maxDailyNotional));
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        _notionalAt = uint40(block.timestamp);
        _limits = next;
        emit LimitsSet(next);
    }

    /// @notice Sets how old a spot may be and still be usable. Bounded by {FRESHNESS_CEIL}.
    /// @dev Zero is allowed and is the strict end: it makes every spot stale, so {hedge} and {unwind} both refuse.
    ///      The bound is only on the loose end, because only the loose end fails OPEN.
    function setFreshnessSeconds(uint256 seconds_) external nonReentrant restricted {
        if (seconds_ > FRESHNESS_CEIL) revert CeilingExceeded();
        freshnessSeconds = seconds_;
        emit FreshnessSet(seconds_);
    }

    function setStockLoanMarket(MarketParams calldata params) external nonReentrant restricted {
        loan.setMarket(params);
    }

    function fund(uint256 usdgAmount) external nonReentrant restricted {
        if (usdgAmount == 0) revert V2Errors.BadUnits();
        IERC20(usdg).safeTransferFrom(msg.sender, address(this), usdgAmount);
    }

    /// @notice Sends `usdgAmount` of the vault's idle USDG to the immutable {treasury}.
    /// @dev The recipient is NOT a parameter. See {treasury}.
    function withdraw(uint256 usdgAmount) external nonReentrant restricted {
        if (usdgAmount == 0) revert V2Errors.BadUnits();
        IERC20(usdg).safeTransfer(treasury, usdgAmount);
    }

    /// @notice Pulls `assets` of USDG collateral back out of the loan market and sends it to {treasury}.
    /// @dev F-CP-02. WITHOUT THIS FUNCTION EVERY USDG POSTED AS COLLATERAL IS LOCKED FOREVER.
    ///      {StockLoanAdapter.withdrawCollateral} is `onlyOwner` and this contract is its immutable owner --
    ///      `loan = new StockLoanAdapter(morpho_, usdg_, address(this))` in the constructor -- so this contract is
    ///      the only address in existence that can ever call it, and until now nothing did. The adapter is
    ///      immutable, so no role, delay or upgrade could have recovered the collateral either.
    ///      Morpho refuses a withdrawal that would leave the position unhealthy, so the health floor is enforced
    ///      by the venue rather than restated here.
    function withdrawCollateral(address asset, uint256 assets) external nonReentrant restricted {
        if (assets == 0) revert V2Errors.BadUnits();
        loan.withdrawCollateral(asset, assets, treasury);
    }

    /// @dev New short. Reverts while disabled, paused, or weekend/stale. Borrow first; sell only after.
    function hedge(address asset, uint256 borrowAssets, uint256 collateralUsdg, uint256 minUsdgOut)
        external
        nonReentrant
        restricted
    {
        if (paused) revert Paused();
        if (!enabled[asset]) revert Disabled();
        // T-CV-HEDGER-AND-LEND. THESE TWO GUARDS REVERT THE SAME ERROR, AND THE ORDER IS LOAD-BEARING FOR TESTS.
        // `_requireFresh` answers WeekendBrake for a STALE SPOT and `_requireOpenSession` answers WeekendBrake for
        // a CLOSED SESSION, so `vm.expectRevert(WeekendBrake.selector)` cannot tell which one fired and the first
        // one silently wins. A test whose fixture ages the spot never reaches the calendar at all -- traced, and
        // {test_weekendBrakeWhileEnabled} is exactly that test. The session guard is proven separately by
        // {test_hedge_refusedOutsideTheRegularSessionEvenWithAFreshOracle}, which holds the spot CURRENT so this
        // line passes and the next one is the only thing left to refuse. Keep that pairing if either guard moves.
        _requireFresh(asset);
        _requireOpenSession();
        Limits memory lim = _limits;
        if (borrowAssets == 0 || collateralUsdg == 0) revert V2Errors.BadUnits();
        // F-CP-08, AND THE LINE BELOW IS WHERE IT ACTUALLY BIT. Morpho only updates `totalBorrowAssets` when
        // something touches the market, so `loan.borrowed` reads a debt that is stale by however long the market
        // has been idle -- which UNDERSTATES it, and makes this ceiling too generous by exactly the accrued
        // interest. The health-factor check further down is not the vulnerable read: `morpho.borrow` accrues on
        // the way through, so by the time it runs the totals have already moved. This one runs first, before
        // anything has touched the market, which is why the accrual belongs here.
        loan.accrue(asset);
        if (loan.borrowed(asset) + borrowAssets > lim.maxBorrowPerAsset) revert LimitExceeded();
        if (loan.collateral(asset) + collateralUsdg > lim.maxUsdgCollateral) revert LimitExceeded();
        _chargeNotional(collateralUsdg, lim.maxDailyNotional);
        (, uint256 px,) = oracle.trySpot(asset);
        // T-512 / T-590. BEFORE the floor, and with the SAME error {unwind} already uses at its own `trySpot`.
        // `_requireFresh` reads `(bool ok, /*price*/, uint256 updatedAt)` and DISCARDS the price by construction,
        // so it proves liveness and staleness and never the value -- and `ok` does not imply non-zero. A zero `px`
        // makes `expected` zero, makes `floor` zero, and leaves the refusal below bounded only by `minUsdgOut`,
        // which is caller input and so cannot bound itself. Placing the check after the floor would be too late:
        // the floor is already zero by then. {unwind} has always refused this input; the two paths now refuse it
        // identically, which is the point -- a different error here would move the asymmetry rather than close it.
        if (px == 0) revert V2Errors.BadPrice();
        uint256 expected = borrowAssets * px / 1e18;
        uint256 floor = expected * (V2Constants.BPS - lim.slippageBps) / V2Constants.BPS;
        if (minUsdgOut < floor) revert Slippage();

        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        loan.postCollateral(asset, collateralUsdg);
        loan.borrow(asset, borrowAssets, address(this));
        if (loan.healthFactorBps(asset) < lim.healthFactorFloorBps) revert LimitExceeded();

        IERC20(asset).forceApprove(address(payout), borrowAssets);
        uint256 out = payout.swapToUsdg(asset, borrowAssets, minUsdgOut, address(this));
        IERC20(asset).forceApprove(address(payout), 0);
        if (IERC20(asset).balanceOf(address(this)) != assetBefore) revert V2Errors.BadUnits();
        emit Hedged(asset, borrowAssets, collateralUsdg, out);
    }

    function unwind(address asset, uint256 usdgIn, uint256 minAssetOut, uint24 fee, int24 tickSpacing)
        external
        nonReentrant
        restricted
    {
        // T-OP-067: the global freeze, FIRST and in the same shape as {hedge}. A pause is the operator saying "no
        // money moves"; an unwind spends this contract's USDG, so it is money moving. Checked before the input
        // guards so a paused Hedger answers {Paused} to every unwind, not only to well-formed ones.
        if (paused) revert Paused();
        if (usdgIn == 0) revert V2Errors.BadUnits();
        // F-CP-05, THE OTHER HALF. {_buyExactInput} now spends THIS CONTRACT'S USDG rather than the caller's, so a
        // caller-chosen route and a caller-chosen `minAssetOut` would otherwise be a way to spend the vault's money
        // badly. Bound the output against a source the caller does not control, exactly as {hedge} bounds its own
        // swap: the oracle spot and the configured slippage. `_requireUsable` is what makes that spot usable --
        // NOT `_requireFresh` (T-OP-066). The floor needs a spot that is ACCURATE, not one that is YOUNG, and since
        // T-OP-061 the oracle answers exactly that question: `trySpot` is ok for a print inside its thirty minutes
        // OR for an older print the market's live pool corroborates within the band. Bounding the exit by raw age
        // on top of that refused every weekend unwind (the Chainlink feed is 24/5) while the Morpho liquidation of
        // the same position waited for nobody (SEC-21c). The owner's ruling was to use the live pool price; the
        // oracle's corroboration IS that, without handing a thin pool the price-setting role (SEC-09).
        uint256 px = _requireUsable(asset);
        Limits memory lim = _limits;

        // THE FLOOR FIRST, BEFORE ANY STATE IS TOUCHED. `minAssetOut` against the oracle is pure input validation
        // and costs nothing; `loan.accrue` below WRITES to Morpho. Validating the caller's numbers before paying
        // for a state write on a call that was never going to succeed is the right order, and it also keeps the
        // refusal a caller sees for a bad `minAssetOut` the same one they saw before this change.
        uint256 expectedAsset = usdgIn * 1e18 / px;
        uint256 assetFloor = expectedAsset * (V2Constants.BPS - lim.slippageBps) / V2Constants.BPS;
        if (minAssetOut < assetFloor) revert Slippage();

        // SEC-04 (1). ACCRUE, THEN READ THE DEBT. `IHedger.NothingBorrowed` has been declared since v8 and NO
        // code path fired it -- the guard was designed and dropped. This is it. The accrual is not optional and
        // not cosmetic: Morpho only moves `totalBorrowAssets` when something touches the market, so a stale read
        // UNDERSTATES the debt, and every bound derived from it below would be too tight rather than too loose --
        // the safe direction, but it would refuse legitimate final repayments. {hedge} accrues first for the
        // mirror-image reason; see its note.
        loan.accrue(asset);
        uint256 owed = loan.borrowed(asset);
        if (owed == 0) revert NothingBorrowed();

        // SEC-04 (2). BOUND `usdgIn` BY WHAT IS ACTUALLY OWED. Without this a QUOTER key -- a hot key with zero
        // delay -- could pass the entire USDG balance and convert the whole treasury position into stock in one
        // call. The oracle floor above makes that conversion FAIR, so it is not a theft; it is still the whole
        // balance moved with no ceiling, which is exactly what `maxBorrowPerAsset` and `maxUsdgCollateral` exist
        // to prevent on the {hedge} side.
        //
        // THE GROSS-UP IS LOAD-BEARING, not slack. Bounding at the debt's oracle value alone would make a final
        // repayment IMPOSSIBLE whenever the pool is worse than the oracle by any amount at all: you would be
        // allowed to spend exactly the mid-price value of the debt and would buy slightly less stock than the
        // debt, forever. So the ceiling is the debt valued at the worst price this contract is willing to accept
        // -- `slippageBps` away from spot -- which is the most that can ever legitimately be needed and not a
        // wei more.
        uint256 maxUsdgIn = (owed * px / 1e18) * V2Constants.BPS / (V2Constants.BPS - lim.slippageBps);
        if (usdgIn > maxUsdgIn) revert LimitExceeded();

        // SEC-04 (3). CHARGE THE SAME BUCKET {hedge} CHARGES. The daily notional limiter metered the hedge side
        // and not this one, so the rate limit could simply be walked around by doing the volume through `unwind`.
        // Charged BEFORE the external call, exactly where {hedge} charges it.
        _chargeNotional(usdgIn, lim.maxDailyNotional);

        uint256 got = _buyExactInput(asset, usdgIn, minAssetOut, address(this), fee, tickSpacing);

        // SEC-04 (4). CAP THE REPAY AT THE DEBT SO THE LAST LEG CAN CLOSE. `StockLoanAdapter.repay` forwards the
        // amount to `morpho.repay(p, assets, 0, ...)`, which underflows when `assets` exceeds the outstanding
        // debt -- so before this, the final partial repayment of a position reverted and the debt could not be
        // closed in one call. Any surplus stock stays in this contract as an idle balance rather than being
        // forced into the market; {repay} and the adapter's own exits can move it later.
        uint256 pay = got > owed ? owed : got;
        IERC20(asset).forceApprove(address(loan), pay);
        loan.repay(asset, pay);
        IERC20(asset).forceApprove(address(loan), 0);
        emit Unwound(asset, usdgIn, got);
    }

    /// @dev Always-on exit. Not `restricted`. Works while disabled, paused, or weekend-frozen -- and PAUSED is
    ///      deliberate (T-OP-067): this path spends nothing of the vault's, it only takes Stock Token from the
    ///      caller and pays the loan down, so it is the one exit a freeze must leave open.
    function repay(address asset, uint256 assets) external nonReentrant {
        if (assets == 0) revert V2Errors.BadUnits();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(asset).forceApprove(address(loan), assets);
        loan.repay(asset, assets);
        IERC20(asset).forceApprove(address(loan), 0);
    }

    function notional() external view returns (uint256 used, uint256 available) {
        uint256 cap = _limits.maxDailyNotional;
        used = (_refilled(cap) + OUTFLOW_WINDOW - 1) / OUTFLOW_WINDOW;
        available = cap > used ? cap - used : 0;
    }

    /// @dev D29's calendar half: a NEW SHORT may only be opened during a regular trading session.
    ///
    ///      THE UNWIRED CASE NO LONGER EXISTS, which is why its check is gone (T-265). T-226 refused a zero
    ///      calendar here with {V2Errors.NoSource}, because the pointer was settable and a Hedger could exist
    ///      before anyone wired it. The pointer is now an immutable the constructor refuses to leave zero,
    ///      codeless or non-answering, so `address(calendar) == 0` is unreachable. Keeping the branch would have
    ///      left a guard that cannot fire -- and this file already argues, about D29's buffer half, that an
    ///      unreachable guard is worse than a stated gap because it is the thing a later reader trusts. The
    ///      protection did not weaken; it moved earlier, from set time to construction time, where there is no
    ///      window at all rather than a window that closed when someone remembered.
    ///
    ///      REUSES {WeekendBrake} rather than introducing an error. The error lives on {IHedger}, outside this
    ///      task, and its name already describes this exact refusal -- a new short blocked because the market is
    ///      not open. A second error would say the same thing in a file I cannot edit.
    ///
    ///      GATES {hedge} ONLY, NEVER {unwind} OR {repay}. {HouseVault.cancel} states the rule this codebase
    ///      follows -- a brake must never trap inventory -- and this contract already marks its always-on exit as
    ///      deliberately unguarded. A closed session must stop new risk being taken, not stop existing risk being
    ///      unwound: the weekend is exactly when someone might need out.
    function _requireOpenSession() private view {
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!calendar.isRegularSession(uint40(block.timestamp))) revert WeekendBrake();
    }

    /// @dev THE RULE FOR NEW RISK, {hedge} only: the spot must be usable AND no older than {freshnessSeconds}.
    ///      A brake on OPENING a short across a quiet feed is a product choice this contract keeps; the weekend
    ///      refusal it produces is named {WeekendBrake} because that is what it is.
    function _requireFresh(address asset) private view {
        (bool ok,/*price*/, uint256 updatedAt) = oracle.trySpot(asset);
        if (!ok || block.timestamp - updatedAt > freshnessSeconds) revert WeekendBrake();
    }

    /// @dev THE RULE FOR EXITS, {unwind} only (T-OP-066): the spot must be one the oracle stands behind, and that is
    ///      all. `ok` from {ISettlementOracle.trySpot} already encodes accuracy (T-OP-061: inside the oracle's
    ///      thirty minutes, or corroborated by the live pool within the band), so a further raw-age bound here
    ///      would only re-create the weekend refusal that SEC-21c named. The refusal says what failed -- there is
    ///      no spot the oracle will stand behind -- with the oracle's own error and the `updatedAt` it returned
    ///      (0 when it returns nothing), so a decoder can tell an exit refused for a dead spot from a new short
    ///      refused by the brake. A zero price with `ok` is still refused as {V2Errors.BadPrice} (T-512), in the
    ///      same order as before, so the floor is never computed from nothing.
    /// @return px The usable spot.
    function _requireUsable(address asset) private view returns (uint256 px) {
        (bool ok, uint256 price, uint256 updatedAt) = oracle.trySpot(asset);
        if (!ok) revert V2Errors.StaleSpot(updatedAt);
        if (price == 0) revert V2Errors.BadPrice();
        return price;
    }

    /// @dev MakerVault.sol:644-677 shape: scaled by OUTFLOW_WINDOW, refill `cap` per window, enforce on charge.
    function _refilled(uint256 cap) private view returns (uint256 s) {
        s = _notionalScaled;
        uint256 refill = cap * (block.timestamp - _notionalAt);
        s = s > refill ? s - refill : 0;
    }

    function _chargeNotional(uint256 out, uint256 cap) private {
        uint256 s = _refilled(cap);
        uint256 next = s + out * OUTFLOW_WINDOW;
        if (next > cap * OUTFLOW_WINDOW) revert LimitExceeded();
        _notionalScaled = uint216(next > type(uint216).max ? type(uint216).max : next);
        _notionalAt = uint40(block.timestamp);
    }
}
