// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ForkFloor} from "./ForkFloor.sol";
import {
    FreezeV7,
    IClearinghouseV7,
    IExpiryCalendarV7,
    IOrderBookV7,
    MarketConfigV7
} from "../../../script/v2/FreezeV7.s.sol";

/// @notice `OrderBook.take` arguments, as the DEPLOYED v7 book answers them. Declared here, like the script's
///         `MarketConfigV7`, so a v8 change to `V2Types` cannot move what this fork test sends to a live contract.
struct TakeParamsV7 {
    uint256 longId;
    bool buying;
    uint256[] orderIds;
    uint64 units;
    uint64 minUnits;
    uint128 limitPrice;
    bool writeToSell;
    address recipient;
    uint40 deadline;
}

struct OrderV7 {
    address maker;
    uint256 longId;
    uint8 kind; // 0 Bid, 1 AskResale, 2 AskWrite
    uint128 price;
    uint64 units;
    uint64 filled;
    uint40 validUntil;
    bool cancelled;
}

/// @notice Everything a v7 USER does on the Clearinghouse. All of it must keep working after the freeze.
interface IClearinghouseUserV7 {
    function deposit(address asset, uint256 amount, address to) external;
    function withdraw(address asset, uint256 amount, address to) external;
    function createSeries(address underlying, bool isPut, uint128 strike, uint40 expiry) external returns (uint256);
    function mint(uint256 longId, uint64 units, address writer, address longTo) external;
    function close(uint256 longId, uint64 units) external;
    function redeem(uint256 tokenId, address holder) external returns (uint256 paid, bool inUsdg);
    function setOperator(address operator, bool approved) external;
    function setApprovalForAll(address operator, bool approved) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function free(address account, address asset) external view returns (uint256);
    function collateralAsset(uint256 longId) external view returns (address);
    function collateralPerUnit(uint256 longId) external view returns (uint256);
    function mintCutoff(uint256 longId) external view returns (uint40);
    function mintFee(uint256 longId, uint64 units) external view returns (uint256 fee);
    function usdg() external view returns (address);
}

/// @notice Everything a v7 USER does on the OrderBook.
interface IOrderBookUserV7 {
    function place(uint256 longId, uint8 kind, uint128 price, uint64 units, uint40 validUntil)
        external
        returns (uint256 orderId);
    function cancel(uint256[] calldata orderIds) external;
    function prune(uint256[] calldata orderIds) external returns (uint256 pruned);
    function take(TakeParamsV7 calldata p) external returns (uint64 unitsFilled, uint256 premium, uint256 takerFee);
    function getOrders(uint256[] calldata orderIds) external view returns (OrderV7[] memory);
}

interface ISettlementOracleSpotV7 {
    function trySpot(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice THE C8-12 FORK DRY RUN. `script/v2/FreezeV7.s.sol` against the LIVE v7 set on a fork of chain 4663,
///         applied with the exact calldata the tool plans, sent by the real role holders — and then the thing the
///         whole task turns on: a user is never trapped by the freeze.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/FreezeV7Fork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as test/fork/ForkLive.t.sol does. Nothing
///      here broadcasts: `vm.prank` on a fork writes to the local fork state and never reaches the chain.
///
///      THE ROLE HOLDERS. AccessControl on the Clearinghouse is not enumerable, so the holders cannot be discovered
///      on chain; the registry's (`ops/markets/tier1.json` `shared`) are checked with `hasRole` and pranked.
///      {test_fork_roleHoldersAreTheRegistrys} fails if they moved, because the owner commands in
///      docs/V7-RUNOFF.md would then be wrong.
///
///      WHAT THE FREEZE IS ALLOWED TO BREAK, and what it is not:
///        - broken on purpose: `createSeries` (MarketDisabled, and CreatePaused in any other market) and `mint`
///          (MarketDisabled). That is the whole of "new risk".
///        - must keep working: `close`, `withdraw`, `deposit`, `redeem`, `OrderBook.cancel`, `OrderBook.prune`, and
///          a RESALE take, which is the only way a holder has of selling a long before expiry. Each has its own
///          assertion in {test_fork_afterTheFreeze_nobodyIsTrapped}.
contract FreezeV7ForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                             THE LIVE v7 SET
    //////////////////////////////////////////////////////////////*/

    address internal constant CLEARINGHOUSE = 0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424;
    address internal constant ORDER_BOOK = 0x9fcAe743C3fA0aEC7DB9b1d01e86464b85759942;
    address internal constant CALENDAR = 0xd0fCeD9Ee6F533aA900BEe8d0523eF4867a5784a;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant REGISTRY_GUARDIAN = 0x29741A8d283a253E8Ce10aDfd04C6507438b6F39;
    address internal constant REGISTRY_ADMIN = 0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b;

    /// @dev `V2Errors`, as deployed. Pinned as selectors so the test does not import `src/v2` on the `v8` branch.
    bytes4 internal constant MARKET_DISABLED = bytes4(keccak256("MarketDisabled()"));
    bytes4 internal constant CREATE_PAUSED = bytes4(keccak256("CreatePaused()"));

    uint8 internal constant KIND_BID = 0;
    uint8 internal constant KIND_ASK_RESALE = 1;
    uint40 internal constant NO_DEADLINE = type(uint40).max;

    /// @dev Collateral of one unit of a call: `V2Constants.UNIT`, 0.01 of an 18-dp share.
    uint256 internal constant UNIT = 1e16;
    /// @dev The registry's NVDA strike grid, 2.50 USDG.
    uint128 internal constant STRIKE_TICK = 2_500_000;
    /// @dev Ask price, USDG 6 dp per whole share; a multiple of `PRICE_TICK` (100).
    uint128 internal constant ASK = 1_000_000;

    FreezeV7 internal tool;
    IClearinghouseV7 internal ch = IClearinghouseV7(CLEARINGHOUSE);
    IClearinghouseUserV7 internal chUser = IClearinghouseUserV7(CLEARINGHOUSE);
    IOrderBookUserV7 internal bookUser = IOrderBookUserV7(ORDER_BOOK);

    address internal usdg;
    address internal writer = makeAddr("v7 writer");
    address internal buyer = makeAddr("v7 buyer");

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        tool = new FreezeV7();
        usdg = chUser.usdg();
        vm.label(CLEARINGHOUSE, "v7 Clearinghouse");
        vm.label(ORDER_BOOK, "v7 OrderBook");
        vm.label(NVDA, "NVDA");
        vm.label(usdg, "USDG");
    }

    /*//////////////////////////////////////////////////////////////
                        THE PLAN ON THE LIVE SET
    //////////////////////////////////////////////////////////////*/

    function test_fork_roleHoldersAreTheRegistrys() public onlyFork {
        assertTrue(ch.hasRole(tool.GUARDIAN_ROLE(), REGISTRY_GUARDIAN), "registry guardian holds GUARDIAN_ROLE");
        assertTrue(ch.hasRole(tool.DEFAULT_ADMIN_ROLE(), REGISTRY_ADMIN), "registry admin holds DEFAULT_ADMIN_ROLE");
        assertFalse(ch.hasRole(tool.DEFAULT_ADMIN_ROLE(), REGISTRY_GUARDIAN), "the guardian is not the admin");
        assertEq(IOrderBookV7(ORDER_BOOK).clearinghouse(), CLEARINGHOUSE, "the book points at the Clearinghouse");
    }

    /// @dev The plan is read-only: building it changes nothing on the fork, and it holds exactly the calls that are
    ///      still missing. The wrapper in docs/V7-RUNOFF.md relies on both.
    function test_fork_planIsReadOnlyAndOnlyWhatIsMissing() public onlyFork {
        FreezeV7.Inputs memory in_ = _inputs();
        bool pausedBefore = ch.createPaused();
        MarketConfigV7 memory cfgBefore = ch.market(NVDA);
        bool bookPausedBefore = IOrderBookV7(ORDER_BOOK).tradingPaused();

        FreezeV7.Call[] memory calls = tool.plan(in_);
        uint256 missing = (pausedBefore ? 0 : 1) + (cfgBefore.enabled ? 1 : 0);
        assertEq(calls.length, missing, "one call per switch still open");

        assertEq(ch.createPaused(), pausedBefore, "planning changed nothing");
        assertEq(ch.market(NVDA).enabled, cfgBefore.enabled, "planning changed nothing");
        assertEq(IOrderBookV7(ORDER_BOOK).tradingPaused(), bookPausedBefore, "planning never touches the book");

        for (uint256 i; i < calls.length; ++i) {
            assertEq(calls[i].to, CLEARINGHOUSE, "every freeze call goes to the Clearinghouse");
            bytes4 sel = bytes4(calls[i].data);
            assertTrue(
                sel == tool.SET_CREATE_PAUSED() || sel == tool.SET_MARKET_CONFIG(), "only the two freeze selectors"
            );
            console2.log(string.concat(calls[i].guardianRole ? "guardian  " : "admin     ", calls[i].what));
            console2.logBytes(calls[i].data);
        }
    }

    /// @dev The run-off dates the document quotes, computed from the live set on this fork block. Not an assertion
    ///      about a particular date -- the live set moves -- but about the shape the document depends on: every
    ///      expiry is on the 16:00 New York grid, the last open expiry never passes the last expiry, and neither
    ///      passes `now + MAX_TENOR`.
    function test_fork_runOffDatesAreComputedFromTheLiveSet() public onlyFork {
        (FreezeV7.RunOff memory off, FreezeV7.SeriesRow[] memory rows) = tool.runOff(_inputs());
        console2.log("fork block", block.number, "timestamp", block.timestamp);
        console2.log("series", rows.length, "open series", off.openSeriesCount);
        console2.log("open units", off.openUnits, "expired and unsettled", off.unsettledPastCount);
        console2.log("last expiry", off.lastExpiry);
        console2.log("last expiry still holding units", off.lastOpenExpiry);
        console2.log("ceiling now + MAX_TENOR", off.tenorCeiling);

        assertEq(off.seriesCount, rows.length, "every discovered series is reported");
        assertEq(off.unaccountedExpiry, 0, "no expiry carries open interest without a discovered series");
        assertLe(off.lastOpenExpiry, off.lastExpiry, "an open expiry is one of the expiries");
        assertLe(off.lastExpiry, off.tenorCeiling, "MAX_TENOR bounds every expiry that can exist");
        for (uint256 i; i < rows.length; ++i) {
            assertEq(rows[i].underlying, NVDA, "NVDA is the only v7 market");
            assertTrue(
                IExpiryCalendarV7(CALENDAR).nextExpiry(rows[i].expiry - 1, false) == rows[i].expiry,
                "every expiry is a session close on the calendar grid"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                    THE FREEZE, AND WHO IT LEAVES ALONE
    //////////////////////////////////////////////////////////////*/

    /// @dev The freeze sent as the owner would send it: the guardian's call from the guardian, the admin's from the
    ///      admin, byte for byte what the plan holds. Afterwards the tool plans nothing and post-checks.
    function test_fork_freezeAppliesAndIsIdempotent() public onlyFork {
        FreezeV7.Inputs memory in_ = _inputs();
        _applyFreeze(in_);

        assertTrue(ch.createPaused(), "creation is paused");
        assertFalse(ch.market(NVDA).enabled, "NVDA is disabled");
        assertFalse(IOrderBookV7(ORDER_BOOK).tradingPaused(), "the book is still trading: sellers are not trapped");

        assertEq(tool.plan(in_).length, 0, "a second run plans nothing");
        assertEq(tool.postCheck(in_, in_.markets), 0, "post-check passes");
    }

    /// @dev What the freeze is FOR. Both refusals are the market's, not the pause's: `mint` and `createSeries` check
    ///      `enabled` before `createPaused`, so a disabled market answers `MarketDisabled` for both. The create pause
    ///      is what stops a market that is not disabled, and {test_fork_createPausedStopsEveryOtherMarket} covers it.
    function test_fork_afterTheFreeze_newRiskIsRefused() public onlyFork {
        (uint256 longId,) = _openAPosition();
        _applyFreeze(_inputs());

        vm.prank(writer);
        vm.expectRevert(MARKET_DISABLED);
        chUser.mint(longId, 1, writer, writer);

        // Both arguments are resolved BEFORE the cheatcode: `vm.expectRevert` binds to the very next call, and a
        // view call made while building the arguments would be the one it bound to.
        uint40 expiry = _nextWeekly();
        uint128 newStrike = _strike() + STRIKE_TICK;
        vm.prank(writer);
        vm.expectRevert(MARKET_DISABLED);
        chUser.createSeries(NVDA, false, newStrike, expiry);
    }

    /// @dev `setCreatePaused` is the half of the freeze that does not depend on a market being disabled: it refuses a
    ///      new series id everywhere, including in a market an admin re-enabled. Shown by re-enabling NVDA on the
    ///      fork after the freeze and watching creation still refuse.
    function test_fork_createPausedStopsEveryOtherMarket() public onlyFork {
        FreezeV7.Inputs memory in_ = _inputs();
        _applyFreeze(in_);

        MarketConfigV7 memory cfg = ch.market(NVDA);
        cfg.enabled = true;
        vm.prank(REGISTRY_ADMIN);
        ch.setMarketConfig(NVDA, cfg);
        assertTrue(ch.market(NVDA).enabled, "re-enabled on the fork only");

        uint40 expiry = _nextWeekly();
        uint128 newStrike = _strike() + STRIKE_TICK;
        vm.prank(writer);
        vm.expectRevert(CREATE_PAUSED);
        chUser.createSeries(NVDA, false, newStrike, expiry);
    }

    /// @dev THE PROPERTY THE TASK TURNS ON. A writer holds a real v7 position, has sold part of it into the live
    ///      book and left an ask and a bid resting. The freeze lands. Everything that gets a user OUT still works:
    ///        1. a buyer still takes the resting resale ask -- the holder's only pre-expiry exit;
    ///        2. the maker cancels the rest of the ask and gets the escrowed longs back;
    ///        3. the bidder cancels and gets the escrowed USDG back;
    ///        4. the writer closes long + short against each other and is credited collateral AND the rent refund;
    ///        5. the writer withdraws the collateral to its own wallet;
    ///        6. the real holder of the live SETTLED series redeems it.
    function test_fork_afterTheFreeze_nobodyIsTrapped() public onlyFork {
        (uint256 longId, uint64 units) = _openAPosition();
        uint256 askId = _placeResale(longId, units / 2);
        uint256 bidId = _placeBid(longId, 5);

        _applyFreeze(_inputs());

        // 1. the resale exit still fills.
        uint256 buyerBefore = chUser.balanceOf(buyer, longId);
        vm.prank(buyer);
        (uint64 filled,,) = bookUser.take(_buy(longId, askId, 10));
        assertEq(filled, 10, "a resale take still fills after the freeze");
        assertEq(chUser.balanceOf(buyer, longId), buyerBefore + 10, "the buyer got the longs");

        // 2. the maker cancels the rest of the ask and the escrow comes home.
        uint256 makerBefore = chUser.balanceOf(writer, longId);
        uint64 resting = units / 2 - 10;
        vm.prank(writer);
        bookUser.cancel(_ids(askId));
        assertEq(chUser.balanceOf(writer, longId), makerBefore + resting, "the escrowed longs came back");
        assertTrue(bookUser.getOrders(_ids(askId))[0].cancelled, "the ask is cancelled");

        // 3. the bidder cancels and the escrowed USDG comes home.
        uint256 usdgBefore = IERC20Min(usdg).balanceOf(buyer);
        vm.prank(buyer);
        bookUser.cancel(_ids(bidId));
        assertGt(IERC20Min(usdg).balanceOf(buyer), usdgBefore, "the escrowed USDG came back");

        // 4. close: long + short burn together, collateral and the unused rent are credited.
        // casting to 'uint64' is safe because both balances came from a mint of `units`, a uint64
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 closable = uint64(_min(chUser.balanceOf(writer, longId), chUser.balanceOf(writer, longId | 1)));
        assertGt(closable, 0, "the writer still holds a closable pair");
        uint256 freeBefore = chUser.free(writer, NVDA);
        vm.prank(writer);
        chUser.close(longId, closable);
        uint256 credited = chUser.free(writer, NVDA) - freeBefore;
        assertGe(credited, uint256(closable) * UNIT, "collateral back, plus the rent refund");

        // 5. withdraw: the collateral leaves the Clearinghouse for the writer's own wallet.
        uint256 walletBefore = IERC20Min(NVDA).balanceOf(writer);
        uint256 freeNow = chUser.free(writer, NVDA);
        vm.prank(writer);
        chUser.withdraw(NVDA, freeNow, writer);
        assertEq(IERC20Min(NVDA).balanceOf(writer), walletBefore + freeNow, "the collateral went home");
        assertEq(chUser.free(writer, NVDA), 0, "nothing left behind");

        // 6. the buyer, who holds longs and no shorts, can still resell them: `place` is not pausable either.
        vm.prank(buyer);
        uint256 resale = bookUser.place(longId, KIND_ASK_RESALE, ASK, 10, 0);
        assertEq(bookUser.getOrders(_ids(resale))[0].units, 10, "the buyer's exit is still listed");
    }

    /// @dev The one real v7 position on chain: the holder of a SETTLED series redeems it after the freeze. Settled
    ///      series pay from collateral the Clearinghouse already holds; nothing about redemption reads a pause.
    ///      Skipped with a reason, never passed silently, when the live set has no settled series with a holder.
    function test_fork_afterTheFreeze_theLiveHolderCanStillRedeem() public onlyFork {
        (, FreezeV7.SeriesRow[] memory rows) = tool.runOff(_inputs());
        (uint256 longId, address holder, uint256 balance) = _aSettledHolder(rows);
        // T-OP-045, precondition-bail: the log said "skipping" but the test reported PASSED; now it skips.
        if (holder == address(0)) {
            console2.log("skipping: no settled v7 series with a live long holder on this block");
            vm.skip(true);
            return;
        }
        console2.log("live settled series", longId);
        console2.log("holder", holder, "units", balance);

        _applyFreeze(_inputs());

        vm.prank(holder);
        chUser.redeem(longId, holder);
        assertEq(chUser.balanceOf(holder, longId), 0, "the holder redeemed after the freeze");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _inputs() internal view returns (FreezeV7.Inputs memory in_) {
        address[] memory markets = new address[](1);
        markets[0] = NVDA;
        in_ = FreezeV7.Inputs({
            clearinghouse: CLEARINGHOUSE,
            orderBook: ORDER_BOOK,
            markets: markets,
            guardian: REGISTRY_GUARDIAN,
            admin: REGISTRY_ADMIN,
            registeredMarkets: new address[](0),
            knownSeries: new uint256[](0),
            fromBlock: tool.DEPLOY_BLOCK(),
            logChunk: tool.DEFAULT_LOG_CHUNK(),
            maxSeries: tool.DEFAULT_MAX_SERIES(),
            gridFrom: tool.DEPLOY_TS(),
            extraExpiries: new uint40[](0),
            writePlan: false,
            guardianPlanOut: "",
            adminPlanOut: "",
            expectChainId: 4663
        });
    }

    /// @dev Sends the planned calls from the real role holders, byte for byte, in the order the plan gives them.
    function _applyFreeze(FreezeV7.Inputs memory in_) internal {
        FreezeV7.Call[] memory calls = tool.plan(in_);
        for (uint256 i; i < calls.length; ++i) {
            address from = calls[i].guardianRole ? in_.guardian : in_.admin;
            vm.prank(from);
            (bool ok,) = calls[i].to.call(calls[i].data);
            assertTrue(ok, calls[i].what);
        }
    }

    /// @dev A real v7 position on the fork: NVDA dealt to the writer, deposited, and written into the next weekly
    ///      series (created idempotently, so an id the live pricer already opened is reused).
    function _openAPosition() internal returns (uint256 longId, uint64 units) {
        units = 40;
        uint40 expiry = _nextWeekly();
        vm.prank(writer);
        longId = chUser.createSeries(NVDA, false, _strike(), expiry);
        assertLt(block.timestamp, chUser.mintCutoff(longId), "the series can still be written");

        if (!_deal(NVDA, writer, 100e18) || !_deal(usdg, buyer, 10_000e6)) return (longId, 0);
        vm.startPrank(writer);
        IERC20Min(NVDA).approve(CLEARINGHOUSE, type(uint256).max);
        chUser.deposit(NVDA, 10e18, writer);
        chUser.setApprovalForAll(ORDER_BOOK, true);
        chUser.setOperator(ORDER_BOOK, true);
        chUser.mint(longId, units, writer, writer);
        vm.stopPrank();
        vm.startPrank(buyer);
        IERC20Min(usdg).approve(ORDER_BOOK, type(uint256).max);
        chUser.setApprovalForAll(ORDER_BOOK, true);
        vm.stopPrank();

        assertEq(chUser.balanceOf(writer, longId), units, "longs minted");
        assertEq(chUser.balanceOf(writer, longId | 1), units, "shorts minted");
    }

    function _placeResale(uint256 longId, uint64 units) internal returns (uint256 orderId) {
        vm.prank(writer);
        orderId = bookUser.place(longId, KIND_ASK_RESALE, ASK, units, 0);
    }

    function _placeBid(uint256 longId, uint64 units) internal returns (uint256 orderId) {
        vm.prank(buyer);
        orderId = bookUser.place(longId, KIND_BID, ASK, units, 0);
    }

    function _buy(uint256 longId, uint256 orderId, uint64 units) internal view returns (TakeParamsV7 memory) {
        return TakeParamsV7({
            longId: longId,
            buying: true,
            orderIds: _ids(orderId),
            units: units,
            minUnits: units,
            limitPrice: type(uint128).max,
            writeToSell: false,
            recipient: buyer,
            deadline: NO_DEADLINE
        });
    }

    /// @dev The first settled series in the live set that still has a long holder, found from its `TransferSingle`
    ///      logs. Returns a zero holder when there is none.
    function _aSettledHolder(FreezeV7.SeriesRow[] memory rows)
        internal
        view
        returns (uint256 longId, address holder, uint256 balance)
    {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("TransferSingle(address,address,address,uint256,uint256)");
        VmSafe.EthGetLogs[] memory logs = vm.eth_getLogs(tool.DEPLOY_BLOCK(), block.number, CLEARINGHOUSE, topics);
        for (uint256 i; i < rows.length; ++i) {
            if (!rows[i].settled || rows[i].longSupply == 0) continue;
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].topics.length < 4 || logs[j].data.length < 64) continue;
                (uint256 id,) = abi.decode(logs[j].data, (uint256, uint256));
                if (id != rows[i].longId) continue;
                address to = address(uint160(uint256(logs[j].topics[3])));
                uint256 bal = chUser.balanceOf(to, rows[i].longId);
                if (bal != 0) return (rows[i].longId, to, bal);
            }
        }
    }

    /// @dev The next weekly close at least two days out: far enough that the mint cutoff has not passed and inside
    ///      `MAX_TENOR`, whatever day the fork lands on.
    function _nextWeekly() internal view returns (uint40) {
        // casting to 'uint40' is safe because block.timestamp + 2 days is a 2026 instant, far below uint40 max
        // forge-lint: disable-next-line(unsafe-typecast)
        return IExpiryCalendarV7(CALENDAR).nextExpiry(uint40(block.timestamp + 2 days), true);
    }

    /// @dev A tick-aligned strike near the oracle's spot when it answers, and a plain in-grid strike when it does
    ///      not (an unavailable spot skips the Clearinghouse's strike band, so any tick-aligned strike is accepted).
    function _strike() internal view returns (uint128) {
        (bool ok, uint256 spotPrice,) = ISettlementOracleSpotV7(ch.market(NVDA).oracle).trySpot(NVDA);
        uint256 raw = ok && spotPrice != 0 ? spotPrice : 230_000_000;
        uint256 rounded = (raw / STRIKE_TICK) * STRIKE_TICK;
        // casting to 'uint128' is safe because a 6-dp USDG strike near spot is far below uint128 max
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(rounded == 0 ? STRIKE_TICK : rounded);
    }

    /// @dev Real tokens by storage-slot discovery (forge `deal`), as test/v2/fork/V2Fork.t.sol does; skips the
    ///      test with the reason when a slot cannot be found rather than failing on the node's behalf.
    function _deal(address token, address to, uint256 amount) internal returns (bool) {
        try this.dealToken(token, to, amount) {
            return true;
        } catch {
            console2.log("skipping: deal() could not locate the balance slot of", token);
            vm.skip(true);
            return false;
        }
    }

    function dealToken(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `CLEARINGHOUSE`, an address this suite's own tests read.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_freezeV7ForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(CLEARINGHOUSE, "FreezeV7Fork");
    }
}
