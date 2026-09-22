// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {EarnVault} from "../../../src/v2/periphery/earn/EarnVault.sol";
import {IEarnVenueAdapter} from "../../../src/v2/interfaces/IEarnVenueAdapter.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {MockEarnVenue} from "../../../src/v2/mocks/MockEarnVenue.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice The one thing this handler needs from whatever holds the vault's parked assets.
/// @dev DELIBERATELY NOT {IEarnVenueAdapter}. The adapter is the contract under test in the pre-T-241 break --
///      asking it for the position is how an invariant ends up agreeing with the bug. This is pointed at the
///      VENUE's own books: {MockEarnVenue} in the campaign, the ERC-4626 itself behind a {StockVenueAdapter}.
interface IVenueBooks {
    function totalAssets() external view returns (uint256);
}

/// @notice Drives {EarnVault} deposits, redemptions, queue service and venue movement for
///         {VaultNavRedemptionInvariantTest}, and MEASURES what each redeemer was actually paid against an
///         economic NAV this handler computes from primitives.
/// @dev WHY THE MEASUREMENT LIVES HERE AND NOT IN AN ASSERTION ON THE VAULT. The defect class this campaign
///      exists for is a check that cannot see its subject: `StockVenueAdapter.enabled` used to gate
///      {IEarnVenueAdapter.totalAssets}, so one `setEnabled(false)` on a FUNDED adapter erased the venue
///      balance from {EarnVault.totalAssets} -- and every assertion phrased against `vault.totalAssets()`
///      agreed with the vault, because both read the same blinded number. An invariant written that way
///      PASSES against the exact bug T-241 fixed.
///
///      So {economicNav} never calls `earn.totalAssets()` and never calls the ADAPTER. It reads:
///        - the vault's own USDG wallet balance,
///        - its free Clearinghouse ledger,
///        - the VENUE's own books, through the venue handle this handler was constructed with,
///        - minus {EarnVault.escrowedAssets}, which are queued depositors' money and not the pool's.
///      An adapter that lies about, hides, or gates its position changes `earn.totalAssets()` and does not
///      change this number. That difference is the whole point.
///
///      A CALL SUCCEEDING IS NOT THE EFFECT HAPPENING (the defect claude-18 named three times in one evening).
///      {redeem} returns `(0, id)` when it queues, and a queued redemption pays nothing -- so every leg here
///      keys off the MEASURED asset delta of the receiver, never off the call returning normally, and the
///      pro-rata comparison is made only when USDG actually moved.
///
///      THE HANDLER NEVER REVERTS: amounts are bounded and every protocol refusal is swallowed, so a revert
///      reaching the fuzzer under `fail-on-revert = true` is a bug in this file.
contract EarnNavHandler is Test {
    EarnVault internal immutable earn;
    Clearinghouse internal immutable ch;
    IERC20 internal immutable usdg;
    MockEarnVenue internal immutable venue;
    /// @dev Where {economicNav} reads the parked position from. Usually `venue` itself; behind an adapter it is
    ///      the ERC-4626 the adapter deposits into, whose `totalAssets` is that position because this fixture
    ///      gives the 4626 no other depositor.
    IVenueBooks internal immutable books;

    address internal immutable quoter;
    address[2] internal holders;

    /// @dev Series this campaign has written through the vault. Read directly off the Clearinghouse to answer
    ///      "is the vault short anything", which is the question {EarnVault.hasOpenShort} is supposed to answer
    ///      and the one a missed {onERC1155BatchReceived} record silently answers wrong.
    uint256[] internal seriesIds;

    /*//////////////////////////////////////////////////////////////
                            WHAT THE CAMPAIGN SAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Largest amount by which a redeemer was paid LESS than their pro-rata slice of economic NAV.
    uint256 public worstUnderpay;
    /// @notice Largest amount by which a redeemer was paid MORE than that slice.
    /// @dev BOTH DIRECTIONS ARE TRACKED DELIBERATELY. The criterion this row was imported with asked for an
    ///      upper bound only, and the pre-T-241 bug UNDERSTATED NAV -- so an upper-bound-only invariant would
    ///      have passed against the very defect it is meant to catch.
    uint256 public worstOverpay;
    /// @notice Redemptions that actually paid out, i.e. the population the two numbers above are measured over.
    uint256 public paidRedemptions;
    /// @notice Redemptions that queued instead of paying.
    uint256 public queuedRedemptions;
    /// @notice Deposits that minted shares immediately.
    uint256 public pricedDeposits;
    /// @notice Deposits that queued.
    uint256 public queuedDeposits;

    /// @notice Times the vault PRICED (minted or paid) while it was short something.
    /// @dev THE SECOND HALF OF THE PROPERTY, and the half that covers an uncounted short. While a series is
    ///      written the vault's collateral is locked and its economic value is not measurable -- that is why
    ///      T-184 queues at that boundary instead of pricing. This counter is incremented from a DIRECT
    ///      Clearinghouse read, NOT from {EarnVault.hasOpenShort}, which is what makes it an independent
    ///      instrument rather than a second copy of the thing under test: a short the vault has not recorded is
    ///      counted here even if the vault believes it is flat. T-257 fixed the case that made that matter --
    ///      `onERC1155BatchReceived` (`EarnVault.sol:811`) was `view` and did not call `_recordShort`, so a
    ///      batch-delivered short was invisible to the vault. KEEP THE DIRECT READ ANYWAY: an instrument that
    ///      asks the subject whether it is broken cannot fail.
    uint256 public pricedWhileShort;

    /// @notice T-OP-036. Legs of this handler entered while {isShort} was TRUE, and pricing events (deposit /
    ///         redeem / processQueue) EVALUATED while it was true -- attempts, not violations.
    /// @dev WHY THESE EXIST. {invariant_earnNeverPricesWhileShort} asserts `pricedWhileShort == 0`, and before
    ///      this row no leg of this handler could put the vault short: `isShort()` was false in every reachable
    ///      state, so the counter could not move and the invariant was green for the same reason a test with no
    ///      assertion is green. These two count the state being REACHED and the guarded path being TRIED in it.
    ///      A floor test asserts both are non-zero after a scripted sequence; without that floor the invariant is
    ///      unfalsifiable. Neither is an invariant subject: they are the campaign's own coverage instrument.
    uint256 public shortObservations;
    uint256 public evaluatedWhileShort;
    /// @notice Shorts this handler had the vault WRITE (its own AskWrite, filled by the counterparty) and CLOSE
    ///         (settled and redeemed to the vault). Leg coverage for the floor test.
    uint256 public shortsWritten;
    uint256 public shortsClosed;

    /// @dev The taker who fills the vault's own AskWrite. A funded, onboarded trader from the fixture
    ///      (`MakerBase.t.sol:147-150` onboards alice, bob, carol, mm), set once by the test contract.
    address public counterparty;

    constructor(
        EarnVault earn_,
        Clearinghouse ch_,
        IERC20 usdg_,
        MockEarnVenue venue_,
        address books_,
        address quoter_,
        address[2] memory holders_
    ) {
        earn = earn_;
        ch = ch_;
        usdg = usdg_;
        venue = venue_;
        books = IVenueBooks(books_);
        quoter = quoter_;
        holders = holders_;
    }

    /*//////////////////////////////////////////////////////////////
                               MEASUREMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool's economic value in USDG base units, computed WITHOUT asking the vault or the adapter.
    function economicNav() public view returns (uint256) {
        uint256 gross = usdg.balanceOf(address(earn)) + ch.free(address(earn), address(usdg)) + books.totalAssets();
        uint256 escrowed = earn.escrowedAssets();
        return gross > escrowed ? gross - escrowed : 0;
    }

    /// @notice True while the vault holds a short of ANY series this campaign created, read off the ledger.
    function isShort() public view returns (bool) {
        uint256 n = seriesIds.length;
        for (uint256 i; i < n; ++i) {
            if (ch.balanceOf(address(earn), V2Ids.shortIdOf(seriesIds[i])) != 0) return true;
        }
        return false;
    }

    /// @notice Series ids the campaign has had the vault write, for the test contract's own checks.
    function series() external view returns (uint256[] memory) {
        return seriesIds;
    }

    /// @notice Registers a series the vault may become short in. Called by the test fixture, not by the fuzzer.
    function trackSeries(uint256 longId) external {
        seriesIds.push(longId);
    }

    /// @notice Names the trader who fills the vault's asks. Called by the test fixture, not by the fuzzer.
    function setCounterparty(address who) external {
        counterparty = who;
    }

    /// @dev Records that a leg found the vault short, so the floor can tell "the state was reached" from "the
    ///      guarded path ran in it" -- the two facts the floor asserts separately (T-OP-036 forbidden fix (d)).
    function _observe(bool shortNow) private {
        if (shortNow) ++shortObservations;
    }

    /*//////////////////////////////////////////////////////////////
                                  LEGS
    //////////////////////////////////////////////////////////////*/

    /// @notice A holder deposits. Records whether the vault priced it or queued it.
    function deposit(uint8 who, uint256 assets) external {
        address holder = holders[who % 2];
        uint256 have = usdg.balanceOf(holder);
        if (have < 2) return;
        assets = bound(assets, 1, have);
        bool shortNow = isShort();
        _observe(shortNow);
        if (shortNow) ++evaluatedWhileShort;
        vm.prank(holder);
        try earn.deposit(assets, holder) returns (uint256 shares) {
            if (shares == 0) {
                ++queuedDeposits;
            } else {
                ++pricedDeposits;
                if (shortNow) ++pricedWhileShort;
            }
        } catch {}
    }

    /// @notice A holder redeems part of their position. THE CENTRAL LEG.
    /// @dev The comparison is made against the NAV and supply MEASURED IMMEDIATELY BEFORE the call, because
    ///      that is what the vault itself prices against (`owed = mulDiv(shares, totalAssets(), supply)`,
    ///      `EarnVault.sol:316`). Raising cash from the venue moves assets between two terms of `economicNav`
    ///      and does not move the total, so the number stays the right comparison after the call.
    function redeem(uint8 who, uint256 pctBps) external {
        address holder = holders[who % 2];
        uint256 balance = earn.balanceOf(holder);
        if (balance == 0) return;
        uint256 shares = Math.mulDiv(balance, bound(pctBps, 1, 10_000), 10_000);
        if (shares == 0) return;

        uint256 supplyBefore = earn.totalSupply();
        if (supplyBefore == 0) return;
        uint256 navBefore = economicNav();
        bool shortNow = isShort();
        _observe(shortNow);
        if (shortNow) ++evaluatedWhileShort;
        uint256 walletBefore = usdg.balanceOf(holder);

        vm.prank(holder);
        // THE POST-CALL WORK LIVES IN THE TRY BODY, not after a `catch { return; }`. A refusal must leave every
        // counter untouched, and this shape makes that structural rather than a thing to remember.
        try earn.redeem(shares, holder) {
            _recordRedemption(holder, shares, supplyBefore, navBefore, shortNow, walletBefore);
        } catch {}
    }

    /// @dev The measurement half of {redeem}: what the receiver's wallet actually gained, against the slice of
    ///      economic NAV those shares were worth at the moment the vault priced them.
    function _recordRedemption(
        address holder,
        uint256 shares,
        uint256 supplyBefore,
        uint256 navBefore,
        bool shortNow,
        uint256 walletBefore
    ) private {
        // MEASURED, NOT RETURNED. A queued redemption returns zero assets and pays nothing; an implementation
        // that paid the wrong account would also return the right number.
        uint256 paid = usdg.balanceOf(holder) - walletBefore;
        if (paid == 0) {
            ++queuedRedemptions;
            return;
        }
        ++paidRedemptions;
        if (shortNow) ++pricedWhileShort;

        uint256 owed = Math.mulDiv(shares, navBefore, supplyBefore);
        if (paid < owed) {
            uint256 d = owed - paid;
            if (d > worstUnderpay) worstUnderpay = d;
        } else {
            uint256 d = paid - owed;
            if (d > worstOverpay) worstOverpay = d;
        }
    }

    /// @notice Serves the queue. Permissionless on the vault, so it is permissionless here too.
    /// @dev Queue service PRICES: `processQueue` values every entry at the share price of that moment
    ///      (`EarnVault.sol:355`), which is why it counts towards {pricedWhileShort}.
    function processQueue(uint256 maxEntries) external {
        (uint256 head, uint256 tail) = earn.queue();
        if (head > tail) return;
        bool shortNow = isShort();
        _observe(shortNow);
        if (shortNow) ++evaluatedWhileShort;
        try earn.processQueue(bound(maxEntries, 1, 8)) returns (uint256 served) {
            if (served != 0 && shortNow) ++pricedWhileShort;
        } catch {}
    }

    /// @notice Idle assets move out to the venue.
    function sweepToVenue(uint256 assets) external {
        uint256 wallet = usdg.balanceOf(address(earn));
        if (wallet == 0) return;
        assets = bound(assets, 1, wallet);
        vm.prank(quoter);
        try earn.sweepToVenue(assets) {} catch {}
    }

    /// @notice Assets come back from the venue.
    function pullFromVenue(uint256 assets) external {
        uint256 held = venue.totalAssets();
        if (held == 0) return;
        assets = bound(assets, 1, held);
        vm.prank(quoter);
        try earn.pullFromVenue(assets) {} catch {}
    }

    /// @notice The venue earns. A gain belongs to every holder pro rata and must show up in what a redeemer is paid.
    /// @dev {MockEarnVenue.addYield} PULLS from its caller, so the yield is funded onto this handler and approved
    ///      here rather than dealt straight onto the venue -- dealing would raise the venue's token balance without
    ///      raising `held`, which is a different (and untrue) state.
    function venueGains(uint256 amount) external {
        if (venue.totalAssets() == 0) return;
        amount = bound(amount, 1, 1_000e6);
        deal(address(usdg), address(this), amount);
        usdg.approve(address(venue), amount);
        venue.addYield(amount);
    }

    /// @notice The venue takes a loss. Symmetric with {venueGains}: it lowers the share price for everyone.
    function venueLoses(uint256 amount) external {
        uint256 held = venue.totalAssets();
        if (held == 0) return;
        venue.loseAssets(bound(amount, 1, held));
    }

    /// @notice The venue cannot pay out in this block, which is the state that turns a redemption into a queue entry.
    function venueGoesIlliquid(bool frozen) external {
        venue.setFrozen(frozen);
    }

    /*//////////////////////////////////////////////////////////////
                    T-OP-036: THE VAULT GOES SHORT, AND FLAT AGAIN
    //////////////////////////////////////////////////////////////*/

    /// @notice The vault WRITES: its quoter rests an AskWrite on a tracked series and the counterparty fills it, so
    ///         the book mints the short to the vault and {isShort} becomes true THROUGH THE VAULT'S OWN PATH.
    /// @dev THE SHORT ARRIVES THE WAY IT ARRIVES IN PRODUCTION. Forbidden fix (a) of T-OP-036 is `vm.prank`-minting
    ///      a short into the vault from here: that bypasses the escrow, {EarnVault._trackSeries} and the ERC-1155
    ///      hook that records it -- the accounting the invariant protects -- and manufactures a state the contract
    ///      cannot enter. This leg mirrors `EarnVault.t.sol:459-472` (`_fundVault` + `_vaultWritesAPut`) exactly:
    ///      QUOTER parks USDG collateral on the Clearinghouse, QUOTER places the AskWrite, a trader takes it.
    ///      The grants are the fixture's: `_grant(V8Roles.QUOTER, quoter, 0)` at `EarnVault.t.sol:53`, and the
    ///      counterparty is one of the four traders `MakerBase.t.sol:147-150` onboards with collateral and every
    ///      book approval.
    ///      PRICE. {EarnVault._checkPrice} (`EarnVault.sol:1359-1385`) floors an ask at the series' intrinsic value
    ///      grossed up for the seller fee, and both tracked series are at or out of the money at the fixture spot,
    ///      so any tick-aligned price clears it; the unit fixture's WRITE_PRICE (ten ticks) is used unchanged.
    ///      SIZE. Bounded well inside {EarnVault.MAX_SERIES_UNITS} and the notional ceiling so a refusal here is
    ///      the vault's decision, not this handler tripping a compiled bound.
    function writeAnAsk(uint256 which, uint64 units) external {
        uint256 n = seriesIds.length;
        if (n == 0 || counterparty == address(0)) return;
        uint256 longId = seriesIds[which % n];
        V2Types.Series memory s = ch.series(longId);
        if (s.underlying == address(0) || s.settled || block.timestamp >= s.expiry) return;
        units = uint64(bound(units, 1, 500));

        // Collateral for the write: the vault's free ledger must cover `units * collateralPerUnit`. Topped up
        // from the wallet by the vault's own QUOTER path; a wallet too thin to cover it is a legitimate refusal.
        uint256 need = uint256(units) * ch.collateralPerUnit(longId);
        uint256 free = ch.free(address(earn), address(usdg));
        if (free < need) {
            uint256 wallet = usdg.balanceOf(address(earn));
            if (wallet == 0) return;
            uint256 top = need - free;
            if (top > wallet) top = wallet;
            vm.prank(quoter);
            try earn.depositToClearinghouse(address(usdg), top) {} catch {}
            if (ch.free(address(earn), address(usdg)) < need) return;
        }

        uint128 price = uint128(V2Constants.PRICE_TICK * 10);
        uint256 shortId = V2Ids.shortIdOf(longId);
        uint256 shortBefore = ch.balanceOf(address(earn), shortId);

        vm.prank(quoter);
        uint256 orderId;
        try earn.place(longId, V2Types.OrderKind.AskWrite, price, units, 0) returns (uint256 id) {
            orderId = id;
        } catch {
            return;
        }

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        // Read the book handle BEFORE the prank: `earn.orderBook()` is an external call and would consume it.
        IOrderBook book = earn.orderBook();
        vm.prank(counterparty);
        try book.take(
            V2Types.TakeParams({
                longId: longId,
                buying: true,
                orderIds: ids,
                units: units,
                minUnits: 0,
                limitPrice: price,
                writeToSell: false,
                recipient: counterparty,
                deadline: type(uint40).max,
                maxTotalFee: type(uint128).max
            })
        ) returns (
            uint64, uint256, uint256
        ) {}
            catch {}

        // MEASURED, NOT RETURNED: the short is the vault's ledger balance, read the same way {isShort} reads it.
        if (ch.balanceOf(address(earn), shortId) > shortBefore) ++shortsWritten;

        // Whatever the taker left resting is withdrawn so the vault's live-order ceiling
        // ({EarnVault.MAX_LIVE_ORDERS_PER_SERIES}) is not consumed by this leg over a long campaign.
        vm.prank(quoter);
        try earn.cancel(ids) {} catch {}
    }

    /// @notice The vault goes FLAT again the way it does in production: the series expires, its settlement price
    ///         is final, someone settles it and someone redeems the vault's short to the vault.
    /// @dev {EarnVault} has no close path of its own (it holds a short until it is redeemed -- see
    ///      {EarnVault.hasOpenShort}, which prunes against the ERC-1155 balance), so this is the only route back
    ///      to flat and it is the one `EarnVault.t.sol:978-985` (`_backToFlat`) drives. Every call is
    ///      permissionless: {Clearinghouse.settle} takes no role, and {Clearinghouse.redeem} accepts a third-party
    ///      caller unless the holder opted out, which the vault has not. The mock oracle is the series' own
    ///      (`ch.series(longId).oracle`), the same instance {HouseNavHandler.rollEpoch} finalizes, and it is
    ///      finalized here only if nobody has yet.
    ///      GATED ON {isShort}. This leg warps to expiry, which ends every tracked series for the rest of the run
    ///      (no more writes, and the House vault cannot take an expired series), so it moves the clock only when
    ///      there is a short to close. The floor test drives it deliberately after the House legs have run.
    function settleAndRedeemShort(uint256 which, uint256 price) external {
        uint256 n = seriesIds.length;
        if (n == 0 || !isShort()) return;
        uint256 longId = seriesIds[which % n];
        uint256 shortId = V2Ids.shortIdOf(longId);
        if (ch.balanceOf(address(earn), shortId) == 0) return;
        V2Types.Series memory s = ch.series(longId);
        if (s.underlying == address(0)) return;

        if (block.timestamp < s.expiry) vm.warp(s.expiry);
        MockSettlementOracle o = MockSettlementOracle(s.oracle);
        (V2Types.SettlementStatus status, uint256 final_) = o.settlementPrice(s.underlying, s.expiry);
        if (status != V2Types.SettlementStatus.Finalized || final_ == 0) {
            o.setSettlement(s.underlying, s.expiry, V2Types.SettlementStatus.Finalized, bound(price, 1e6, 1_000e6));
        }
        if (!s.settled) {
            try ch.settle(longId) returns (bool) {} catch {}
        }
        try ch.redeem(shortId, address(earn)) returns (uint256, bool) {} catch {}
        if (ch.balanceOf(address(earn), shortId) == 0) ++shortsClosed;
    }
}
