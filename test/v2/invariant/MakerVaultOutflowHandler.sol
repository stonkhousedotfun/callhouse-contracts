// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";

/// @notice Drives a real MakerVault, OrderBook and Clearinghouse for {MakerVaultOutflowInvariantTest}: a compromised
///         QUOTER_ROLE key quoting and trading at any price the guards allow, three outsiders resting orders and
///         filling the vault's, a keeper pruning, USDG arriving from outside, the spot moving, and time passing —
///         all of it strictly BEFORE the series expire, so nothing settles and no redemption pays the vault.
/// @dev THE QUOTER IS THE ADVERSARY. Every action it takes is legal: bids at or under the bid cap, asks at or above
///      the intrinsic-value floor, takes in both directions, replaces up and down, cancels, closes, both ledger moves,
///      owed claims and syncs. The handler never reverts — it bounds every argument into the legal range and swallows
///      the protocol's own refusals (size caps, live-order caps, empty books, OutflowCapExceeded) with try/catch —
///      and counts what actually happened. {MakerVaultOutflowInvariantTest.test_handlerExercisesEveryLeg} drives one
///      scripted pass and asserts every counter moves, which is where the non-vacuity evidence lives: an invariant
///      run's state is rolled back between runs, so a per-run coverage assertion would only be a coin toss.
///
///      GHOSTS.
///        - {outsideInflow}: USDG that reached the vault WITHOUT a vault call — the admin's deposits and plain
///          transfers. It is on the left of the bound, because it is not the quoter's money to lose.
///        - {vaultOrderIds}: every order id the vault ever received from place or replace. The recoverable escrow is
///          summed from the BOOK over this list, never from {MakerVault.orderIdsOf}: the vault drops an order id from
///          its own list as soon as the order can no longer fill, while the book keeps the USDG until a cancel or a
///          prune, and reading the vault's list would make that escrow look lost.
///        - {clock}: the simulated time. Never read back from `block.timestamp`, which via_ir may fold to its first
///          value in a frame.
///
///      NO ADMIN QUOTING, NO ADMIN WITHDRAWAL. The admin is booked but never checked ({MakerVault} NatSpec), so an
///      admin quote would legitimately push `used` past the cap and an admin withdrawal would legitimately take USDG
///      out of the measure; both are covered by MakerVaultOutflowTest instead. Here the admin only deposits, so
///      `used <= maxDailyOutflow` is exact.
contract MakerVaultOutflowHandler is Test {
    /*//////////////////////////////////////////////////////////////
                                 WIRING
    //////////////////////////////////////////////////////////////*/

    Clearinghouse internal immutable ch;
    OrderBook internal immutable book;
    MakerVault internal immutable vault;
    MockERC20 internal immutable usdg;
    MockSettlementOracle internal immutable oracle;
    address internal immutable nvda;
    address internal immutable quoter;
    address internal immutable admin;
    address internal immutable keeper;
    address internal immutable funder;

    /// @dev The series the handler trades: the NVDA call, the NVDA put (USDG collateral, so its locked collateral is
    ///      part of the measure's recoverable side) and the TSLA call.
    uint256[3] internal series;
    address[3] internal outsiders;

    /*//////////////////////////////////////////////////////////////
                                CLOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice The simulated time; {start} is where the campaign began and {deadline} the instant it never passes.
    uint256 public clock;
    uint256 public immutable start;
    uint256 public immutable deadline;

    /*//////////////////////////////////////////////////////////////
                                GHOSTS
    //////////////////////////////////////////////////////////////*/

    /// @notice USDG that reached the vault without a vault call (admin deposits and plain transfers).
    uint256 public outsideInflow;
    /// @notice Every order id the vault ever got from {MakerVault.place} or {MakerVault.replace}.
    uint256[] public vaultOrderIds;
    /// @dev Every order id an outsider rested, so the quoter has something to trade against.
    uint256[] internal outsiderOrderIds;

    /// @notice How often each shape of thing actually happened.
    uint256 public bidsPlaced;
    uint256 public asksPlaced;
    uint256 public replaces;
    uint256 public buysFilled;
    uint256 public salesFilled;
    uint256 public vaultOrdersFilledByOutsiders;
    uint256 public cancels;
    uint256 public prunes;
    uint256 public closes;
    uint256 public capReverts;
    /// @notice The largest `used` the campaign ever reached.
    uint256 public peakUsed;

    constructor(
        Clearinghouse ch_,
        OrderBook book_,
        MakerVault vault_,
        MockERC20 usdg_,
        MockSettlementOracle oracle_,
        address nvda_,
        address[4] memory actors, // quoter, admin, keeper, funder
        address[3] memory outsiders_,
        uint256[3] memory series_,
        uint256 deadline_
    ) {
        ch = ch_;
        book = book_;
        vault = vault_;
        usdg = usdg_;
        oracle = oracle_;
        nvda = nvda_;
        (quoter, admin, keeper, funder) = (actors[0], actors[1], actors[2], actors[3]);
        outsiders = outsiders_;
        series = series_;
        clock = vm.getBlockTimestamp();
        start = clock;
        deadline = deadline_;
    }

    /// @dev Every action first moves the clock by `gap` seconds (0-30 min), never past {deadline}, so the campaign stays
    ///      before the mint cutoff and nothing ever settles.
    modifier tick(uint32 gap) {
        uint256 next = clock + (gap % 30 minutes);
        clock = next < deadline ? next : deadline;
        vm.warp(clock);
        _;
        uint256 used = _used();
        if (used > peakUsed) peakUsed = used;
    }

    /*//////////////////////////////////////////////////////////////
                         THE QUOTER'S ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Rests a bid at any price up to the bid cap.
    function quoterBid(uint32 gap, uint8 which, uint128 price, uint64 units, uint32 life) external tick(gap) {
        uint256 longId = _pick(which);
        uint256 cap = _bidCap(longId);
        if (cap < V2Constants.PRICE_TICK) return;
        price = _tick(bound(price, V2Constants.PRICE_TICK, cap));
        units = uint64(bound(units, 1, 10_000));
        vm.prank(quoter);
        try vault.place(longId, V2Types.OrderKind.Bid, price, units, _validUntil(life)) returns (uint256 id) {
            vaultOrderIds.push(id);
            ++bidsPlaced;
        } catch (bytes memory err) {
            _countCapRevert(err);
        }
    }

    /// @notice Rests a write-on-fill or resale ask at any price down to the intrinsic-value floor.
    function quoterAsk(uint32 gap, uint8 which, bool resale, uint128 price, uint64 units, uint32 life)
        external
        tick(gap)
    {
        uint256 longId = _pick(which);
        (bool ok, uint256 floorPrice) = _askFloor(longId);
        if (!ok) return;
        V2Types.OrderKind kind = resale ? V2Types.OrderKind.AskResale : V2Types.OrderKind.AskWrite;
        price = _tick(bound(price, floorPrice + V2Constants.PRICE_TICK, floorPrice + 40_000_000));
        units = uint64(bound(units, 1, 10_000));
        vm.prank(quoter);
        try vault.place(longId, kind, price, units, _validUntil(life)) returns (uint256 id) {
            vaultOrderIds.push(id);
            ++asksPlaced;
        } catch {}
    }

    /// @notice Replaces one of the vault's live orders up or down.
    function quoterReplace(uint32 gap, uint8 which, uint128 price, uint64 units) external tick(gap) {
        (uint256 id, V2Types.Order memory o) = _liveVaultOrder(which);
        if (id == 0) return;
        if (o.kind == V2Types.OrderKind.Bid) {
            uint256 cap = _bidCap(o.longId);
            if (cap < V2Constants.PRICE_TICK) return;
            price = _tick(bound(price, V2Constants.PRICE_TICK, cap));
        } else {
            (bool ok, uint256 floorPrice) = _askFloor(o.longId);
            if (!ok) return;
            price = _tick(bound(price, floorPrice + V2Constants.PRICE_TICK, floorPrice + 40_000_000));
        }
        units = uint64(bound(units, 1, 10_000));
        vm.prank(quoter);
        try vault.replace(id, price, units) returns (uint256 newId) {
            vaultOrderIds.push(newId);
            ++replaces;
        } catch (bytes memory err) {
            _countCapRevert(err);
        }
    }

    /// @notice Cancels one of the vault's orders. Never blocked by the cap, whatever it holds.
    function quoterCancel(uint32 gap, uint8 which) external tick(gap) {
        (uint256 id,) = _liveVaultOrder(which);
        if (id == 0) return;
        vm.prank(quoter);
        try vault.cancel(_one(id)) {
            ++cancels;
        } catch {}
    }

    /// @notice Buys an outsider's resting ask at any price up to the bid cap: the leg the cap exists to bound.
    function quoterBuy(uint32 gap, uint8 which, uint64 units) external tick(gap) {
        (uint256 id, V2Types.Order memory o) = _liveOutsiderOrder(which, false);
        if (id == 0) return;
        uint256 cap = _bidCap(o.longId);
        if (cap < o.price) return;
        units = uint64(bound(units, 1, o.units - o.filled));
        vm.prank(quoter);
        try vault.take(_params(o.longId, true, id, units, uint128(cap), false)) returns (
            uint64 filled, uint256, uint256
        ) {
            if (filled != 0) ++buysFilled;
        } catch (bytes memory err) {
            _countCapRevert(err);
        }
    }

    /// @notice Sells into an outsider's resting bid, from inventory or by writing on the spot.
    function quoterSell(uint32 gap, uint8 which, uint64 units, bool preferWrite) external tick(gap) {
        (uint256 id, V2Types.Order memory o, bool write) = _sellableOutsiderBid(which, preferWrite);
        if (id == 0) return;
        units = uint64(bound(units, 1, o.units - o.filled));
        // The bid's own price is at or above the ask floor, so it passes the guard and the book fills this order.
        vm.prank(quoter);
        try vault.take(_params(o.longId, false, id, units, o.price, write)) returns (uint64 filled, uint256, uint256) {
            if (filled != 0) ++salesFilled;
        } catch (bytes memory err) {
            _countCapRevert(err);
        }
    }

    /// @notice THE ATTACK, in one call: the c14/c21 round trip. A partner rests an ask at the vault's bid cap, the
    ///         vault buys it, the partner rests a bid at the ask floor (one tick while the series is out of the
    ///         money), the vault sells the longs straight back, and the partner closes its pair. Every leg passes
    ///         the price and size guards and the vault's exposure ends where it started; what moves is the
    ///         difference, and the outflow cap is the only thing that bounds repeating it.
    /// @dev Without this the campaign's buys and sells are drawn from the same price distribution and roughly
    ///      cancel, so the bound would never be approached and invariant 1 would have no teeth.
    function quoterDrainRoundTrip(uint32 gap, uint8 who, uint8 which, uint64 units) external tick(gap) {
        uint256 longId = _pick(which);
        uint256 cap = _bidCap(longId);
        (bool ok, uint256 floorPrice) = _askFloor(longId);
        if (cap < V2Constants.PRICE_TICK || !ok || floorPrice > cap) return;
        address partner = outsiders[who % outsiders.length];
        units = uint64(bound(units, 100, 10_000));

        uint128 high = _tick(cap);
        uint256 ask;
        vm.prank(partner);
        try book.place(longId, V2Types.OrderKind.AskWrite, high, units, 0) returns (uint256 id) {
            ask = id;
        } catch {
            return;
        }
        uint64 bought;
        vm.prank(quoter);
        try vault.take(_params(longId, true, ask, units, high, false)) returns (uint64 f, uint256, uint256) {
            bought = f;
            if (f != 0) ++buysFilled;
        } catch (bytes memory err) {
            _countCapRevert(err);
        }
        vm.prank(partner);
        try book.cancel(_one(ask)) {} catch {}
        if (bought == 0) return;

        uint128 low = _tickUp(floorPrice);
        uint256 bid;
        vm.prank(partner);
        try book.place(longId, V2Types.OrderKind.Bid, low, bought, 0) returns (uint256 id) {
            bid = id;
        } catch {
            return;
        }
        vm.prank(quoter);
        try vault.take(_params(longId, false, bid, bought, low, false)) returns (uint64 f, uint256, uint256) {
            if (f != 0) ++salesFilled;
        } catch (bytes memory err) {
            _countCapRevert(err);
        }
        uint256 longs = ch.balanceOf(partner, longId);
        uint256 shorts = ch.balanceOf(partner, V2Ids.shortIdOf(longId));
        uint256 pair = longs < shorts ? longs : shorts;
        if (pair != 0) {
            vm.prank(partner);
            try ch.close(longId, uint64(pair)) {} catch {}
        }
    }

    /// @notice Closes a long/short pair back into the vault's ledger. Never booked.
    function quoterClose(uint32 gap, uint8 which, uint64 units) external tick(gap) {
        uint256 longId = _pick(which);
        uint256 longs = ch.balanceOf(address(vault), longId);
        uint256 shorts = ch.balanceOf(address(vault), V2Ids.shortIdOf(longId));
        uint256 pair = longs < shorts ? longs : shorts;
        if (pair == 0) return;
        units = uint64(bound(units, 1, pair));
        vm.prank(quoter);
        try vault.close(longId, units) {
            ++closes;
        } catch {}
    }

    /// @notice Moves USDG or shares between the vault's wallet and its Clearinghouse ledger, and sweeps up owed and
    ///         stale bookkeeping. None of it is booked; all of it stays inside the recoverable side of the measure.
    function quoterLedger(uint32 gap, uint8 which, bool usdgSide, bool out, uint256 amount) external tick(gap) {
        address asset = usdgSide ? address(usdg) : nvda;
        vm.startPrank(quoter);
        if (out) {
            uint256 free = ch.free(address(vault), asset);
            if (free != 0) {
                try vault.withdrawFromClearinghouse(asset, bound(amount, 1, free)) {} catch {}
            }
        } else {
            uint256 wallet = MockERC20(asset).balanceOf(address(vault));
            if (wallet != 0) {
                try vault.depositToClearinghouse(asset, bound(amount, 1, wallet)) {} catch {}
            }
        }
        try vault.claimOwed() {} catch {}
        try vault.sync(_one(_pick(which))) {} catch {}
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    OUTSIDERS, KEEPERS AND THE WORLD
    //////////////////////////////////////////////////////////////*/

    /// @notice An outsider rests an order of its own for the vault to trade against.
    function outsiderQuote(uint32 gap, uint8 who, uint8 which, uint8 kind, uint128 price, uint64 units)
        external
        tick(gap)
    {
        price = _tick(bound(price, V2Constants.PRICE_TICK, 40_000_000));
        units = uint64(bound(units, 1, 10_000));
        vm.prank(outsiders[who % outsiders.length]);
        try book.place(_pick(which), V2Types.OrderKind(kind % 3), price, units, 0) returns (uint256 id) {
            outsiderOrderIds.push(id);
        } catch {}
    }

    /// @notice An outsider fills one of the vault's live orders between vault calls — the thing the cap must not be
    ///         able to credit, and the thing that turns a charged bid escrow into a position.
    function outsiderFillsVaultOrder(uint32 gap, uint8 who, uint8 which, uint64 units) external tick(gap) {
        (uint256 id, V2Types.Order memory o) = _liveVaultOrder(which);
        if (id == 0) return;
        address filler = outsiders[who % outsiders.length];
        units = uint64(bound(units, 1, o.units - o.filled));
        bool buying = o.kind != V2Types.OrderKind.Bid;
        uint128 limit = buying ? type(uint128).max : 1;
        vm.prank(filler);
        try book.take(_paramsFor(filler, o.longId, buying, id, units, limit, !buying && who % 3 == 0)) returns (
            uint64 filled, uint256, uint256
        ) {
            if (filled != 0) ++vaultOrdersFilledByOutsiders;
        } catch {}
    }

    /// @notice A keeper prunes the vault's expired orders. A pruned bid hands its escrow back with nothing booked,
    ///         which is the residual the design accepts: the charge stays until the bucket refills.
    function keeperPrunes(uint32 gap) external tick(gap) {
        uint256 n = vaultOrderIds.length;
        if (n == 0) return;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = vaultOrderIds[i];
        }
        vm.prank(keeper);
        try book.prune(ids) returns (uint256 pruned) {
            prunes += pruned;
        } catch {}
    }

    /// @notice USDG arrives from outside a vault call: an admin deposit or a plain transfer. Never a budget.
    function usdgArrivesFromOutside(uint32 gap, bool viaAdmin, uint256 amount) external tick(gap) {
        amount = bound(amount, 1e6, 50_000e6);
        address from = viaAdmin ? admin : funder;
        usdg.mint(from, amount);
        if (!viaAdmin) {
            vm.prank(from);
            usdg.transfer(address(vault), amount);
        } else {
            vm.startPrank(admin);
            usdg.approve(address(vault), amount);
            try vault.deposit(address(usdg), amount) {}
            catch {
                vm.stopPrank();
                return;
            }
            vm.stopPrank();
        }
        outsideInflow += amount;
    }

    /// @notice The spot moves, so the ask floor and the bid cap move with it and the quoter's legal range changes.
    function printsMove(uint32 gap, uint256 spot) external tick(gap) {
        oracle.setSpot(nvda, true, bound(spot, 150_000_000, 300_000_000), clock);
    }

    /*//////////////////////////////////////////////////////////////
                             THE MEASURE
    //////////////////////////////////////////////////////////////*/

    /// @notice What the vault could still get back, in USDG base units: its wallet, what the book owes it, its free
    ///         USDG ledger balance, the escrow the book still holds for its live bids, and the USDG collateral its
    ///         put shorts have locked.
    /// @dev The escrow term is summed from the BOOK over {vaultOrderIds}, not from {MakerVault.orderIdsOf} — see the
    ///      contract NatSpec. Long tokens the vault bought are deliberately NOT counted: buying worthless options at
    ///      the bid cap is precisely the loss the cap is there to bound.
    function recoverable() public view returns (uint256 total) {
        total = usdg.balanceOf(address(vault)) + book.owed(address(vault)) + ch.free(address(vault), address(usdg));
        uint256 n = vaultOrderIds.length;
        if (n != 0) {
            uint256[] memory ids = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                ids[i] = vaultOrderIds[i];
            }
            V2Types.Order[] memory orders = book.getOrders(ids);
            for (uint256 i; i < n; ++i) {
                V2Types.Order memory o = orders[i];
                if (o.kind != V2Types.OrderKind.Bid || o.cancelled || o.filled >= o.units) continue;
                total += uint256(o.price) * (o.units - o.filled) / V2Constants.UNITS_PER_SHARE;
            }
        }
        for (uint256 i; i < series.length; ++i) {
            V2Types.Series memory s = ch.series(series[i]);
            if (!s.isPut) continue;
            total += ch.balanceOf(address(vault), V2Ids.shortIdOf(series[i])) * s.strike / V2Constants.UNITS_PER_SHARE;
        }
    }

    /// @notice Seconds of simulated time the campaign has run.
    function elapsed() external view returns (uint256) {
        return clock - start;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _used() private view returns (uint256 used) {
        (used,) = vault.outflow();
    }

    function _pick(uint8 which) private view returns (uint256) {
        return series[which % series.length];
    }

    /// @dev 30 minutes to 6.5 hours of life, so orders expire inside a campaign and keeper prunes have work to do.
    function _validUntil(uint32 life) private view returns (uint40) {
        // casting to 'uint40' is safe: the clock never passes `deadline`, itself far below 2^40
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(clock + 30 minutes + (life % 6 hours));
    }

    function _tick(uint256 price) private pure returns (uint128) {
        uint256 rounded = price / V2Constants.PRICE_TICK * V2Constants.PRICE_TICK;
        // casting to 'uint128' is safe: every caller bounds `price` far below 2^128
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(rounded == 0 ? V2Constants.PRICE_TICK : rounded);
    }

    /// @dev The lowest tick multiple at or above `price`, and never below one tick: the cheapest ask the vault's own
    ///      price guard still accepts.
    function _tickUp(uint256 price) private pure returns (uint128) {
        uint256 rounded = (price + V2Constants.PRICE_TICK - 1) / V2Constants.PRICE_TICK * V2Constants.PRICE_TICK;
        // casting to 'uint128' is safe: every caller derives `price` from a bounded spot
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(rounded == 0 ? V2Constants.PRICE_TICK : rounded);
    }

    function _bidCap(uint256 longId) private view returns (uint256) {
        try vault.bidCap(longId) returns (uint256 c) {
            return c;
        } catch {
            return 0;
        }
    }

    function _askFloor(uint256 longId) private view returns (bool ok, uint256 floorPrice) {
        try vault.askFloor(longId) returns (uint256 f) {
            return (true, f);
        } catch {
            return (false, 0);
        }
    }

    /// @dev A live order of the vault's, starting from index `which`; id 0 when there is none.
    function _liveVaultOrder(uint8 which) private view returns (uint256, V2Types.Order memory empty) {
        uint256 n = vaultOrderIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = vaultOrderIds[(uint256(which) + i) % n];
            V2Types.Order memory o = book.getOrders(_one(id))[0];
            if (o.cancelled || o.filled >= o.units || clock >= o.validUntil) continue;
            return (id, o);
        }
        return (0, empty);
    }

    /// @dev A live order an outsider rests; `wantBid` picks the side. Id 0 when there is none.
    function _liveOutsiderOrder(uint8 which, bool wantBid) private view returns (uint256, V2Types.Order memory empty) {
        uint256 n = outsiderOrderIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = outsiderOrderIds[(uint256(which) + i) % n];
            V2Types.Order memory o = book.getOrders(_one(id))[0];
            if (o.cancelled || o.filled >= o.units || clock >= o.validUntil) continue;
            if (wantBid != (o.kind == V2Types.OrderKind.Bid)) continue;
            return (id, o);
        }
        return (0, empty);
    }

    /// @dev A live outsider bid the vault could actually sell into: priced at or above the ask floor, on a series the
    ///      vault either holds longs of or has the free collateral to write. `write` says which of the two the take
    ///      should use. Without this the sale leg almost never fills and the campaign would only ever exercise the
    ///      charging half of the cap.
    function _sellableOutsiderBid(uint8 which, bool preferWrite)
        private
        view
        returns (uint256, V2Types.Order memory empty, bool write)
    {
        uint256 n = outsiderOrderIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = outsiderOrderIds[(uint256(which) + i) % n];
            V2Types.Order memory o = book.getOrders(_one(id))[0];
            if (o.kind != V2Types.OrderKind.Bid || o.cancelled || o.filled >= o.units || clock >= o.validUntil) {
                continue;
            }
            (bool ok, uint256 floorPrice) = _askFloor(o.longId);
            if (!ok || o.price < floorPrice) continue;
            V2Types.Series memory s = ch.series(o.longId);
            bool hasLongs = ch.balanceOf(address(vault), o.longId) != 0;
            uint256 perUnit = s.isPut ? uint256(s.strike) / V2Constants.UNITS_PER_SHARE : V2Constants.UNIT;
            bool canWrite = ch.free(address(vault), s.isPut ? address(usdg) : s.underlying) >= perUnit;
            if (!hasLongs && !canWrite) continue;
            return (id, o, !hasLongs || (canWrite && preferWrite));
        }
        return (0, empty, false);
    }

    function _params(uint256 longId, bool buying, uint256 id, uint64 units, uint128 limit, bool writeToSell)
        private
        view
        returns (V2Types.TakeParams memory)
    {
        return _paramsFor(address(vault), longId, buying, id, units, limit, writeToSell);
    }

    function _paramsFor(
        address recipient,
        uint256 longId,
        bool buying,
        uint256 id,
        uint64 units,
        uint128 limit,
        bool writeToSell
    ) private view returns (V2Types.TakeParams memory) {
        return V2Types.TakeParams({
            longId: longId,
            buying: buying,
            orderIds: _one(id),
            units: units,
            minUnits: 0,
            limitPrice: limit,
            writeToSell: writeToSell,
            recipient: recipient,
            // casting to 'uint40' is safe: the clock never passes `deadline`, itself far below 2^40
            // forge-lint: disable-next-line(unsafe-typecast)
            deadline: uint40(clock + 1)
        });
    }

    function _one(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    /// @dev Counts a refusal that was the outflow cap's, so a campaign can show the cap actually bound something.
    function _countCapRevert(bytes memory err) private {
        if (err.length >= 4 && bytes4(err) == bytes4(keccak256("OutflowCapExceeded(uint256,uint256)"))) ++capReverts;
    }
}
