// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {HouseVault} from "../../../src/v2/periphery/house/HouseVault.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice Drives {HouseVault}'s request / boundary / claim cycle for {VaultNavRedemptionInvariantTest} and
///         measures, at each boundary and at each claim, what a leaver was actually paid against the pool they
///         were leaving.
/// @dev THE HOUSE VAULT PAYS IN TWO STEPS AND BOTH CAN BE WRONG INDEPENDENTLY, so both are measured:
///        1. THE BATCH, at {HouseVault.rollEpoch}: the withdrawing shares are burned and `owedUsdg` /
///           `owedStock` rise by the batch's pro-rata slice of the post-fee pool.
///        2. THE SLICE, at {HouseVault.claim}: each holder receives their share of that batch, floor-divided.
///      An error in (1) underpays every leaver in the epoch; an error in (2) underpays one of them. A single
///      end-to-end equality would hide which, and -- worse -- a rounding-only tolerance wide enough to cover
///      both steps at once is wide enough to hide a real defect in either.
///
///      THE EXPECTED NUMBER IS BUILT FROM PRIMITIVES, never from `house.nav()`. `_nav` is the function under
///      test; asking it what the answer should be is the check-cannot-see-its-subject failure this campaign
///      exists to catch. {poolValue} reads the wallet balances, the free Clearinghouse ledger and the two
///      reserve counters, and values the stock leg at the price the boundary actually used.
///
///      `_rates` IS PRIVATE, so the per-epoch batch numbers are recorded HERE, measured across the
///      {rollEpoch} call itself (the deltas of the two public `owed*` counters, and `pendingWithdrawShares`
///      read before). That is also the stronger measurement: it is what the contract DID, not what it stored.
///
///      THE HANDLER NEVER REVERTS: every argument is bounded and every protocol refusal is swallowed.
contract HouseNavHandler is Test {
    struct Batch {
        uint256 shares;
        uint256 usdg;
        uint256 stock;
        uint256 price;
        bool recorded;
    }

    /// @dev Everything read BEFORE a boundary, carried into the measurement in one value. Nine locals across a
    ///      `try` is how a handler hits stack-too-deep; a struct keeps it readable and keeps the pre-state and
    ///      the post-state visibly separate.
    struct Pre {
        uint64 epoch;
        uint256 supply;
        uint256 wShares;
        uint256 pool;
        uint256 owedUsdg;
        uint256 owedStock;
        uint256 splitterUsdg;
        uint256 price;
        bool notFlat;
    }

    HouseVault internal immutable house;
    Clearinghouse internal immutable ch;
    IERC20 internal immutable usdg;
    IERC20 internal immutable stock;
    MockSettlementOracle internal immutable oracle;
    address internal immutable splitter;

    address[2] internal holders;

    /// @dev What each boundary actually reserved, keyed by the epoch that closed.
    mapping(uint64 epoch => Batch) public batchOf;

    /*//////////////////////////////////////////////////////////////
                            WHAT THE CAMPAIGN SAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Largest shortfall, in USDG base units, of a withdrawal BATCH against its pro-rata slice of the pool.
    uint256 public worstBatchUnderpay;
    /// @notice Largest excess of a batch over that slice. Both directions: an over-payment is the remaining
    ///         holders being diluted, which is the same defect pointed the other way.
    uint256 public worstBatchOverpay;
    /// @notice Largest shortfall of an individual {claim} against its slice of the batch it belongs to.
    uint256 public worstClaimUnderpay;
    /// @notice Largest excess of an individual claim over that slice.
    uint256 public worstClaimOverpay;

    uint256 public boundariesPriced;
    uint256 public claimsPaid;

    /// @notice Boundaries that priced and LEFT an option of a tracked series in the vault, measured off the
    ///         Clearinghouse AFTER the boundary rather than off {HouseVault} bookkeeping.
    /// @dev THE PRECONDITION OF THE WHOLE VALUATION. `rollEpoch` values no option: it relies on `_requireFlat`
    ///      having proved there is none. If a boundary ever prices a non-flat vault, every number this handler
    ///      compares is meaningless -- so it is counted here instead of being assumed.
    ///      MEASURED AFTER THE CALL, NOT BEFORE (T-OP-036). This counter used to be fed from `pre.notFlat`, a read
    ///      taken before `rollEpoch`, and the first sequence that ever reached the state showed why that is the
    ///      wrong instrument: the boundary's own F10 step ({HouseVault._redeemSettled}, `HouseVault.sol:691-701`)
    ///      redeems every SETTLED tracked balance at its real worth and then prices, correctly -- so a vault that
    ///      holds a settled long at entry and is flat at exit is the designed path, and the pre-read called it a
    ///      violation. The post-read is also the stronger check: an UNSETTLED balance cannot survive `_requireFlat`
    ///      (`:704-713`), so a boundary that succeeds and leaves any tracked balance behind means either
    ///      `_requireFlat` walked past a live position or `_redeemSettled` skipped a settled one. Both are the
    ///      defect this counter exists for; neither was visible while the state was unreachable.
    uint256 public boundariesPricedWhileNotFlat;

    /// @notice T-OP-036. Legs entered while {holdsAnOption} was TRUE, and pricing events ({rollEpoch} / {claim})
    ///         EVALUATED while it was true -- attempts, not violations.
    /// @dev {invariant_houseNeverPricesWhileHoldingAnOption} asserts `boundariesPricedWhileNotFlat == 0`, and before
    ///      this row no leg here could put an option in the vault, so `holdsAnOption()` was false in every reachable
    ///      state and the counter could not move. These count the state being reached and the guarded path being
    ///      tried in it; the floor test asserts both. They are coverage instruments, not invariant subjects.
    uint256 public optionObservations;
    uint256 public evaluatedWhileHolding;
    /// @notice Longs the vault TOOK from the counterparty's ask and longs it SOLD back into the counterparty's bid,
    ///         both through {HouseVault.take}. Leg coverage for the floor test.
    uint256 public longsTaken;
    uint256 public longsSold;
    /// @notice Tracked series this handler settled after expiry so a boundary's {HouseVault._redeemSettled} can clear
    ///         the vault's balance -- the keeper's job in production, and without it a held option blocks every later
    ///         boundary for the rest of the run.
    uint256 public seriesSettled;

    /// @dev The maker on the other side of the vault's takes: rests the AskWrite the vault buys and the Bid it sells
    ///      into. A funded, onboarded trader from the fixture, set once by the test contract.
    address public counterparty;

    uint256[] internal seriesIds;

    constructor(
        HouseVault house_,
        Clearinghouse ch_,
        MockSettlementOracle oracle_,
        address splitter_,
        address[2] memory holders_
    ) {
        house = house_;
        ch = ch_;
        usdg = house_.usdg();
        stock = house_.underlying();
        oracle = oracle_;
        splitter = splitter_;
        holders = holders_;
    }

    /*//////////////////////////////////////////////////////////////
                               MEASUREMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool's value in USDG base units at `price`, computed without calling {HouseVault.nav}.
    /// @dev MIRRORS the contract's own exclusions because they are economically right, not because the contract
    ///      does them: queued deposits have not bought shares yet and reserved withdrawals have already left.
    ///      The saturating subtraction is deliberate for the same reason the contract's is -- the ledger can
    ///      exceed the wallet whenever the quoter has posted collateral.
    ///
    ///      THE POOL THE BATCH IS PRICED FROM IS THE ONE AFTER THE BOUNDARY'S OWN PRE-PRICING STEPS (T-OP-127).
    ///      {HouseVault.rollEpoch} runs `_redeemSettled()` (every settled tracked position is redeemed into the
    ///      wallet) and `orderBook.claimOwed()` (T-OP-073, the book-owed slice comes home) BEFORE it measures
    ///      `usdgPool` / `stockPool`, and this handler reads `Pre.pool` BEFORE the call. So two things the
    ///      contract will hold by the time it prices are invisible to a wallet-plus-ledger read: (1) a settled
    ///      but not yet redeemed option -- what it pays is `units x payoutPerUnit` of the payout asset
    ///      (`Clearinghouse._redeem`: calls in Stock, puts in USDG, net of the fee already), and (2) USDG the book
    ///      owes the vault (`orderBook.owed`), which `_nav` and `usdgPool` count for the same reason. Both are
    ///      added from PRIMITIVES here, never from `house.nav()`. The first was the T-OP-097 red: a batch priced
    ///      against a settled call's payout read as "overpaid" by exactly the leavers' pro-rata share of it
    ///      (11156719 at the reporter's boundary price of 600008141 on 18594281019939089 Stock base units).
    function poolValue(uint256 price) public view returns (uint256) {
        uint256 cash = usdg.balanceOf(address(house)) + ch.free(address(house), address(usdg))
            + house.orderBook().owed(address(house));
        uint256 held = stock.balanceOf(address(house)) + ch.free(address(house), address(stock));
        (uint256 settledCash, uint256 settledStock) = settledButUnredeemed();
        cash += settledCash;
        held += settledStock;
        uint256 reservedCash = house.pendingDepositUsdg() + house.owedUsdg();
        uint256 reservedStock = house.pendingDepositStock() + house.owedStock();
        cash = cash > reservedCash ? cash - reservedCash : 0;
        held = held > reservedStock ? held - reservedStock : 0;
        return cash + Math.mulDiv(held, price, 1e18);
    }

    /// @notice What `_redeemSettled` will deliver to the vault at the next boundary: for every tracked series that
    ///         is settled, the vault's long and short balances times that series' payout per unit, in the series'
    ///         payout asset (puts pay USDG, calls pay Stock). Read from {Clearinghouse.series} and `balanceOf`, the
    ///         same primitives `_redeem` multiplies (`owed = amount * s.longPayoutPerUnit`).
    function settledButUnredeemed() public view returns (uint256 cashUsdg, uint256 stockUnits) {
        for (uint256 i; i < seriesIds.length; ++i) {
            uint256 longId = seriesIds[i];
            V2Types.Series memory s = ch.series(longId);
            if (s.underlying == address(0) || !s.settled) continue;
            uint256 payout = ch.balanceOf(address(house), longId) * s.longPayoutPerUnit
                + ch.balanceOf(address(house), V2Ids.shortIdOf(longId)) * s.shortPayoutPerUnit;
            if (s.isPut) cashUsdg += payout;
            else stockUnits += payout;
        }
    }

    /// @notice True while the vault still holds any option of a tracked series, read off the ledger.
    function holdsAnOption() public view returns (bool) {
        uint256 n = seriesIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 longId = seriesIds[i];
            if (ch.balanceOf(address(house), longId) != 0) return true;
            if (ch.balanceOf(address(house), longId | 1) != 0) return true;
        }
        return false;
    }

    function trackSeries(uint256 longId) external {
        seriesIds.push(longId);
    }

    /*//////////////////////////////////////////////////////////////
                                  LEGS
    //////////////////////////////////////////////////////////////*/

    /// @notice A holder queues a deposit in one of the two assets.
    function requestDeposit(uint8 who, bool inUsdg, uint256 amount) external {
        address holder = holders[who % 2];
        IERC20 token = inUsdg ? usdg : stock;
        uint256 have = token.balanceOf(holder);
        if (have == 0) return;
        amount = bound(amount, 1, have);
        vm.prank(holder);
        try house.requestDeposit(address(token), amount) {} catch {}
    }

    /// @notice A holder queues an exit.
    function requestWithdraw(uint8 who, uint256 pctBps) external {
        address holder = holders[who % 2];
        uint256 balance = house.balanceOf(holder);
        if (balance == 0) return;
        uint256 shares = Math.mulDiv(balance, bound(pctBps, 1, 10_000), 10_000);
        if (shares == 0) return;
        vm.prank(holder);
        try house.requestWithdraw(shares) {} catch {}
    }

    /// @notice A holder changes their mind before the boundary.
    function cancelWithdraw(uint8 who) external {
        vm.prank(holders[who % 2]);
        try house.cancelWithdrawRequest() {} catch {}
    }

    /// @notice Closes the epoch, and measures what the boundary reserved for the leavers against the pool.
    /// @dev PERMISSIONLESS on the contract, so it is called from here with no prank. The price is finalized at
    ///      a bounded value first, because a boundary with no Finalized price is a refusal and not a valuation.
    function rollEpoch(uint256 price) external {
        uint40 end = house.epochEnd();
        price = bound(price, 1e6, 1_000e6);
        oracle.setSettlement(address(stock), end, V2Types.SettlementStatus.Finalized, price);
        if (block.timestamp < end) vm.warp(end);

        Pre memory pre = Pre({
            epoch: house.epochId(),
            supply: house.totalSupply(),
            wShares: house.pendingWithdrawShares(),
            pool: poolValue(price),
            owedUsdg: house.owedUsdg(),
            owedStock: house.owedStock(),
            splitterUsdg: usdg.balanceOf(splitter),
            price: price,
            notFlat: holdsAnOption()
        });
        if (pre.notFlat) {
            ++optionObservations;
            ++evaluatedWhileHolding;
        }

        // THE MEASUREMENT IS INSIDE THE TRY BODY, so a refused boundary leaves every counter untouched
        // structurally rather than by remembering to return.
        try house.rollEpoch() {
            _recordBoundary(pre);
        } catch {}
    }

    /// @dev What the boundary actually did, measured across the call: the two `owed*` deltas are the batch, and
    ///      the splitter delta is the performance fee. Both are read rather than recomputed -- recomputing the
    ///      fee here would re-implement {HouseVault} and agree with it about any shared mistake.
    function _recordBoundary(Pre memory pre) private {
        ++boundariesPriced;
        // Post-state, deliberately: see the counter's NatSpec. `pre.notFlat` still feeds the evaluation counter.
        if (holdsAnOption()) ++boundariesPricedWhileNotFlat;

        uint256 batchUsdg = house.owedUsdg() - pre.owedUsdg;
        uint256 batchStock = house.owedStock() - pre.owedStock;
        batchOf[pre.epoch] =
            Batch({shares: pre.wShares, usdg: batchUsdg, stock: batchStock, price: pre.price, recorded: true});

        if (pre.wShares == 0 || pre.supply == 0) return;

        uint256 fee = usdg.balanceOf(splitter) - pre.splitterUsdg;
        uint256 postFee = pre.pool > fee ? pre.pool - fee : 0;
        uint256 owed = Math.mulDiv(postFee, pre.wShares, pre.supply);
        uint256 paid = batchUsdg + Math.mulDiv(batchStock, pre.price, 1e18);

        if (paid < owed) {
            uint256 d = owed - paid;
            if (d > worstBatchUnderpay) worstBatchUnderpay = d;
        } else {
            uint256 d = paid - owed;
            if (d > worstBatchOverpay) worstBatchOverpay = d;
        }
    }

    /// @notice A holder collects whatever a past boundary decided for them.
    /// @dev MEASURED AT THE HOLDER'S WALLET. {claim} settles a deposit and a withdrawal in one call, and the
    ///      deposit leg moves shares rather than assets, so the two do not confuse each other here.
    function claim(uint8 who) external {
        address holder = holders[who % 2];
        HouseVault.WithdrawRequest memory w = _withdrawRequest(holder);
        Batch memory b = batchOf[w.epochId];

        uint256 usdgBefore = usdg.balanceOf(holder);
        uint256 stockBefore = stock.balanceOf(holder);
        if (holdsAnOption()) {
            ++optionObservations;
            ++evaluatedWhileHolding;
        }

        vm.prank(holder);
        try house.claim() {
            _recordClaim(holder, w.shares, b, usdgBefore, stockBefore);
        } catch {}
    }

    /// @dev The slice half: what this holder received against their share of the batch their request belonged
    ///      to. A claim that paid nothing but retired a request is ordinary (floor division at any boundary
    ///      above 1:1 produces it) and is not a shortfall, so it is skipped rather than counted as zero.
    function _recordClaim(
        address holder,
        uint256 requestShares,
        Batch memory b,
        uint256 usdgBefore,
        uint256 stockBefore
    ) private {
        uint256 gotUsdg = usdg.balanceOf(holder) - usdgBefore;
        uint256 gotStock = stock.balanceOf(holder) - stockBefore;
        if (gotUsdg == 0 && gotStock == 0) return;
        ++claimsPaid;

        // Only a matured request this handler saw priced can be compared; anything else is a deposit-leg claim,
        // which pays shares and not assets.
        if (!b.recorded || requestShares == 0 || b.shares == 0) return;

        uint256 owedUsdg_ = Math.mulDiv(b.usdg, requestShares, b.shares);
        uint256 owedStock_ = Math.mulDiv(b.stock, requestShares, b.shares);
        uint256 owed = owedUsdg_ + Math.mulDiv(owedStock_, b.price, 1e18);
        uint256 paid = gotUsdg + Math.mulDiv(gotStock, b.price, 1e18);

        if (paid < owed) {
            uint256 d = owed - paid;
            if (d > worstClaimUnderpay) worstClaimUnderpay = d;
        } else {
            uint256 d = paid - owed;
            if (d > worstClaimOverpay) worstClaimOverpay = d;
        }
    }

    /// @notice The vault's quoter parks collateral on the Clearinghouse ledger and takes it back.
    /// @dev NOT DECORATION. Both `_nav` and the withdrawal split add the free ledger to the wallet, and both
    ///      had to be rewritten (the saturating form) because posting collateral can make the reserves exceed
    ///      the wallet. This leg is what puts the campaign in that state.
    function moveCollateral(bool out, bool inUsdg, uint256 amount) external {
        IERC20 token = inUsdg ? usdg : stock;
        if (out) {
            uint256 wallet = token.balanceOf(address(house));
            if (wallet == 0) return;
            vm.prank(_quoter());
            try house.depositToClearinghouse(address(token), bound(amount, 1, wallet)) {} catch {}
        } else {
            uint256 free = ch.free(address(house), address(token));
            if (free == 0) return;
            vm.prank(_quoter());
            try house.withdrawFromClearinghouse(address(token), bound(amount, 1, free)) {} catch {}
        }
    }

    /*//////////////////////////////////////////////////////////////
                T-OP-036: THE VAULT HOLDS AN OPTION, AND LETS GO
    //////////////////////////////////////////////////////////////*/

    /// @notice The vault BUYS a long: the counterparty rests an AskWrite on a tracked series and the vault's quoter
    ///         takes it, so {holdsAnOption} becomes true through {HouseVault.take} -- the vault's own quoting path,
    ///         with its epoch guard, price check, self-deal refusal and exposure limits all in the way.
    /// @dev MIRRORS `HouseVaultEpoch.t.sol:1138-1154` (`_houseTakeOneLong`): `_place(mm, callId, WRITE, P3_00, 10)`
    ///      then `house.take(p)` as `quoter` with `recipient = address(house)`. Forbidden fix (a) of T-OP-036 --
    ///      minting into the vault with `ch.mint` under a prank -- would skip `_seriesInEpoch`, `_checkPrice`,
    ///      `_enforce` and `_trackSeries`, and manufacture a state the contract cannot enter.
    ///      GRANTS are the fixture's: QUOTER for `quoter` (`MakerBase.t.sol:131` grants it to `admin`, `V8Access.sol`
    ///      to the quoter holder), the vault as a Clearinghouse minter (`HouseVaultBase.t.sol:83-84`), and the vault
    ///      ARMED with a protocol account (`HouseVaultBase.t.sol:97-98`), without which {take} reverts `NoSource`.
    ///      REACHABLE ONLY INSIDE AN EPOCH THAT CONTAINS THE SERIES: at deploy `epochEnd` is the Friday before the
    ///      tracked series expire, so this leg refuses (BadExpiry, swallowed) until the first boundary has rolled,
    ///      and again after the series expire. That window is the fraction of states the floor test proves exists.
    function takeALong(uint256 which, uint64 units) external {
        uint256 n = seriesIds.length;
        if (n == 0 || counterparty == address(0) || quoterAddress == address(0)) return;
        uint256 longId = seriesIds[which % n];
        V2Types.Series memory s = ch.series(longId);
        if (s.underlying == address(0) || s.settled || block.timestamp >= s.expiry) return;
        if (s.expiry > house.epochEnd()) return;
        units = uint64(bound(units, 1, 50));

        uint128 price = 3_000_000; // P3_00: at-the-money time value inside {HouseVault._checkPrice}'s bid band
        IOrderBook book = house.orderBook();
        uint256 askId;
        vm.prank(counterparty);
        try book.place(longId, V2Types.OrderKind.AskWrite, price, units, 0) returns (uint256 id) {
            askId = id;
        } catch {
            return;
        }
        uint256[] memory ids = new uint256[](1);
        ids[0] = askId;

        uint256 before = ch.balanceOf(address(house), longId);
        vm.prank(quoterAddress);
        try house.take(_take(longId, ids, units, price, true)) returns (uint64, uint256, uint256) {} catch {}
        if (ch.balanceOf(address(house), longId) > before) ++longsTaken;

        // Withdraw whatever the vault left resting, so the counterparty's book stays clean for the next leg.
        vm.prank(counterparty);
        try book.cancel(ids) {} catch {}
    }

    /// @notice The vault SELLS a long it holds back into the counterparty's bid, through {HouseVault.take} with
    ///         `buying = false`. The pre-settlement way back to flat, so a boundary can price again.
    /// @dev The other release path -- `HouseVault.close` -- needs a matched long/short pair
    ///      (`HouseVaultEpoch.t.sol:169-186`) and the vault only holds longs here, so the resale is the one that
    ///      applies. `_checkPrice(s, buying = false, writeToSell = false, limit)` floors the ask at intrinsic value
    ///      grossed up for the resale fee, which is zero for an at-the-money series at the fixture spot.
    function sellTheLong(uint256 which, uint64 units) external {
        uint256 n = seriesIds.length;
        if (n == 0 || counterparty == address(0) || quoterAddress == address(0)) return;
        uint256 longId = seriesIds[which % n];
        uint256 held = ch.balanceOf(address(house), longId);
        if (held == 0) return;
        V2Types.Series memory s = ch.series(longId);
        if (s.settled || block.timestamp >= s.expiry || s.expiry > house.epochEnd()) return;
        units = uint64(bound(units, 1, held));

        uint128 price = 2_000_000; // P2_00
        IOrderBook book = house.orderBook();
        uint256 bidId;
        vm.prank(counterparty);
        try book.place(longId, V2Types.OrderKind.Bid, price, units, 0) returns (uint256 id) {
            bidId = id;
        } catch {
            return;
        }
        uint256[] memory ids = new uint256[](1);
        ids[0] = bidId;

        vm.prank(quoterAddress);
        try house.take(_take(longId, ids, units, price, false)) returns (uint64, uint256, uint256) {} catch {}
        if (ch.balanceOf(address(house), longId) < held) ++longsSold;

        vm.prank(counterparty);
        try book.cancel(ids) {} catch {}
    }

    /// @notice After expiry, settle a tracked series so the next boundary's {HouseVault._redeemSettled} can redeem
    ///         what the vault holds of it and {_requireFlat} can pass. The keeper's job in production.
    /// @dev Without this leg a long held across its expiry blocks EVERY later boundary (`_requireFlat` reverts
    ///      NotSettled on an unsettled tracked series, `HouseVault.sol:704-713`) and the campaign spends the rest of
    ///      the run doing nothing. {Clearinghouse.settle} is permissionless and needs the expiry's price Finalized on
    ///      the series' oracle -- which {rollEpoch} above already does whenever `epochEnd` is that expiry.
    function settleTracked(uint256 which, uint256 price) external {
        uint256 n = seriesIds.length;
        if (n == 0) return;
        uint256 longId = seriesIds[which % n];
        V2Types.Series memory s = ch.series(longId);
        if (s.underlying == address(0) || s.settled || block.timestamp < s.expiry) return;
        (V2Types.SettlementStatus status, uint256 final_) = oracle.settlementPrice(s.underlying, s.expiry);
        if (status != V2Types.SettlementStatus.Finalized || final_ == 0) {
            oracle.setSettlement(s.underlying, s.expiry, V2Types.SettlementStatus.Finalized, bound(price, 1e6, 1_000e6));
        }
        try ch.settle(longId) returns (bool advanced) {
            if (advanced) ++seriesSettled;
        } catch {}
    }

    /// @dev One take shape for both directions; `recipient` is the vault because {HouseVault.take} refuses anything
    ///      else (`HouseVault.sol:894`).
    function _take(uint256 longId, uint256[] memory ids, uint64 units, uint128 limit, bool buying)
        private
        view
        returns (V2Types.TakeParams memory)
    {
        return V2Types.TakeParams({
            longId: longId,
            buying: buying,
            orderIds: ids,
            units: units,
            minUnits: 0,
            limitPrice: limit,
            writeToSell: false,
            recipient: address(house),
            deadline: type(uint40).max,
            maxTotalFee: type(uint128).max
        });
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev The public mapping getter returns the struct's fields, not the struct, so it is rebuilt here.
    function _withdrawRequest(address holder) private view returns (HouseVault.WithdrawRequest memory w) {
        (uint64 epochId, uint256 shares) = house.withdrawRequestOf(holder);
        w = HouseVault.WithdrawRequest({epochId: epochId, shares: shares});
    }

    function _quoter() private view returns (address) {
        return quoterAddress;
    }

    /// @dev Set once by the fixture; the quoter is a role holder in the fixture's AccessManager, not a
    ///      property of the vault, so it cannot be read off the contract.
    address public quoterAddress;

    function setQuoter(address q) external {
        quoterAddress = q;
    }

    /// @notice Names the maker on the other side of the vault's takes. Called by the test fixture, not by the fuzzer.
    function setCounterparty(address who) external {
        counterparty = who;
    }
}
