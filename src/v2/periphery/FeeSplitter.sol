// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Managed} from "../access/Managed.sol";
import {IFeeSplitter} from "../interfaces/IFeeSplitter.sol";
import {IPayoutAdapter} from "../interfaces/IPayoutAdapter.sol";
import {IPayoutRouter} from "../interfaces/IPayoutRouter.sol";
import {IBuybackExecutor} from "../interfaces/IBuybackExecutor.sol";
import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";

/// @title FeeSplitter
/// @notice INTERFACE_VERSION 8 fee sink: accept USDG and Stock Token pushes, convert under an oracle ok-spot floor,
///         split once into buyback vs treasury, and spend the buyback balance through a swappable executor.
/// @dev Constructor is `(authority, usdg, treasury, burnBps)` as 03-INTERFACES §2.9. Oracle, router, order book,
///      executor and the STONKHOUSE token are TREASURY_ADMIN setters so the splitter can deploy first (V8-DESIGN §6).
///      `setOracle` / `setToken` are not in the frozen interface; they are added to `roles.v8.json` as TREASURY_ADMIN
///      so they are not silent ADMIN. Launch `burnBps` is 5_000 (50/50). Launch per-call cap is 50 USDG
///      (`50_000_000`), from `V2Constants` BUYBACK_CAP_CEIL natspec and `IFeeSplitter.setBuybackCap`.
contract FeeSplitter is IFeeSplitter, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 private constant SKIP_NO_ROUTE = keccak256("NO_ROUTE");
    bytes32 private constant SKIP_NO_SPOT = keccak256("NO_SPOT");
    bytes32 private constant SKIP_BELOW_FLOOR = keccak256("BELOW_FLOOR");
    bytes32 private constant SKIP_DUST = keccak256("DUST");
    bytes32 private constant SKIP_NO_EXECUTOR = keccak256("NO_EXECUTOR");
    bytes32 private constant SKIP_EMPTY = keccak256("EMPTY");
    /// @dev SEC-43: `buybackBalance` is a counter and the USDG balance is chain state; they can diverge.
    bytes32 private constant SKIP_SHORT_RESERVE = keccak256("SHORT_RESERVE");

    /// @dev 50 USDG (6 dp). Source: `V2Constants.sol` flywheel comment on `BUYBACK_CAP_CEIL` ("launch value is 50 USDG")
    ///      and `IFeeSplitter.setBuybackCap` natspec (`50_000_000`).
    uint256 private constant LAUNCH_BUYBACK_CAP = 50_000_000;

    address public immutable usdg;

    address public treasury;
    address public orderBook;
    address public router;
    address public executor;
    address public oracle;
    address public stonkhouse;
    uint16 public burnBps;
    uint16 public conversionSlippageBps;
    uint256 public buybackCap;
    bool public paused;

    uint256 public override buybackBalance;
    uint40 public override lastBuybackAt;

    constructor(address authority_, address usdg_, address treasury_, uint16 burnBps_) Managed(authority_) {
        if (usdg_.code.length == 0 || IERC20Metadata(usdg_).decimals() != 6) {
            revert V2Errors.UnsupportedAsset();
        }
        usdg = usdg_;
        _setTreasury(treasury_);
        if (uint256(burnBps_) > V2Constants.BPS) revert V2Errors.CeilingExceeded();
        burnBps = burnBps_;
        buybackCap = LAUNCH_BUYBACK_CAP;
        // The launch split and the launch cap are emitted here, not only by their setters, so that a reader with
        // nothing but this contract's logs can state what they ARE rather than only what they were last changed to.
        // `_setTreasury` above has already emitted {TreasurySet}. `paused` starts false, which is the ABI default,
        // so it needs no genesis event; every later flip emits {PausedSet}.
        emit BurnBpsSet(burnBps_);
        emit BuybackCapSet(LAUNCH_BUYBACK_CAP);
    }

    /// @inheritdoc IFeeSplitter
    function claimOrderBookFees() external nonReentrant returns (uint256 claimed) {
        address book = orderBook;
        if (book == address(0)) return 0;
        uint256 owed = IOrderBook(book).owed(address(this));
        if (owed == 0) return 0;
        uint256 before = IERC20(usdg).balanceOf(address(this));
        IOrderBook(book).claimOwed();
        claimed = IERC20(usdg).balanceOf(address(this)) - before;
        if (claimed != owed) revert V2Errors.BadUnits();
    }

    /// @inheritdoc IFeeSplitter
    function distribute(address asset) external nonReentrant returns (uint256 usdgIn) {
        return _distribute(asset, 0);
    }

    /// @notice Converts exactly `assetIn` base units of `asset` to USDG, then splits that USDG once.
    /// @dev Anyone, no role and no delay. NOT IN THE FROZEN IFeeSplitter, and deliberately so: `IFeeSplitter`'s
    ///      ERC-165 id is pinned twice in `test/v2/InterfaceIds.t.sol` (the id itself and the XOR of its 23
    ///      selectors), and a function added to the interface moves that id. `setOracle` and `setToken` sit outside
    ///      the interface for the same reason and are listed in `roles.v8.json` so they are not silent ADMIN; this
    ///      one needs no role entry because it is permissionless. The contract ABI carries it, so `ops/abis/v2`
    ///      re-export picks it up (T-422), and no consumer of the frozen interface changes.
    /// @param asset A Stock Token the splitter holds. Not USDG, which has no conversion to be locked.
    /// @param assetIn Base units to convert, at most the splitter's balance.
    /// @return usdgIn USDG base units that were split by this call (0 when it skipped).
    function distributeAmount(address asset, uint256 assetIn) external nonReentrant returns (uint256 usdgIn) {
        if (assetIn == 0) revert V2Errors.BadUnits();
        if (asset == usdg) revert V2Errors.UnsupportedAsset();
        return _distribute(asset, assetIn);
    }

    /// @dev `requested == 0` means the whole balance, which is what the frozen one-argument {distribute} asks for.
    ///
    ///      WHY THERE IS AN AMOUNT AT ALL (F-05-05). The conversion used to be the splitter's ENTIRE balance of
    ///      `asset`, with no amount, no cap and no partial path, and the swap failure below is caught rather than
    ///      bubbled. A donation is an ordinary ERC-20 transfer, so nothing rejects it and nobody can undo it: once
    ///      the balance is larger than the route can clear in one swap, EVERY call quotes that whole balance, every
    ///      swap fails the same way, and the fees underneath are locked behind somebody else's tokens for as long as
    ///      they sit there. The catch is right for a transient floor miss and permanently wrong under a donation.
    ///
    ///      THE RULE: the caller names the piece. Any caller, no role, no delay, no new configuration - the floor is
    ///      computed on the piece actually being sold, so a smaller piece is protected exactly as the whole balance
    ///      was, and repeated calls clear the rest. A per-asset cap set by an admin was the other candidate and is
    ///      not used: it would need a new restricted selector, that selector would need a `roles.v8.json` entry to be
    ///      callable by anyone but ADMIN, and that file is outside this row's scope - an unmapped restricted selector
    ///      is silent ADMIN, which is the failure this repo has already paid for. A cap would also still need this
    ///      partial path underneath it, because a cap alone just moves the threshold the donation has to clear.
    function _distribute(address asset, uint256 requested) private returns (uint256 usdgIn) {
        if (paused) revert V2Errors.TradingPaused();
        if (treasury == address(0)) revert V2Errors.NotAuthorized();
        if (asset == usdg) {
            usdgIn = _pendingUsdg();
            if (usdgIn == 0) return 0;
            _split(asset, usdgIn, usdgIn);
            return usdgIn;
        }
        uint256 held = IERC20(asset).balanceOf(address(this));
        if (held == 0) {
            emit DistributionSkipped(asset, SKIP_DUST);
            return 0;
        }
        if (requested > held) revert V2Errors.BadUnits();
        uint256 assetIn = requested == 0 ? held : requested;
        address router_ = router;
        if (router_ == address(0) || IPayoutRouter(router_).routes(asset).venue == IPayoutRouter.Venue.None) {
            emit DistributionSkipped(asset, SKIP_NO_ROUTE);
            return 0;
        }
        address oracle_ = oracle;
        if (oracle_ == address(0)) {
            emit DistributionSkipped(asset, SKIP_NO_SPOT);
            return 0;
        }
        (bool ok, uint256 price,) = ISettlementOracle(oracle_).trySpot(asset);
        if (!ok || price == 0) {
            emit DistributionSkipped(asset, SKIP_NO_SPOT);
            return 0;
        }
        uint16 routeFee = IPayoutAdapter(router_).routeFeeBps(asset);
        uint256 haircut = uint256(conversionSlippageBps) + uint256(routeFee);
        if (haircut >= V2Constants.BPS) {
            emit DistributionSkipped(asset, SKIP_DUST);
            return 0;
        }
        uint256 quoted = assetIn * price / 1e18;
        uint256 minOut = quoted * (V2Constants.BPS - haircut) / V2Constants.BPS;
        if (minOut == 0) {
            emit DistributionSkipped(asset, SKIP_DUST);
            return 0;
        }
        uint256 before = IERC20(usdg).balanceOf(address(this));
        IERC20(asset).forceApprove(router_, assetIn);
        try IPayoutAdapter(router_).swapToUsdg(asset, assetIn, minOut, address(this)) returns (uint256 reported) {
            // The router must have taken EXACTLY the piece it was offered. This was `balanceOf(this) != 0`, which
            // asserted the same thing only because the piece was always the whole balance; as a rule about a partial
            // sale that check is not merely too strict, it is a different claim, and it is the line that made a
            // partial conversion impossible.
            if (IERC20(asset).balanceOf(address(this)) != held - assetIn) revert V2Errors.BadUnits();
            usdgIn = IERC20(usdg).balanceOf(address(this)) - before;
            if (usdgIn < minOut || reported != usdgIn) revert V2Errors.BadPrice();
        } catch {
            IERC20(asset).forceApprove(router_, 0);
            emit DistributionSkipped(asset, SKIP_BELOW_FLOOR);
            return 0;
        }
        IERC20(asset).forceApprove(router_, 0);
        _split(asset, assetIn, usdgIn);
    }

    /// @inheritdoc IFeeSplitter
    /// @dev WHERE EACH BOUND ON THIS BUY COMES FROM (SEC-42), because this function enforces only the last of them.
    ///      Leg USDG->WETH: the executor's own on-chain v3 TWAP floor, which a caller may RAISE and cannot lower
    ///      ({V4BuybackExecutor.buy} takes the larger of that floor and the caller's). Route cost: the executor's
    ///      declared and measured fee caps. Leg ETH->token on v4: `minTokenOut` and NOTHING ELSE -- there is no
    ///      independent price for the token, so this leg is bounded by the keeper's number, which ADR-15 4 calls a
    ///      bound on the fill rather than a price. Burn: the check below, against the token's total-supply delta.
    ///      The executor is REPLACEABLE, so none of the first three is a property of this contract; it verifies the
    ///      burn and holds the cap and the cooldown.
    /// @dev SEC-43: `buybackBalance` is a COUNTER this contract increments in {_split}, not a measured balance. The
    ///      USDG itself can leave without passing through here -- a USDG issuer that can burn from a holder wipes the
    ///      backing while the counter keeps its value. The reserve is then unspendable, and the call below refuses
    ///      with {BuybackSkipped}(SHORT_RESERVE) rather than reverting inside the executor's `transferFrom` with an
    ///      ERC-20 error that names no cause. It FAILS CLOSED and this contract does NOT reconcile the counter
    ///      downward: writing the hole off would hand the treasury the income that currently refills the buyback
    ///      claim, which is an economics decision and not this contract's to make. Recovery is more USDG arriving.
    function buyback(uint256 minTokenOut) external nonReentrant restricted returns (uint256 usdgIn, uint256 burned) {
        if (paused) revert V2Errors.TradingPaused();
        uint256 reserve = buybackBalance;
        if (reserve == 0 || buybackCap == 0) {
            emit BuybackSkipped(SKIP_EMPTY);
            return (0, 0);
        }
        if (lastBuybackAt != 0) {
            uint40 readyAt = lastBuybackAt + V2Constants.BUYBACK_COOLDOWN;
            if (block.timestamp < readyAt) revert V2Errors.CooldownActive(readyAt);
        }
        address exec = executor;
        address token = stonkhouse;
        if (exec == address(0) || token == address(0)) {
            emit BuybackSkipped(SKIP_NO_EXECUTOR);
            return (0, 0);
        }
        usdgIn = reserve < buybackCap ? reserve : buybackCap;
        // SEC-43. The counter says this USDG is here; the balance is what is actually here. Spending is the only
        // path that needs them to agree, so it is the only one that checks.
        if (IERC20(usdg).balanceOf(address(this)) < usdgIn) {
            emit BuybackSkipped(SKIP_SHORT_RESERVE);
            return (0, 0);
        }
        uint256 supplyBefore = IERC20(token).totalSupply();
        // F-05-08. `usdgIn` is what the executor is OFFERED, not what it spends. V4BuybackExecutor allows a v3
        // partial fill at the price limit and refunds the rest to this contract inside the same call, so debiting
        // the reserve by `usdgIn` wrote off USDG that had come back. The refund then looked like a fresh fee to
        // {_pendingUsdg} - `balanceOf(this) - buybackBalance` - and the next {distribute} split it, sending
        // `(BPS - burnBps)` of the protocol's own buyback money to the treasury as revenue.
        //
        // MEASURED, NOT REPORTED. The spend is this contract's own USDG balance delta across the call, so it holds
        // whatever a replaceable executor returns and whatever it does with the refund. A `spent` value added to the
        // executor's return tuple would be that third party's claim about itself, and the splitter would have to
        // reconcile it against this same balance anyway.
        uint256 usdgBefore = IERC20(usdg).balanceOf(address(this));
        IERC20(usdg).forceApprove(exec, usdgIn);
        uint256 tokenOut;
        (tokenOut, burned) = IBuybackExecutor(exec).execute(usdgIn, minTokenOut);
        IERC20(usdg).forceApprove(exec, 0);
        uint256 usdgAfter = IERC20(usdg).balanceOf(address(this));
        if (usdgAfter > usdgBefore) revert V2Errors.BadUnits();
        uint256 spent = usdgBefore - usdgAfter;
        if (spent > usdgIn) revert V2Errors.BadUnits();
        // THIS CHECK MUST BE ABLE TO FAIL. It is the only thing the splitter verifies about a REPLACEABLE
        // third-party executor, and `supplyBefore - totalSupply() != burned` could not: an executor that pulls the
        // approved USDG and reports `burned == 0` passed on `0 == 0`, burning nothing. Require a real burn. The
        // supply-increase case is named rather than left to panic on the subtraction.
        // WHAT THIS STILL DOES NOT PROVE, so the NatSpec does not claim it: that the USDG was spent on the token,
        // that the route was the pinned one, or that `burned` is proportionate to `usdgIn`.
        uint256 supplyAfter = IERC20(token).totalSupply();
        if (burned == 0 || supplyAfter > supplyBefore || supplyBefore - supplyAfter != burned) {
            revert V2Errors.BadUnits();
        }
        // The frozen return is documented as "USDG base units spent", and now it is.
        usdgIn = spent;
        buybackBalance = reserve - spent;
        lastBuybackAt = uint40(block.timestamp);
        // The event reports what was SPENT, which is what the reserve moved by, and it agrees with the executor's
        // own `Bought(usdgIn, usdgSpent, ...)`. Reporting the offered amount would overstate every partial fill in
        // any consumer that sums this field.
        emit BoughtBack(spent, tokenOut);
        emit Burned(burned);
    }

    /// @inheritdoc IFeeSplitter
    function setTreasury(address treasury_) external nonReentrant restricted {
        _setTreasury(treasury_);
    }

    /// @inheritdoc IFeeSplitter
    /// @dev F-05-06. {claimOrderBookFees} only ever calls the CURRENT book, and `OrderBook.claimOwed` pays
    ///      `owed[msg.sender]`, so only the splitter can collect the splitter's entry. Overwriting the pointer while
    ///      the old book still owed something therefore made that USDG unreachable by anyone, permanently and
    ///      silently. The old book is drained here, before the pointer moves.
    ///
    ///      IT DOES NOT REVERT ON FAILURE, deliberately. Refusing to repoint while `owed > 0` would let a dead or
    ///      reverting old book block migration forever, which is the worse end of the same problem. So both calls
    ///      are attempted inside `try`, and whatever could not be collected is named in {OrderBookFeesStranded}
    ///      with the book that still holds it. An operator reading logs alone can see that it happened and how much;
    ///      the alternative was for it to happen and say nothing.
    function setOrderBook(address orderBook_) external nonReentrant restricted {
        if (orderBook_.code.length == 0) revert V2Errors.NoSource();
        address previous = orderBook;
        if (previous != address(0) && previous != orderBook_) _drainOrderBook(previous);
        orderBook = orderBook_;
        emit OrderBookSet(orderBook_);
    }

    /// @inheritdoc IFeeSplitter
    function setRouter(address router_) external nonReentrant restricted {
        if (router_.code.length == 0) revert V2Errors.NoSource();
        router = router_;
        emit RouterSet(router_);
    }

    /// @inheritdoc IFeeSplitter
    function setBuybackExecutor(address executor_) external nonReentrant restricted {
        if (executor_.code.length == 0) revert V2Errors.NoSource();
        executor = executor_;
        emit BuybackExecutorSet(executor_);
    }

    /// @notice SettlementOracle used for the conversion floor (`trySpot`). TREASURY_ADMIN (24 h).
    /// @dev Not in the frozen IFeeSplitter; listed in `roles.v8.json` so it is not silent ADMIN.
    function setOracle(address oracle_) external nonReentrant restricted {
        if (oracle_.code.length == 0) revert V2Errors.NoSource();
        oracle = oracle_;
        emit SettlementOracleSet(oracle_);
    }

    /// @notice STONKHOUSE token whose total-supply delta {buyback} checks against `burned`. TREASURY_ADMIN (24 h).
    /// @dev Not in the frozen IFeeSplitter; listed in `roles.v8.json` so it is not silent ADMIN.
    function setToken(address stonkhouse_) external nonReentrant restricted {
        if (stonkhouse_.code.length == 0 || stonkhouse_ == usdg) revert V2Errors.UnsupportedAsset();
        stonkhouse = stonkhouse_;
        emit StonkhouseSet(stonkhouse_);
    }

    /// @inheritdoc IFeeSplitter
    function setBurnBps(uint16 burnBps_) external nonReentrant restricted {
        if (uint256(burnBps_) > V2Constants.BPS) revert V2Errors.CeilingExceeded();
        burnBps = burnBps_;
        emit BurnBpsSet(burnBps_);
    }

    /// @inheritdoc IFeeSplitter
    function setBuybackCap(uint256 perCallUsdg) external nonReentrant restricted {
        if (perCallUsdg > V2Constants.BUYBACK_CAP_CEIL) revert V2Errors.CeilingExceeded();
        buybackCap = perCallUsdg;
        emit BuybackCapSet(perCallUsdg);
    }

    /// @inheritdoc IFeeSplitter
    function setConversionSlippageBps(uint16 bps) external nonReentrant restricted {
        if (bps > V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS) revert V2Errors.CeilingExceeded();
        conversionSlippageBps = bps;
        emit ConversionSlippageBpsSet(bps);
    }

    /// @inheritdoc IFeeSplitter
    /// @dev Emits UNCONDITIONALLY, including when the stored value does not change. GUARDIAN runs at a zero
    ///      execution delay, so this call is never scheduled and the AccessManager writes no `OperationScheduled`
    ///      or `OperationExecuted` for it: this event is the entire on-chain record that a guardian acted. A
    ///      change-only emit would hide a repeated pause, which is exactly the signal an operator is watching for.
    function setPaused(bool paused_) external nonReentrant restricted {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @dev Best-effort collection of `book`'s `owed[splitter]`. Every external call is wrapped: a book that
    ///      reverts on `owed`, or pays less than it reported, must not stop a repoint. Anything left is emitted.
    function _drainOrderBook(address book) private {
        uint256 owed;
        try IOrderBook(book).owed(address(this)) returns (uint256 amount) {
            owed = amount;
        } catch {
            emit OrderBookFeesStranded(book, 0);
            return;
        }
        if (owed == 0) return;
        uint256 before = IERC20(usdg).balanceOf(address(this));
        try IOrderBook(book).claimOwed() {
            uint256 claimed = IERC20(usdg).balanceOf(address(this)) - before;
            if (claimed < owed) emit OrderBookFeesStranded(book, owed - claimed);
        } catch {
            emit OrderBookFeesStranded(book, owed);
        }
    }

    function _pendingUsdg() private view returns (uint256) {
        uint256 bal = IERC20(usdg).balanceOf(address(this));
        return bal > buybackBalance ? bal - buybackBalance : 0;
    }

    /// @dev Shared by the constructor and {setTreasury}, so the launch treasury is in the logs too.
    function _setTreasury(address treasury_) private {
        if (uint160(treasury_) <= 2 || treasury_ == address(this) || treasury_ == usdg) {
            revert V2Errors.NotAuthorized();
        }
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function _split(address asset, uint256 assetIn, uint256 amount) private {
        uint256 buybackAdded = amount * uint256(burnBps) / V2Constants.BPS;
        uint256 treasuryOut = amount - buybackAdded;
        buybackBalance += buybackAdded;
        if (treasuryOut != 0) {
            address to = treasury;
            uint256 before = IERC20(usdg).balanceOf(to);
            IERC20(usdg).safeTransfer(to, treasuryOut);
            if (IERC20(usdg).balanceOf(to) - before != treasuryOut) revert V2Errors.BadUnits();
        }
        emit Distributed(asset, assetIn, amount, treasuryOut, buybackAdded);
    }
}
