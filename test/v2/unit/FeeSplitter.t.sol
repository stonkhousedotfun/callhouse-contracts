// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {FeeSplitter} from "../../../src/v2/periphery/FeeSplitter.sol";
import {IFeeSplitter} from "../../../src/v2/interfaces/IFeeSplitter.sol";
import {IPayoutRouter} from "../../../src/v2/interfaces/IPayoutRouter.sol";
import {IBuybackExecutor} from "../../../src/v2/interfaces/IBuybackExecutor.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";

contract MockSpot {
    bool public okFlag = true;
    uint256 public price = 100e6;

    function set(bool ok_, uint256 price_) external {
        okFlag = ok_;
        price = price_;
    }

    function trySpot(address) external view returns (bool, uint256, uint256) {
        return (okFlag, price, block.timestamp);
    }
}

contract MockBook {
    IERC20 public usdg;
    mapping(address => uint256) public owed;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function credit(address a, uint256 n) external {
        owed[a] = n;
    }

    function claimOwed() external {
        uint256 n = owed[msg.sender];
        owed[msg.sender] = 0;
        usdg.transfer(msg.sender, n);
    }
}

/// @dev Reports an `owed` it will not pay: `claimOwed` always reverts. A retired or broken book has to be
///      something {setOrderBook} can migrate AWAY from, so this double exists to prove the repoint still happens
///      and that the shortfall is named in a log rather than lost in silence.
contract DeadBook {
    mapping(address => uint256) public owed;

    function credit(address a, uint256 n) external {
        owed[a] = n;
    }

    function claimOwed() external pure {
        revert("dead");
    }
}

contract MockAdapter {
    IPayoutRouter.Venue public venue = IPayoutRouter.Venue.V3;
    uint16 public feeBps = 5;
    uint256 public quote = 100e6;
    bool public miss;
    /// @dev Most base units this route can take in ONE swap. 0 means unbounded, which is what every test that does
    ///      not care about depth wants. A real pool does not revert with a tidy message, but it does fail the swap,
    ///      and failing the swap is the whole of what the splitter can observe.
    uint256 public maxIn;
    MockERC20 public dollar;

    constructor(MockERC20 dollar_) {
        dollar = dollar_;
    }

    function setVenue(IPayoutRouter.Venue v) external {
        venue = v;
    }

    function setQuote(uint256 q) external {
        quote = q;
    }

    function setMiss(bool m) external {
        miss = m;
    }

    function setMaxIn(uint256 n) external {
        maxIn = n;
    }

    function routes(address) external view returns (IPayoutRouter.Route memory r) {
        r.venue = venue;
        r.feeBps = feeBps;
    }

    function routeFeeBps(address) external view returns (uint16) {
        return feeBps;
    }

    function swapToUsdg(address asset, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out) {
        if (maxIn != 0 && amountIn > maxIn) revert("depth");
        IERC20(asset).transferFrom(msg.sender, address(this), amountIn);
        if (miss) revert("floor");
        out = quote;
        require(out >= minOut, "min");
        dollar.transfer(to, out);
    }
}

contract MockExecutor is IBuybackExecutor {
    IERC20 public usdg;
    MockERC20 public token;
    address public splitter;
    uint256 public quote = 1e18;

    constructor(IERC20 usdg_, MockERC20 token_, address splitter_) {
        usdg = usdg_;
        token = token_;
        splitter = splitter_;
    }

    function execute(uint256 usdgIn, uint256 minTokenOut) external returns (uint256 tokenOut, uint256 burned) {
        require(msg.sender == splitter, "only splitter");
        usdg.transferFrom(msg.sender, address(this), usdgIn);
        tokenOut = quote;
        require(tokenOut >= minTokenOut, "min");
        uint256 before = token.totalSupply();
        token.burnFrom(address(this), tokenOut);
        burned = before - token.totalSupply();
    }
}

/// @dev Spends only part of what it is offered and refunds the rest INSIDE the call, which is exactly what
///      V4BuybackExecutor does on a v3 partial fill at the price limit. {MockExecutor} cannot express this - it
///      always spends the whole offer - so the accounting divergence had no double that could show it.
contract PartialFillExecutor is IBuybackExecutor {
    IERC20 public usdg;
    MockERC20 public token;
    address public splitter;
    uint256 public spend;
    uint256 public quote = 1e18;

    constructor(IERC20 usdg_, MockERC20 token_, address splitter_, uint256 spend_) {
        usdg = usdg_;
        token = token_;
        splitter = splitter_;
        spend = spend_;
    }

    function execute(uint256 usdgIn, uint256 minTokenOut) external returns (uint256 tokenOut, uint256 burned) {
        require(msg.sender == splitter, "only splitter");
        usdg.transferFrom(msg.sender, address(this), usdgIn);
        usdg.transfer(splitter, usdgIn - spend); // the refund arrives before this call returns
        tokenOut = quote;
        require(tokenOut >= minTokenOut, "min");
        uint256 before = token.totalSupply();
        token.burnFrom(address(this), tokenOut);
        burned = before - token.totalSupply();
    }
}

/// @dev Takes the approved USDG and burns NOTHING, reporting `burned == 0`. This is the SEC-18 executor: against
///      the old `supplyBefore - totalSupply() != burned` it passed on `0 == 0`, so the splitter's only check on a
///      replaceable third-party executor could not see its subject. {MockExecutor} cannot express this -- it always
///      burns what it bought -- so this is a separate double rather than a flag on that one.
contract PocketingExecutor is IBuybackExecutor {
    IERC20 public usdg;
    address public splitter;
    uint256 public quote = 1e18;

    constructor(IERC20 usdg_, address splitter_) {
        usdg = usdg_;
        splitter = splitter_;
    }

    function execute(uint256 usdgIn, uint256) external returns (uint256 tokenOut, uint256 burned) {
        require(msg.sender == splitter, "only splitter");
        usdg.transferFrom(msg.sender, address(this), usdgIn); // takes the money
        tokenOut = quote;
        burned = 0; // ...and reports a burn that never happened
    }
}

contract FeeSplitterTest is V8AccessTest {
    address internal holder = makeAddr("holder");
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockERC20 internal stonk;
    MockSpot internal spot;
    MockBook internal book;
    MockAdapter internal adapter;
    FeeSplitter internal splitter;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 6);
        nvda = new MockStockToken("NVDA", "NVDAx");
        stonk = new MockERC20("STONK", "STONK", 18);
        spot = new MockSpot();
        book = new MockBook(usdg);
        adapter = new MockAdapter(usdg);
        _deployManager();
        splitter = new FeeSplitter(address(manager), address(usdg), treasury, 5_000);
        _wire(address(splitter), "FeeSplitter", holder, 0);
        _grant(V8Roles.GUARDIAN, guardian, 0);
        vm.startPrank(holder);
        splitter.setOracle(address(spot));
        splitter.setRouter(address(adapter));
        splitter.setOrderBook(address(book));
        splitter.setToken(address(stonk));
        vm.stopPrank();
        usdg.mint(address(adapter), 1_000_000e6);
        usdg.mint(address(book), 1_000_000e6);
        nvda.mint(address(splitter), 1e18);
    }

    function test_launchSplitIsFiftyFifty() public {
        assertEq(splitter.burnBps(), 5_000);
        assertEq(uint256(splitter.burnBps()) * 2, V2Constants.BPS);
        assertEq(splitter.buybackCap(), 50_000_000, "launch cap is 50 USDG from V2Constants natspec");
        usdg.mint(address(splitter), 100e6);
        splitter.distribute(address(usdg));
        assertEq(usdg.balanceOf(treasury), 50e6);
        assertEq(splitter.buybackBalance(), 50e6);
    }

    function test_burnBpsZeroSendsAllToTreasury() public {
        vm.prank(holder);
        splitter.setBurnBps(0);
        usdg.mint(address(splitter), 80e6);
        splitter.distribute(address(usdg));
        assertEq(usdg.balanceOf(treasury), 80e6);
        assertEq(splitter.buybackBalance(), 0);
    }

    function test_burnBpsMaxSendsAllToBuyback() public {
        vm.prank(holder);
        splitter.setBurnBps(uint16(V2Constants.BPS));
        usdg.mint(address(splitter), 80e6);
        splitter.distribute(address(usdg));
        assertEq(usdg.balanceOf(treasury), 0);
        assertEq(splitter.buybackBalance(), 80e6);
    }

    function test_setBurnBpsAboveBpsReverts() public {
        vm.prank(holder);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        splitter.setBurnBps(uint16(V2Constants.BPS) + 1);
    }

    function test_setBurnBpsTimelock() public {
        address delayed = makeAddr("delayedFee");
        uint32 delay = V8Roles.FEE_MANAGER_DELAY;
        assertEq(uint256(delay), uint256(V2Constants.FEE_CHANGE_DELAY), "FEE_MANAGER delay is FEE_CHANGE_DELAY");
        _grant(V8Roles.FEE_MANAGER, delayed, delay);
        bytes memory data = abi.encodeCall(FeeSplitter.setBurnBps, (0));
        vm.prank(delayed);
        vm.expectRevert();
        splitter.setBurnBps(0);
        vm.prank(delayed);
        manager.schedule(address(splitter), data, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(delayed);
        splitter.setBurnBps(0);
        assertEq(splitter.burnBps(), 0);
    }

    function test_distributeStockPaysUnderOkSpotFloor() public {
        // 1e18 stock * 100e6 / 1e18 = 100e6; haircut 5 bps → minOut 99_950_000.
        adapter.setQuote(99_950_000);
        uint256 out = splitter.distribute(address(nvda));
        assertEq(out, 99_950_000);
        assertEq(usdg.balanceOf(treasury), 99_950_000 / 2);
        assertEq(splitter.buybackBalance(), 99_950_000 - 99_950_000 / 2);
        assertEq(nvda.balanceOf(address(splitter)), 0);
    }

    function test_okSpotFloorRefusalDoesNotDump() public {
        adapter.setMiss(true);
        vm.expectEmit(true, false, false, true);
        emit IFeeSplitter.DistributionSkipped(address(nvda), keccak256("BELOW_FLOOR"));
        uint256 out = splitter.distribute(address(nvda));
        assertEq(out, 0);
        assertEq(nvda.balanceOf(address(splitter)), 1e18, "stock is held, not dumped");
        assertEq(splitter.buybackBalance(), 0);
    }

    function test_noSpotSkips() public {
        spot.set(false, 0);
        vm.expectEmit(true, false, false, true);
        emit IFeeSplitter.DistributionSkipped(address(nvda), keccak256("NO_SPOT"));
        assertEq(splitter.distribute(address(nvda)), 0);
        assertEq(nvda.balanceOf(address(splitter)), 1e18);
    }

    function test_noRouteSkips() public {
        adapter.setVenue(IPayoutRouter.Venue.None);
        vm.expectEmit(true, false, false, true);
        emit IFeeSplitter.DistributionSkipped(address(nvda), keccak256("NO_ROUTE"));
        assertEq(splitter.distribute(address(nvda)), 0);
        assertEq(nvda.balanceOf(address(splitter)), 1e18);
    }

    function test_onlyTreasuryReceivesSplit() public {
        usdg.mint(address(splitter), 10e6);
        splitter.distribute(address(usdg));
        assertEq(usdg.balanceOf(treasury), 5e6);
        assertEq(usdg.balanceOf(holder), 0);
        assertEq(usdg.balanceOf(address(this)), 0);
    }

    function test_pauseStopsDistributeAndBuybackNotClaim() public {
        vm.prank(guardian);
        splitter.setPaused(true);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        splitter.distribute(address(usdg));
        vm.prank(holder);
        vm.expectRevert(V2Errors.TradingPaused.selector);
        splitter.buyback(0);
        book.credit(address(splitter), 7e6);
        assertEq(splitter.claimOrderBookFees(), 7e6);
        assertEq(usdg.balanceOf(address(splitter)), 7e6);
    }

    function test_strangerSetBurnBpsRevertsNotAuthorized() public {
        vm.prank(makeAddr("nope"));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        splitter.setBurnBps(0);
    }

    function test_buybackSpendsCapAndChecksSupplyDelta() public {
        MockExecutor exec = new MockExecutor(usdg, stonk, address(splitter));
        stonk.setSupplyController(address(exec), true);
        stonk.mint(address(exec), 100e18);
        vm.prank(holder);
        splitter.setBuybackExecutor(address(exec));
        usdg.mint(address(splitter), 200e6);
        vm.prank(holder);
        splitter.setBurnBps(uint16(V2Constants.BPS));
        splitter.distribute(address(usdg));
        assertEq(splitter.buybackBalance(), 200e6);
        vm.prank(holder);
        (uint256 spent,) = splitter.buyback(1);
        assertEq(spent, 50_000_000, "per-call cap");
        assertEq(splitter.buybackBalance(), 150e6);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.CooldownActive.selector, uint40(block.timestamp + 5 minutes)));
        splitter.buyback(1);
        vm.warp(block.timestamp + V2Constants.BUYBACK_COOLDOWN);
        vm.prank(holder);
        splitter.buyback(1);
        assertEq(splitter.buybackBalance(), 100e6);
    }

    function test_setBuybackCapAboveCeilReverts() public {
        vm.prank(holder);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        splitter.setBuybackCap(V2Constants.BUYBACK_CAP_CEIL + 1);
    }

    function test_buybackSkippedWithoutExecutor() public {
        usdg.mint(address(splitter), 10e6);
        vm.prank(holder);
        splitter.setBurnBps(uint16(V2Constants.BPS));
        splitter.distribute(address(usdg));
        vm.prank(holder);
        vm.expectEmit(false, false, false, true);
        emit IFeeSplitter.BuybackSkipped(keccak256("NO_EXECUTOR"));
        (uint256 spent,) = splitter.buyback(0);
        assertEq(spent, 0);
        assertEq(splitter.buybackBalance(), 10e6, "reserve is not consumed on skip");
    }

    /*//////////////////////////////////////////////////////////////
                     WIPED RESERVE (SEC-43)
    //////////////////////////////////////////////////////////////*/

    /// @dev SEC-43. `buybackBalance` is a counter; the USDG is chain state. The live USDG's issuer can burn a
    ///      holder's whole balance (`wipeFrozenAddress`), which MockERC20 mirrors, and the counter does not move with
    ///      it. The reserve is then unspendable. Before this row that showed up as an ERC-20 insufficient-balance
    ///      revert raised inside the executor's `transferFrom` -- a failure that names neither this contract nor the
    ///      cause. It now refuses as a skip that says which. The positive control comes first: the same setup buys
    ///      before the wipe, so the refusal afterwards is the wipe's and not the fixture's.
    function test_buyback_wipedReserveSkipsAsShortReserveInsteadOfFailingInTheExecutor() public {
        MockExecutor exec = new MockExecutor(usdg, stonk, address(splitter));
        stonk.setSupplyController(address(exec), true);
        stonk.mint(address(exec), 100e18);
        vm.prank(holder);
        splitter.setBuybackExecutor(address(exec));
        vm.prank(holder);
        splitter.setBurnBps(uint16(V2Constants.BPS));
        usdg.mint(address(splitter), 200e6);
        splitter.distribute(address(usdg));
        assertEq(splitter.buybackBalance(), 200e6, "the whole distribution is earmarked for the buyback");

        // Positive control: this buy works.
        vm.prank(holder);
        (uint256 spentBefore,) = splitter.buyback(1);
        assertEq(spentBefore, 50_000_000, "control: the per-call cap is spent while the USDG is there");
        assertEq(splitter.buybackBalance(), 150e6);
        uint40 lastAt = splitter.lastBuybackAt();
        vm.warp(block.timestamp + V2Constants.BUYBACK_COOLDOWN);

        // The issuer wipes the splitter. The counter does not move: that IS the desync.
        usdg.freeze(address(splitter));
        usdg.wipeFrozenAddress(address(splitter));
        usdg.unfreeze(address(splitter));
        assertEq(usdg.balanceOf(address(splitter)), 0, "the backing is gone");
        assertEq(splitter.buybackBalance(), 150e6, "the counter still claims 150 USDG");

        vm.expectEmit(false, false, false, true);
        emit IFeeSplitter.BuybackSkipped(keccak256("SHORT_RESERVE"));
        vm.prank(holder);
        (uint256 spent, uint256 burned) = splitter.buyback(1);
        assertEq(spent, 0, "nothing is spent");
        assertEq(burned, 0, "nothing is burned");
        assertEq(splitter.buybackBalance(), 150e6, "the counter is NOT written down: that is an economics decision");
        assertEq(splitter.lastBuybackAt(), lastAt, "a skip does not start a new cooldown");
        assertEq(usdg.allowance(address(splitter), address(exec)), 0, "no approval is left standing");
    }

    /// @dev SEC-43, the other half: the refusal is temporary and the contract heals itself. USDG arriving after the
    ///      wipe first makes the counter true again -- {_pendingUsdg} is `balance - buybackBalance`, so until the hole
    ///      is filled a {distribute} of USDG splits nothing and the treasury is paid nothing. That is the cost of not
    ///      writing the counter down, and it is pinned here so the trade-off is visible rather than discovered.
    function test_buyback_wipedReserveHealsFromIncomeBeforeTheTreasuryIsPaidAgain() public {
        MockExecutor exec = new MockExecutor(usdg, stonk, address(splitter));
        stonk.setSupplyController(address(exec), true);
        stonk.mint(address(exec), 100e18);
        vm.prank(holder);
        splitter.setBuybackExecutor(address(exec));
        vm.prank(holder);
        splitter.setBurnBps(uint16(V2Constants.BPS));
        usdg.mint(address(splitter), 150e6);
        splitter.distribute(address(usdg));
        usdg.freeze(address(splitter));
        usdg.wipeFrozenAddress(address(splitter));
        usdg.unfreeze(address(splitter));

        // Income exactly equal to the hole: the counter is true again, and none of it reaches the treasury.
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        usdg.mint(address(splitter), 150e6);
        assertEq(splitter.distribute(address(usdg)), 0, "nothing is pending while the balance only covers the counter");
        assertEq(usdg.balanceOf(treasury), treasuryBefore, "the treasury is paid nothing until the hole is filled");

        vm.prank(holder);
        (uint256 spent,) = splitter.buyback(1);
        assertEq(spent, 50_000_000, "the buyback resumes at the cap");
        assertEq(splitter.buybackBalance(), 100e6);

        // Income ABOVE the counter is split normally again.
        usdg.mint(address(splitter), 40e6);
        vm.prank(holder);
        splitter.setBurnBps(0);
        assertEq(splitter.distribute(address(usdg)), 40e6, "the surplus over the counter is pending again");
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, 40e6, "and reaches the treasury");
    }

    /*//////////////////////////////////////////////////////////////
                      OBSERVABILITY (T-75)

        Until T-75 not one of the ten restricted setters emitted anything, and the exported ABI could read back
        only `treasury`, `buybackBalance` and `lastBuybackAt`. Every test below asserts the PAYLOAD and the
        READ-BACK, never merely that a setter did not revert -- a setter that silently kept the old value would
        pass the second kind of test and fail every one of these.
    //////////////////////////////////////////////////////////////*/

    /// @dev Without the constructor emits, a reader holding only this contract's logs could not say what the
    ///      launch split or the launch cap ARE -- only what they were last changed to, which before any change
    ///      is nothing at all. Deleting either `emit` in the constructor fails here.
    ///
    ///      WHAT THIS TEST UNDERWRITES OFF CHAIN, AND WHERE IT STOPS (T-560). `ops/alerts.md` in the callhouse
    ///      repo tells an operator to re-run `cast logs` for `TreasurySet(address)` against a live splitter and
    ///      treat at least one row as a positive control, on the grounds that `_setTreasury` is called from the
    ///      constructor (`FeeSplitter.sol:65` -> `:380-385`). THIS TEST IS WHY THAT GROUND HOLDS: it proves the
    ///      genesis event is emitted. It proves nothing about whether the operator can still READ it.
    ///
    ///      That second half is a property of the NODE, not of this contract: an endpoint that has pruned past
    ///      the deploy block returns no rows, and the control then fails OPEN -- it reads as "your query is
    ///      broken" when the truth is "this node is short". Measured on chain 4663 while auditing the flywheel:
    ///      block 67,296,505 still serves its HEADER while `eth_call` at that block returns
    ///      `-32000 historical state is not available`. The fix is `--from-block <deployBlock>` on the operator
    ///      side and it is tracked as T-OP-009, because `ops/alerts.md` is a different repository and a fence
    ///      cannot cross one. Nothing addable to this file or to `FeeSplitter.sol` would close it.
    function test_constructorEmitsLaunchTreasuryBurnBpsAndCap() public {
        vm.recordLogs();
        FeeSplitter fresh = new FeeSplitter(address(manager), address(usdg), treasury, 3_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countFrom(logs, address(fresh), IFeeSplitter.TreasurySet.selector), 1, "one TreasurySet at birth");
        assertEq(_countFrom(logs, address(fresh), IFeeSplitter.BurnBpsSet.selector), 1, "one BurnBpsSet at birth");
        assertEq(_countFrom(logs, address(fresh), IFeeSplitter.BuybackCapSet.selector), 1, "one BuybackCapSet at birth");
        assertEq(
            _countFrom(logs, address(fresh), IFeeSplitter.PausedSet.selector),
            0,
            "no PausedSet at birth: false is the ABI default and needs no genesis event"
        );

        // The payloads say the launch values, and the views agree with the logs.
        assertEq(abi.decode(_dataFrom(logs, address(fresh), IFeeSplitter.BurnBpsSet.selector), (uint16)), 3_000);
        assertEq(
            abi.decode(_dataFrom(logs, address(fresh), IFeeSplitter.BuybackCapSet.selector), (uint256)), 50_000_000
        );
        assertEq(
            address(uint160(uint256(_topic1From(logs, address(fresh), IFeeSplitter.TreasurySet.selector)))),
            treasury,
            "TreasurySet carries the treasury as an indexed topic"
        );
        assertEq(fresh.burnBps(), 3_000);
        assertEq(fresh.buybackCap(), 50_000_000);
        assertEq(fresh.treasury(), treasury);
    }

    /// @dev Both directions, because an event emitted with a hardcoded `true` would satisfy a one-direction test,
    ///      and a `paused()` that returned a constant would satisfy a one-value test.
    function test_setPausedEmitsAndPausedViewTracksIt() public {
        assertFalse(splitter.paused(), "starts unpaused");

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.PausedSet(true);
        vm.prank(guardian);
        splitter.setPaused(true);
        assertTrue(splitter.paused(), "view reads back the pause");

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.PausedSet(false);
        vm.prank(guardian);
        splitter.setPaused(false);
        assertFalse(splitter.paused(), "view reads back the resume");
    }

    /// @dev THE ACCEPTANCE CRITERION, literally. GUARDIAN's execution delay is 0, so the pause is called directly
    ///      rather than scheduled and the AccessManager writes NO `OperationScheduled` / `OperationExecuted` for
    ///      it. This test asserts that: the manager emits nothing, and the splitter's own `PausedSet` is the
    ///      entire record. Reconstructing the state from the log alone is the point, so the value is decoded out
    ///      of the log rather than read from the view, and only then compared against the view.
    function test_pausedSplitterIsVisibleFromLogsAlone() public {
        vm.recordLogs();
        vm.prank(guardian);
        splitter.setPaused(true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 fromManager;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager)) ++fromManager;
        }
        assertEq(fromManager, 0, "the zero-delay guardian lane leaves NOTHING on the AccessManager");
        assertEq(
            _countFrom(logs, address(splitter), IFeeSplitter.PausedSet.selector),
            1,
            "exactly one PausedSet, and it is the only evidence that exists"
        );

        bool pausedPerTheLog = abi.decode(_dataFrom(logs, address(splitter), IFeeSplitter.PausedSet.selector), (bool));
        assertTrue(pausedPerTheLog, "a log-only reader concludes PAUSED");
        assertEq(pausedPerTheLog, splitter.paused(), "and chain state agrees with the log");
    }

    /// @dev THE RULE, NOT THE CODE. The setters emit unconditionally on purpose. If someone later "optimises"
    ///      them to emit only when the value changes, every other test in this file still passes -- and a
    ///      guardian re-pausing an already-paused splitter, or confirming a pause, becomes invisible again.
    ///      This is the test that fails when the rule is loosened in the permissive direction.
    function test_settersEmitEvenWhenTheStoredValueDoesNotChange() public {
        vm.prank(guardian);
        splitter.setPaused(true);

        // Read the current values BEFORE any prank: a `vm.prank` is consumed by the very next call, and an
        // argument that is itself a call would eat it.
        uint16 sameBps = splitter.burnBps();
        address sameRouter = splitter.router();

        vm.recordLogs();
        vm.prank(guardian);
        splitter.setPaused(true); // same value again
        vm.prank(holder);
        splitter.setBurnBps(sameBps); // same value again
        vm.prank(holder);
        splitter.setRouter(sameRouter); // same address again, set in setUp
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countFrom(logs, address(splitter), IFeeSplitter.PausedSet.selector), 1, "re-pause still logged");
        assertEq(_countFrom(logs, address(splitter), IFeeSplitter.BurnBpsSet.selector), 1, "re-set bps still logged");
        assertEq(_countFrom(logs, address(splitter), IFeeSplitter.RouterSet.selector), 1, "re-set router still logged");
        assertEq(splitter.burnBps(), sameBps, "and nothing moved");
        assertEq(splitter.router(), sameRouter);
        assertTrue(splitter.paused());
    }

    /// @dev The five address pointers. Each is moved OFF the value `setUp` gave it, so a getter hardwired to a
    ///      constructor argument or to a constant could not pass.
    function test_addressSettersEmitAndTheirViewsTrack() public {
        MockBook book2 = new MockBook(usdg);
        MockAdapter adapter2 = new MockAdapter(usdg);
        MockSpot spot2 = new MockSpot();
        MockERC20 stonk2 = new MockERC20("STONK2", "STONK2", 18);
        MockExecutor exec = new MockExecutor(usdg, stonk, address(splitter));

        assertTrue(splitter.orderBook() != address(book2) && splitter.router() != address(adapter2));

        vm.startPrank(holder);
        vm.expectEmit(address(splitter));
        emit IFeeSplitter.OrderBookSet(address(book2));
        splitter.setOrderBook(address(book2));

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.RouterSet(address(adapter2));
        splitter.setRouter(address(adapter2));

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.BuybackExecutorSet(address(exec));
        splitter.setBuybackExecutor(address(exec));

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.SettlementOracleSet(address(spot2));
        splitter.setOracle(address(spot2));

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.StonkhouseSet(address(stonk2));
        splitter.setToken(address(stonk2));

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.TreasurySet(address(0xBEEF));
        splitter.setTreasury(address(0xBEEF));
        vm.stopPrank();

        assertEq(splitter.orderBook(), address(book2), "orderBook() reads back");
        assertEq(splitter.router(), address(adapter2), "router() reads back");
        assertEq(
            splitter.executor(), address(exec), "executor() reads back -- named for the storage, not setBuybackExecutor"
        );
        assertEq(splitter.oracle(), address(spot2), "oracle() reads back");
        assertEq(splitter.stonkhouse(), address(stonk2), "stonkhouse() reads back");
        assertEq(splitter.treasury(), address(0xBEEF), "treasury() reads back");
    }

    /// @dev The three numeric dials, each set twice to different values so a constant getter cannot pass.
    function test_numericSettersEmitAndTheirViewsTrack() public {
        vm.startPrank(holder);
        vm.expectEmit(address(splitter));
        emit IFeeSplitter.BurnBpsSet(1_234);
        splitter.setBurnBps(1_234);
        assertEq(splitter.burnBps(), 1_234);

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.BurnBpsSet(9_876);
        splitter.setBurnBps(9_876);
        assertEq(splitter.burnBps(), 9_876, "second value proves the view is not the constructor argument");

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.BuybackCapSet(1);
        splitter.setBuybackCap(1);
        assertEq(splitter.buybackCap(), 1);

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.BuybackCapSet(V2Constants.BUYBACK_CAP_CEIL);
        splitter.setBuybackCap(V2Constants.BUYBACK_CAP_CEIL);
        assertEq(splitter.buybackCap(), V2Constants.BUYBACK_CAP_CEIL, "the ceiling itself is allowed");

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.ConversionSlippageBpsSet(7);
        splitter.setConversionSlippageBps(7);
        assertEq(splitter.conversionSlippageBps(), 7);

        vm.expectEmit(address(splitter));
        emit IFeeSplitter.ConversionSlippageBpsSet(uint16(V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS));
        splitter.setConversionSlippageBps(uint16(V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS));
        assertEq(splitter.conversionSlippageBps(), uint16(V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS));
        vm.stopPrank();
    }

    /// @dev `burnBps` has NO compiled bound (V3-D25), so redirecting the entire fee flow to the treasury is a
    ///      legal FEE_MANAGER action. Before T-75 that redirection showed up only as an `OperationScheduled`
    ///      naming a selector, with no way to read what the split had become. Here the event, the view and the
    ///      money all have to agree.
    function test_wholeFlowRedirectedToTreasuryIsReadableAndLogged() public {
        vm.expectEmit(address(splitter));
        emit IFeeSplitter.BurnBpsSet(0);
        vm.prank(holder);
        splitter.setBurnBps(0);
        assertEq(splitter.burnBps(), 0, "the new split is readable, not merely scheduled");

        usdg.mint(address(splitter), 40e6);
        splitter.distribute(address(usdg));
        assertEq(usdg.balanceOf(treasury), 40e6, "and the money went where the readable value said it would");
        assertEq(splitter.buybackBalance(), 0);
    }

    /// @dev On the real FEE_MANAGER lane the call is scheduled 48 h ahead. The event must mark the EXECUTION --
    ///      when the value actually changes -- not the scheduling, or a monitor would report a split that had
    ///      not happened yet.
    function test_delayedBurnBpsChangeEmitsOnExecutionNotOnSchedule() public {
        address delayed = makeAddr("delayedFeeObs");
        uint32 delay = V8Roles.FEE_MANAGER_DELAY;
        _grant(V8Roles.FEE_MANAGER, delayed, delay);
        bytes memory data = abi.encodeCall(FeeSplitter.setBurnBps, (2_500));

        vm.recordLogs();
        vm.prank(delayed);
        manager.schedule(address(splitter), data, 0);
        Vm.Log[] memory atSchedule = vm.getRecordedLogs();
        assertEq(
            _countFrom(atSchedule, address(splitter), IFeeSplitter.BurnBpsSet.selector), 0, "scheduling is not a change"
        );
        assertEq(splitter.burnBps(), 5_000, "and the value has not moved yet");

        vm.warp(block.timestamp + delay);
        vm.expectEmit(address(splitter));
        emit IFeeSplitter.BurnBpsSet(2_500);
        vm.prank(delayed);
        splitter.setBurnBps(2_500);
        assertEq(splitter.burnBps(), 2_500);
    }

    /*//////////////////////////////////////////////////////////////
                              LOG HELPERS
    //////////////////////////////////////////////////////////////*/

    function _countFrom(Vm.Log[] memory logs, address emitter, bytes32 topic0) private pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic0) ++n;
        }
    }

    function _dataFrom(Vm.Log[] memory logs, address emitter, bytes32 topic0) private pure returns (bytes memory) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic0) {
                return logs[i].data;
            }
        }
        revert("no such log");
    }

    function _topic1From(Vm.Log[] memory logs, address emitter, bytes32 topic0) private pure returns (bytes32) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 1 && logs[i].topics[0] == topic0) {
                return logs[i].topics[1];
            }
        }
        revert("no such indexed log");
    }

    /*//////////////////////////////////////////////////////////////
                    SEC-18: the burn check must be able to fail
    //////////////////////////////////////////////////////////////*/

    /// @notice SEC-18. An executor that pulls the spend and burns nothing is refused.
    /// @dev PROVE BY BREAKING: with the old single condition `supplyBefore - totalSupply() != burned` restored, this
    ///      call SUCCEEDS -- 0 == 0 -- the reserve is debited and the USDG sits in the executor, so
    ///      `vm.expectRevert` fails and every assertion below reads the looted state instead. The non-zero bound is
    ///      the only reason this test can pass.
    function test_buyback_executorThatPullsAndBurnsNothingIsRefused() public {
        PocketingExecutor exec = new PocketingExecutor(usdg, address(splitter));
        vm.prank(holder);
        splitter.setBuybackExecutor(address(exec));
        usdg.mint(address(splitter), 200e6);
        vm.prank(holder);
        splitter.setBurnBps(uint16(V2Constants.BPS));
        splitter.distribute(address(usdg));
        assertEq(splitter.buybackBalance(), 200e6, "the reserve the executor is trying to take");
        uint256 supplyBefore = stonk.totalSupply();

        vm.prank(holder);
        vm.expectRevert(V2Errors.BadUnits.selector);
        splitter.buyback(1);

        assertEq(splitter.buybackBalance(), 200e6, "reserve untouched");
        assertEq(usdg.balanceOf(address(exec)), 0, "the revert undoes the pull");
        assertEq(stonk.totalSupply(), supplyBefore, "and nothing was burned");
    }

    /*//////////////////////////////////////////////////////////////
                    T-428: DONATION LOCK AND REPOINTING
    //////////////////////////////////////////////////////////////*/

    /// @dev F-05-05. `distribute(address)` quotes the WHOLE balance, and a donation is an ordinary transfer nobody
    ///      can refuse or undo. Once the balance is larger than the route can clear in one swap, every call fails
    ///      the same way and the fees underneath are locked behind somebody else's tokens. The fix is that a caller
    ///      can name a piece the route CAN take, with no role and no delay, and the floor still applies to that
    ///      piece. PROVE BY BREAKING: restore whole-balance `assetIn` in `_distribute` and this test goes red on
    ///      the `distributeAmount` leg, because the swap of 1000e18 reverts exactly as the whole-balance call does.
    function test_donationDoesNotLockLegitimateFees() public {
        // 1e18 of real fee sits in the splitter from setUp. Anyone can push more.
        nvda.mint(address(splitter), 999e18);
        assertEq(nvda.balanceOf(address(splitter)), 1_000e18, "donation landed and cannot be refused");
        adapter.setMaxIn(2e18); // the route clears at most 2e18 in one swap
        adapter.setQuote(99_950_000); // exactly the floor for a 1e18 piece at spot 100e6 less 5 bps

        // The whole-balance path is what the donation broke: it quotes 1000e18, the swap fails, nothing moves.
        vm.recordLogs();
        uint256 blocked = splitter.distribute(address(nvda));
        assertEq(blocked, 0, "whole-balance conversion cannot clear the route");
        assertEq(nvda.balanceOf(address(splitter)), 1_000e18, "and nothing was converted");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool skipped;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IFeeSplitter.DistributionSkipped.selector) skipped = true;
        }
        assertTrue(skipped, "the failure is a skip, not a revert, so it repeats forever");

        // The remedy is permissionless: no role, no delay, no configuration. Progress is made.
        uint256 converted = splitter.distributeAmount(address(nvda), 1e18);
        assertEq(converted, 99_950_000, "the legitimate piece converted under the same floor");
        assertEq(nvda.balanceOf(address(splitter)), 999e18, "exactly the named piece left the splitter");
        assertEq(usdg.balanceOf(treasury), 99_950_000 / 2);
        assertEq(splitter.buybackBalance(), 99_950_000 - 99_950_000 / 2);
    }

    /// @dev The floor is computed on the piece actually being sold, so a partial conversion is protected exactly as
    ///      the whole balance was. Without this, "convert less" would be a way to sell under the oracle floor.
    function test_partialConversionStillHonoursTheFloor() public {
        nvda.mint(address(splitter), 999e18);
        adapter.setQuote(99_949_999); // one base unit under the floor for a 1e18 piece
        uint256 out = splitter.distributeAmount(address(nvda), 1e18);
        assertEq(out, 0, "a piece below the floor is skipped, not sold");
        assertEq(nvda.balanceOf(address(splitter)), 1_000e18, "and the tokens stay put");
    }

    function test_distributeAmountRejectsZeroAndOverBalance() public {
        // Read the balance BEFORE arming the cheatcode: `expectRevert` applies to the next call, and an argument
        // that is itself a call would consume it.
        uint256 tooMuch = nvda.balanceOf(address(splitter)) + 1;
        vm.expectRevert(V2Errors.BadUnits.selector);
        splitter.distributeAmount(address(nvda), 0);
        vm.expectRevert(V2Errors.BadUnits.selector);
        splitter.distributeAmount(address(nvda), tooMuch);
    }

    /// @dev USDG has no conversion, so it cannot be locked by a donation; the amount-taking entry point refuses it
    ///      rather than opening a second, partial path into the USDG split.
    function test_distributeAmountRefusesUsdg() public {
        usdg.mint(address(splitter), 10e6);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        splitter.distributeAmount(address(usdg), 1e6);
    }

    /// @dev F-05-06. `OrderBook.claimOwed` pays `owed[msg.sender]`, so only the splitter can collect the splitter's
    ///      entry, and {claimOrderBookFees} only ever calls the CURRENT book. Repointing used to make the old book's
    ///      owed unreachable by anyone, permanently and silently.
    function test_repointClaimsTheOldBooksOwed() public {
        book.credit(address(splitter), 25e6);
        MockBook next = new MockBook(usdg);
        usdg.mint(address(next), 1_000e6);
        uint256 before = usdg.balanceOf(address(splitter));

        vm.prank(holder);
        splitter.setOrderBook(address(next));

        assertEq(usdg.balanceOf(address(splitter)) - before, 25e6, "the old book's owed came with the repoint");
        assertEq(book.owed(address(splitter)), 0, "and is no longer stranded there");
        assertEq(splitter.orderBook(), address(next), "the pointer still moved");
    }

    /// @dev A dead old book must not be able to block migration forever - that is forbidden fix (d). The repoint
    ///      happens anyway and the shortfall is NAMED, so an operator reading logs alone can see what was left.
    function test_repointAwayFromADeadBookStillMigratesAndNamesTheShortfall() public {
        DeadBook dead = new DeadBook();
        dead.credit(address(splitter), 7e6);
        vm.prank(holder);
        splitter.setOrderBook(address(dead));

        MockBook next = new MockBook(usdg);
        vm.expectEmit(true, false, false, true, address(splitter));
        emit IFeeSplitter.OrderBookFeesStranded(address(dead), 7e6);
        vm.prank(holder);
        splitter.setOrderBook(address(next));
        assertEq(splitter.orderBook(), address(next), "migration is never blocked by the old book");
    }

    /// @dev Repointing to the same address must not try to drain the book it is about to keep.
    function test_repointToTheSameBookIsANoOp() public {
        book.credit(address(splitter), 11e6);
        vm.prank(holder);
        splitter.setOrderBook(address(book));
        assertEq(book.owed(address(splitter)), 11e6, "still claimable through claimOrderBookFees");
        assertEq(splitter.claimOrderBookFees(), 11e6);
    }

    /// @dev F-05-08, the report's own example: reserve 100, cap 50 so 50 is offered, the v3 leg consumes 45 and 5 is
    ///      refunded inside the call. The reserve must end at 55, not 50. Before the fix the splitter debited the
    ///      OFFERED amount, so the 5 that came back was no longer counted as reserve, `_pendingUsdg` read it as a
    ///      fresh fee, and the next distribute sent `(BPS - burnBps)` of it to the treasury as revenue.
    ///      PROVE BY BREAKING: restore `buybackBalance = reserve - usdgIn` and this test goes red at the reserve.
    function test_partialFillDebitsWhatWasSpentNotWhatWasOffered() public {
        stonk.mint(address(splitter), 0);
        usdg.mint(address(splitter), 100e6);
        splitter.distribute(address(usdg)); // 50/50: 50 to treasury, 50 to the reserve
        usdg.mint(address(splitter), 100e6);
        splitter.distribute(address(usdg));
        assertEq(splitter.buybackBalance(), 100e6, "reserve is 100 USDG");
        uint256 treasuryBefore = usdg.balanceOf(treasury);

        PartialFillExecutor executor = new PartialFillExecutor(usdg, stonk, address(splitter), 45e6);
        stonk.setSupplyController(address(executor), true);
        stonk.mint(address(executor), 1e18);
        vm.startPrank(holder);
        splitter.setBuybackExecutor(address(executor));
        splitter.setBuybackCap(50e6);
        vm.stopPrank();

        vm.expectEmit(false, false, false, true, address(splitter));
        emit IFeeSplitter.BoughtBack(45e6, 1e18);
        vm.prank(holder);
        (uint256 reportedSpend,) = splitter.buyback(1);

        assertEq(reportedSpend, 45e6, "the return is the spend, as IFeeSplitter documents it");
        assertEq(splitter.buybackBalance(), 55e6, "the 5 USDG refund stayed in the reserve");
        assertEq(usdg.balanceOf(address(splitter)), 55e6, "and the balance agrees with the counter");

        // The refund must not look like a new fee to the next distribute.
        uint256 split = splitter.distribute(address(usdg));
        assertEq(split, 0, "there is no unreserved USDG to split");
        assertEq(usdg.balanceOf(treasury), treasuryBefore, "not one unit of the refund reached the treasury");
        assertEq(splitter.buybackBalance(), 55e6, "and the reserve is untouched");
    }
}
