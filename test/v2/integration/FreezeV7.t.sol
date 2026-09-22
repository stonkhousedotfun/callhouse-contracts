// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2IntegrationBase} from "./V2IntegrationBase.t.sol";
import {FreezeV7, IClearinghouseV7, MarketConfigV7} from "../../../script/v2/FreezeV7.s.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice `script/v2/FreezeV7.s.sol` against a real Clearinghouse and OrderBook, and every claim
///         `docs/V7-RUNOFF.md` makes about what a frozen v7 market does.
/// @dev The tool reads the live set from `SeriesCreated` / `MarketRegistered` logs, which needs a node. These tests
///      drive it through `Inputs.knownSeries` / `Inputs.registeredMarkets` instead — the same lists, given rather
///      than read — so the whole procedure runs in-process on the fixture's own contracts. The log scan itself is
///      exercised against the real chain in `test/v2/fork/FreezeV7Fork.t.sol`.
///
///      Nothing here broadcasts, because there is nothing to broadcast with:
///      {test_cannotBroadcast_notEvenWithEveryMarketSelected} is the statement of that.
/**
 * T-CV-CLEARINGHOUSE, checked at contracts 8adcde6f89cbbabfba4fb50227a89edac09350f7.
 *
 * THE CAUSE IS HERE, IN THESE TESTS, NOT IN script/v2/FreezeV7.s.sol. An earlier version of this
 * note said the opposite; it was wrong and this replaces it.
 *
 * `forge test --match-path test/v2/integration/FreezeV7.t.sol` was 9 passed / 17 failed / 26 total.
 * The C8-12 ledger entry records this file as "written and compiling, never executed"; that was its
 * first execution.
 *
 * WHY: FreezeV7 is a V7 TOOL BY DESIGN — its header says it freezes the DEPLOYED v7 set and declares
 * its own IClearinghouseV7 so a v8 refactor cannot change the calldata the owner signs. The live v7
 * Clearinghouse answered `hasRole` directly. THIS FIXTURE IS v8 and delegates roles to AccessManager,
 * so `hasRole` hits `unrecognized function selector 0x91d14854` and every unmocked test dies there —
 * before the behaviour it names ever runs. One test already mocked the two v7 preflight reads and was
 * the only one passing; `_mockV7Preflight()` gives the rest the same two mocks and nothing more.
 *
 * RESULT: 14 passed / 12 failed. Five repaired. The residue is three separate causes, none of them
 * this one: 6 x NotMinter() (the isMinter allowlist, T-448 Cause A, untouched here), 5 x a missing v7
 * `setMarketConfig` on the same v8 fixture (the same class one layer deeper, now reachable because
 * the role probe no longer blocks it), and 1 x `vm.eth_getLogs: no active fork URL` in
 * test_cannotBroadcast_notEvenWithEveryMarketSelected, which needs an RPC and is owner-gated.
 *
 * DO NOT mock `hasRole` wholesale to clear the rest. Mocking only the two exact preflight reads is
 * what keeps an unrelated missing selector from making an `expectRevert` case green for the wrong
 * reason — which is the failure this suite exists to prevent, and which two of these tests were one
 * small edit away from.
 */
contract FreezeV7Test is V2IntegrationBase {
    FreezeV7 internal tool;

    uint128 internal constant K_220 = 220_000_000;
    uint128 internal constant K_230 = 230_000_000;
    uint128 internal constant K_240 = 240_000_000;
    uint64 internal constant UNITS = 50;

    function setUp() public override {
        super.setUp();
        tool = new FreezeV7();
        _registerNvda();
        _onboard(alice);
        _onboard(bob);
    }

    /*//////////////////////////////////////////////////////////////
                              THE REFUSALS
    //////////////////////////////////////////////////////////////*/

    /// @dev The two v7 preflight reads `FreezeV7.freezeSet` makes before it reaches any guard of its own.
    ///      THIS FIXTURE IS v8: it delegates roles to AccessManager and has no `hasRole`, while the live v7
    ///      Clearinghouse this tool targets answered it directly (see the tool's own IClearinghouseV7). Without
    ///      these two mocks every call dies on `unrecognized function selector 0x91d14854` before the behaviour
    ///      under test runs — which for an `expectRevert` case would be GREEN FOR THE WRONG REASON.
    ///      Mock ONLY these two reads, never `hasRole` wholesale, so a missing selector anywhere else still fails.
    ///      (T-CV-CLEARINGHOUSE, at contracts 8adcde6f89cbbabfba4fb50227a89edac09350f7.)
    function _mockV7Preflight() private {
        vm.mockCall(
            address(ch), abi.encodeCall(IClearinghouseV7.hasRole, (tool.GUARDIAN_ROLE(), guardian)), abi.encode(true)
        );
        vm.mockCall(
            address(ch), abi.encodeCall(IClearinghouseV7.hasRole, (tool.DEFAULT_ADMIN_ROLE(), admin)), abi.encode(true)
        );
    }

    function test_freezeSet_acceptsTheLiveSet() public {
        _mockV7Preflight();
        address[] memory set = tool.freezeSet(_inputs());
        assertEq(set.length, 1, "one market");
        assertEq(set[0], address(nvda), "NVDA");
    }

    function test_freezeSet_refusesTheWrongChain() public {
        FreezeV7.Inputs memory in_ = _inputs();
        in_.expectChainId = block.chainid + 1;
        vm.expectRevert();
        tool.freezeSet(in_);
    }

    function test_freezeSet_refusesAGuardianWithoutTheRole() public {
        FreezeV7.Inputs memory in_ = _inputs();
        in_.guardian = bob;
        vm.expectRevert();
        tool.freezeSet(in_);
    }

    function test_freezeSet_refusesAnAdminWithoutTheRole() public {
        FreezeV7.Inputs memory in_ = _inputs();
        in_.admin = guardian;
        vm.expectRevert();
        tool.freezeSet(in_);
    }

    function test_freezeSet_refusesAnUnregisteredMarket() public {
        FreezeV7.Inputs memory in_ = _inputs();
        in_.markets[0] = address(tsla);
        in_.registeredMarkets = in_.markets;
        vm.expectRevert();
        tool.freezeSet(in_);
    }

    function test_freezeSet_refusesADuplicate() public {
        FreezeV7.Inputs memory in_ = _inputs();
        address[] memory twice = new address[](2);
        (twice[0], twice[1]) = (address(nvda), address(nvda));
        in_.markets = twice;
        vm.expectRevert();
        tool.freezeSet(in_);
    }

    function test_freezeSet_refusesABookWiredElsewhere() public {
        FreezeV7.Inputs memory in_ = _inputs();
        in_.clearinghouse = address(calendar); // has code, is not the book's clearinghouse
        vm.expectRevert();
        tool.freezeSet(in_);
    }

    /// @dev THE ONE THAT MATTERS. `setCreatePaused` stops new series ids; it does NOT stop `mint` on a series that
    ///      already exists. A second registered market left out of the set would therefore keep writing new risk,
    ///      so the tool refuses to plan at all.
    function test_freezeSet_refusesAnEnabledMarketLeftOut() public {
        _mockV7Preflight();
        vm.startPrank(admin);
        ch.registerMarket(address(tsla), STRIKE_TICK, true);
        ch.setMarketOracle(address(tsla), address(oracle));
        ch.setMarketFees(address(tsla), EXERCISE_FEE_BPS, 0);
        vm.stopPrank();

        FreezeV7.Inputs memory in_ = _inputs();
        address[] memory both = new address[](2);
        (both[0], both[1]) = (address(nvda), address(tsla));
        in_.registeredMarkets = both;
        vm.expectRevert();
        tool.freezeSet(in_); // in_.markets still names NVDA alone

        in_.markets = both;
        assertEq(tool.freezeSet(in_).length, 2, "naming both is accepted");
    }

    /// @dev Both operator-supplied arrays omit the canonical live market, so comparing them to each other cannot
    ///      catch the omission. The compiled live-market pin is the independent subject that must make this revert.
    function test_freezeSet_refusesATruncatedOverrideThatOmitsPinnedLiveMarket() public {
        address pinnedNvda = tool.NVDA();
        assertTrue(pinnedNvda != address(nvda), "the fixture market and live pin must differ");

        vm.etch(pinnedNvda, address(nvda).code);
        vm.prank(admin);
        ch.registerMarket(pinnedNvda, STRIKE_TICK, true);
        assertTrue(ch.market(pinnedNvda).enabled, "the omitted pinned market is enabled");

        // This fixture is v8 and delegates roles to AccessManager, while the live v7 Clearinghouse answered
        // hasRole directly. Mock only the two exact v7 preflight reads so an unrelated missing selector cannot make
        // expectRevert green before the completeness guard runs.
        vm.mockCall(
            address(ch), abi.encodeCall(IClearinghouseV7.hasRole, (tool.GUARDIAN_ROLE(), guardian)), abi.encode(true)
        );
        vm.mockCall(
            address(ch), abi.encodeCall(IClearinghouseV7.hasRole, (tool.DEFAULT_ADMIN_ROLE(), admin)), abi.encode(true)
        );

        FreezeV7.Inputs memory in_ = _inputs();
        assertEq(in_.markets.length, 1, "the freeze set is deliberately truncated");
        assertEq(in_.registeredMarkets.length, 1, "the override is deliberately truncated");
        assertTrue(in_.markets[0] != pinnedNvda, "the live pin is omitted from the freeze set");
        assertTrue(in_.registeredMarkets[0] != pinnedNvda, "the live pin is omitted from the override");

        vm.expectRevert(
            bytes(
                string.concat(
                    "market ",
                    vm.toString(pinnedNvda),
                    " is registered and still enabled but is not in V7_MARKETS. setCreatePaused does not stop mint",
                    " on series that already exist, so leaving it enabled leaves new risk open. Add it."
                )
            )
        );
        tool.freezeSet(in_);
    }

    /// @dev A market that is registered but ALREADY disabled needs no call and may be left out.
    function test_freezeSet_allowsADisabledMarketToBeLeftOut() public {
        _mockV7Preflight();
        vm.startPrank(admin);
        ch.registerMarket(address(tsla), STRIKE_TICK, false);
        ch.setMarketOracle(address(tsla), address(oracle));
        ch.setMarketFees(address(tsla), EXERCISE_FEE_BPS, 0);
        vm.stopPrank();

        FreezeV7.Inputs memory in_ = _inputs();
        address[] memory both = new address[](2);
        (both[0], both[1]) = (address(nvda), address(tsla));
        in_.registeredMarkets = both;
        assertEq(tool.freezeSet(in_).length, 1, "the disabled market needs no call");
    }

    /*//////////////////////////////////////////////////////////////
                                THE PLAN
    //////////////////////////////////////////////////////////////*/

    function test_plan_isTwoCallsAndChangesNothing() public {
        _mockV7Preflight();
        FreezeV7.Call[] memory calls = tool.plan(_inputs());
        assertEq(calls.length, 2, "the pause and one market");
        assertTrue(calls[0].guardianRole, "the guardian's call comes first");
        assertEq(bytes4(calls[0].data), tool.SET_CREATE_PAUSED());
        assertFalse(calls[1].guardianRole, "the admin's call second");
        assertEq(bytes4(calls[1].data), tool.SET_MARKET_CONFIG());
        assertEq(calls[0].to, address(ch));
        assertEq(calls[1].to, address(ch));
        assertFalse(ch.createPaused(), "planning changed nothing");
        assertTrue(ch.market(address(nvda)).enabled, "planning changed nothing");
    }

    /// @dev The config call carries the chain's own row with `enabled` alone flipped. `_checkFreezeOnly` refuses to
    ///      build anything else, and this pins what "anything else" means field by field.
    function test_plan_flipsEnabledAndNothingElse() public {
        _mockV7Preflight();
        FreezeV7.Call[] memory calls = tool.plan(_inputs());
        (address underlying, MarketConfigV7 memory cfg) = _decodeConfig(calls[1].data);
        V2Types.MarketConfig memory live = ch.market(address(nvda));
        assertEq(underlying, address(nvda));
        assertFalse(cfg.enabled, "enabled goes false");
        assertEq(cfg.mintPaused, live.mintPaused, "mintPaused as stored");
        assertEq(cfg.strikeTick, live.strikeTick, "strikeTick unchanged");
        assertEq(cfg.exerciseFeeBps, live.exerciseFeeBps, "exerciseFeeBps unchanged");
        assertEq(cfg.oracle, live.oracle, "oracle unchanged");
        assertEq(cfg.mintFeePpm, live.mintFeePpm, "mintFeePpm unchanged");
    }

    function test_plan_skipsWhatIsAlreadyDone() public {
        _mockV7Preflight();
        vm.prank(guardian);
        ch.setCreatePaused(true);
        assertEq(tool.plan(_inputs()).length, 1, "only the market call is left");

        _applyFreeze();
        assertEq(tool.plan(_inputs()).length, 0, "nothing left: idempotent");
    }

    /// @dev The guardian's pause never lifts the guardian's own mint pause, and the admin's config push cannot
    ///      either: the Clearinghouse keeps the stored `mintPaused` whatever the call carries.
    function test_plan_cannotLiftAGuardianMintPause() public {
        _mockV7Preflight();
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), true);
        _applyFreeze();
        assertTrue(ch.market(address(nvda)).mintPaused, "the guardian pause survived the freeze");
    }

    /*//////////////////////////////////////////////////////////////
                         NEW RISK, AND ONLY NEW RISK
    //////////////////////////////////////////////////////////////*/

    function test_afterTheFreeze_creationAndMintAreRefused() public {
        uint256 longId = _write(alice, K_230, FRI_2026_09_18, UNITS);
        _applyFreeze();

        vm.prank(alice);
        vm.expectRevert(V2Errors.MarketDisabled.selector);
        ch.mint(longId, 1, alice, alice);

        vm.prank(alice);
        vm.expectRevert(V2Errors.MarketDisabled.selector);
        ch.createSeries(address(nvda), false, K_240, FRI_2026_09_18);
    }

    /// @dev The create pause is the half that does not depend on a market being disabled.
    function test_afterTheFreeze_creationIsRefusedEvenIfTheMarketIsReEnabled() public {
        _mockV7Preflight();
        _applyFreeze();
        V2Types.MarketConfig memory cfg = _nvdaMarket();
        vm.prank(admin);
        _reconfigure(ch, address(nvda), cfg);

        vm.prank(alice);
        vm.expectRevert(V2Errors.CreatePaused.selector);
        ch.createSeries(address(nvda), false, K_240, FRI_2026_09_18);
    }

    /// @dev THE PROPERTY THE FREEZE EXISTS TO PRESERVE: close, withdraw, cancel and a resale all still work.
    function test_afterTheFreeze_nobodyIsTrapped() public {
        uint256 longId = _write(alice, K_230, FRI_2026_09_18, UNITS);
        uint256 askId = _place(alice, longId, RESALE, 8_000_000, 20);
        uint256 bidId = _place(bob, longId, BID, 1_000_000, 5);

        _applyFreeze();

        // a resale still fills: the holder's only pre-expiry exit
        vm.prank(bob);
        (uint64 filled,,) = book.take(_buyParams(longId, _ids(askId), 10, 10, bob));
        assertEq(filled, 10, "the resale take still fills");

        // the maker cancels the rest and the escrow comes home
        uint256 longsBefore = ch.balanceOf(alice, longId);
        vm.prank(alice);
        book.cancel(_ids(askId));
        assertEq(ch.balanceOf(alice, longId), longsBefore + 10, "the escrowed longs came back");

        // the bidder cancels and the USDG comes home
        uint256 usdgBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        book.cancel(_ids(bidId));
        assertGt(usdg.balanceOf(bob), usdgBefore, "the escrowed USDG came back");

        // close burns long + short together and credits the collateral
        // casting to 'uint64' is safe because the balance came from a mint of UNITS, a uint64
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 closable = uint64(ch.balanceOf(alice, longId));
        uint256 freeBefore = ch.free(alice, address(nvda));
        vm.prank(alice);
        ch.close(longId, closable);
        assertGe(
            ch.free(alice, address(nvda)) - freeBefore,
            uint256(closable) * ch.collateralPerUnit(longId),
            "collateral back"
        );

        // and it leaves the Clearinghouse
        uint256 walletBefore = nvda.balanceOf(alice);
        uint256 freeNow = ch.free(alice, address(nvda));
        vm.prank(alice);
        ch.withdraw(address(nvda), freeNow, alice);
        assertEq(nvda.balanceOf(alice), walletBefore + freeNow, "the collateral went home");
    }

    /// @dev Settlement and redemption are the run-off itself: the cranker keeps working on a frozen market.
    function test_afterTheFreeze_theExpiryStillSettlesAndRedeems() public {
        uint256 longId = _write(alice, K_230, FRI_2026_09_18, UNITS);
        _applyFreeze();

        _settleAt(longId, 240_000_000);
        assertTrue(ch.series(longId).settled, "settled after the freeze");

        vm.prank(alice);
        ch.redeem(longId, alice);
        assertEq(ch.balanceOf(alice, longId), 0, "the long redeemed");
        vm.prank(alice);
        ch.redeem(V2Ids.shortIdOf(longId), alice);
        assertEq(ch.balanceOf(alice, V2Ids.shortIdOf(longId)), 0, "the short redeemed");
    }

    function test_theFreezeLeavesTheBookTrading() public {
        _mockV7Preflight();
        _applyFreeze();
        assertFalse(book.tradingPaused(), "a paused book would take away the resale exit");
        assertEq(tool.postCheck(_inputs(), _markets()), 0, "post-check passes");
    }

    /// @dev The post-check cannot pass by accident: before the freeze it fails on both switches.
    function test_postCheck_hasTeeth() public view {
        assertEq(tool.postCheck(_inputs(), _markets()), 2, "createPaused and enabled both fail");
    }

    /// @dev A freeze that paused the book fails the post-check, however frozen the Clearinghouse is.
    function test_postCheck_failsWhenTheBookWasPaused() public {
        _mockV7Preflight();
        _applyFreeze();
        vm.prank(guardian);
        book.setTradingPaused(true);
        assertEq(tool.postCheck(_inputs(), _markets()), 1, "a paused book is a failure, not a success");
    }

    /*//////////////////////////////////////////////////////////////
                               THE RUN-OFF
    //////////////////////////////////////////////////////////////*/

    /// @dev `lastExpiry` is the largest expiry over every series that exists; `lastOpenExpiry` the largest that
    ///      still carries units, which is what a holder is told. They are different numbers and the report says so.
    function test_runOff_lastExpiryAndLastOpenExpiry() public {
        _mockV7Preflight();
        uint256 near = _write(alice, K_230, THU_2026_09_10, UNITS);
        vm.prank(alice);
        uint256 far = ch.createSeries(address(nvda), false, K_220, FRI_2026_09_18);

        FreezeV7.Inputs memory in_ = _inputs();
        in_.knownSeries = _ids2(near, far);
        (FreezeV7.RunOff memory off, FreezeV7.SeriesRow[] memory rows) = tool.runOff(in_);

        assertEq(rows.length, 2, "both series reported");
        assertEq(off.seriesCount, 2);
        assertEq(off.openSeriesCount, 1, "only the written one carries units");
        assertEq(off.openUnits, UNITS);
        assertEq(off.lastExpiry, FRI_2026_09_18, "the furthest series that exists");
        assertEq(off.lastOpenExpiry, THU_2026_09_10, "the furthest series still holding units");
        assertEq(off.tenorCeiling, uint40(block.timestamp + V2Constants.MAX_TENOR), "the ceiling is now + MAX_TENOR");
        assertEq(off.unaccountedExpiry, 0, "the grid agrees with the series list");
        assertFalse(off.gridTruncated, "the window from START to the ceiling fits in MAX_GRID_STEPS closes");
    }

    /// @dev T-OP-055. The walk is capped at MAX_GRID_STEPS session closes, and before this row a walk that hit the
    ///      cap was indistinguishable from one that reached the ceiling: both reported `unaccountedExpiry == 0`. Push
    ///      `now` far enough past the fixture's START that the window `[START, now + MAX_TENOR]` holds more closes than
    ///      the cap (120 days on, the window is ~165 calendar days, ~118 session closes) and the report must say so.
    ///      PROVE BY BREAKING: with `truncated = !reachedEnd` replaced by `truncated = false` in
    ///      `_unaccountedExpiry`, this test goes red on its first assertion by name.
    function test_runOff_gridWalkReportsTruncation() public {
        _mockV7Preflight();
        uint256 longId = _write(alice, K_230, THU_2026_09_10, UNITS);
        vm.warp(START + 120 days);

        FreezeV7.Inputs memory in_ = _inputs();
        in_.knownSeries = _ids(longId);
        assertEq(in_.gridFrom, uint40(START), "the walk starts at the fixture's START");
        (FreezeV7.RunOff memory off,) = tool.runOff(in_);

        assertTrue(off.gridTruncated, "MAX_GRID_STEPS closes from START do not reach now + MAX_TENOR: truncated");
        assertEq(off.unaccountedExpiry, 0, "nothing unaccounted inside the part that was walked");
        assertEq(off.unsettledPastCount, 1, "the written series expired unsettled inside the walked part");
    }

    /// @dev T-OP-055, the other half of the same finding: `gridFrom` is only ever wrong through the operator's
    ///      V7_GRID_FROM, so that variable is bounded to [DEPLOY_TS, now] where it is read, with a refusal that
    ///      names the variable and the bound. A value before the deploy only spends grid steps on closes no v7
    ///      series can have (and is how a walk comes to truncate); a value in the future skips every close before it.
    ///      Refused, never clamped. The bound lives in {FreezeV7.gridFromInBounds}, which `_inputsFromEnv` calls on
    ///      the raw variable; it is driven directly here rather than through `vm.setEnv` + `run()`, because the
    ///      environment is process-global and forge runs tests in parallel -- an env test races its neighbours.
    function test_gridFromInBounds_refusesAStartBeforeTheDeploy() public {
        uint256 tooEarly = uint256(tool.DEPLOY_TS()) - 1;
        vm.expectRevert(
            bytes(
                string.concat(
                    "V7_GRID_FROM ",
                    vm.toString(tooEarly),
                    " is before DEPLOY_TS ",
                    vm.toString(uint256(tool.DEPLOY_TS())),
                    ": no v7 expiry exists before the deploy; the grid walk must start in [DEPLOY_TS, now]"
                )
            )
        );
        tool.gridFromInBounds(tooEarly);
    }

    function test_gridFromInBounds_refusesAStartInTheFuture() public {
        vm.warp(uint256(tool.DEPLOY_TS()) + 1 days);
        uint256 tomorrow = block.timestamp + 1;
        vm.expectRevert(
            bytes(
                string.concat(
                    "V7_GRID_FROM ",
                    vm.toString(tomorrow),
                    " is in the future (now ",
                    vm.toString(block.timestamp),
                    "): the grid walk would skip every close before it; it must start in [DEPLOY_TS, now]"
                )
            )
        );
        tool.gridFromInBounds(tomorrow);
    }

    /// @dev Both edges are inside the bound: DEPLOY_TS itself and `now` itself pass, and come back unchanged. The
    ///      happy path is the default (V7_GRID_FROM unset reads as DEPLOY_TS) and is exactly the first edge.
    function test_gridFromInBounds_acceptsBothEdges() public {
        vm.warp(uint256(tool.DEPLOY_TS()) + 1 days);
        assertEq(tool.gridFromInBounds(uint256(tool.DEPLOY_TS())), tool.DEPLOY_TS(), "DEPLOY_TS, the default, passes");
        assertEq(tool.gridFromInBounds(block.timestamp), uint40(block.timestamp), "now passes");
    }
    /// @dev The cross-check that keeps a short scan from producing a confident wrong date: an expiry reporting open
    ///      interest with no series behind it in the list is reported, not ignored.
    function test_runOff_flagsAnExpiryTheSeriesListMissed() public {
        uint256 near = _write(alice, K_230, THU_2026_09_10, UNITS);
        uint256 far = _write(alice, K_230, FRI_2026_09_18, UNITS);
        assertGt(ch.openInterest(address(nvda), FRI_2026_09_18), 0, "the far expiry really does carry units");
        assertTrue(far != near, "two distinct series");

        // `far` is deliberately left out of the list the tool is given: this is a scan that came up short.
        FreezeV7.Inputs memory in_ = _inputs();
        in_.knownSeries = _ids(near);
        (FreezeV7.RunOff memory off,) = tool.runOff(in_);
        assertEq(off.unaccountedExpiry, FRI_2026_09_18, "the missing expiry is named");
    }

    function test_runOff_countsExpiredUnsettledSeries() public {
        uint256 longId = _write(alice, K_230, THU_2026_09_10, UNITS);
        vm.warp(uint256(THU_2026_09_10) + 1);

        FreezeV7.Inputs memory in_ = _inputs();
        in_.knownSeries = _ids(longId);
        (FreezeV7.RunOff memory off,) = tool.runOff(in_);
        assertEq(off.unsettledPastCount, 1, "the cranker still owes this one a settle");
    }

    function test_runOff_refusesASeriesIdThatDoesNotExist() public {
        FreezeV7.Inputs memory in_ = _inputs();
        in_.knownSeries = _ids(uint256(keccak256("not a series")) & ~uint256(1));
        vm.expectRevert();
        tool.runOff(in_);
    }

    /*//////////////////////////////////////////////////////////////
                            NO BROADCAST PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev The tool takes no key, holds no key, and sends nothing on any path: a full `runWith` over every market,
    ///      with the plan files switched off, leaves the chain exactly as it found it. The only thing that changes
    ///      anything is the owner sending the calldata afterwards.
    function test_cannotBroadcast_notEvenWithEveryMarketSelected() public {
        _mockV7Preflight();
        vm.startPrank(admin);
        ch.registerMarket(address(tsla), STRIKE_TICK, true);
        ch.setMarketOracle(address(tsla), address(oracle));
        ch.setMarketFees(address(tsla), EXERCISE_FEE_BPS, 0);
        vm.stopPrank();

        FreezeV7.Inputs memory in_ = _inputs();
        address[] memory both = new address[](2);
        (both[0], both[1]) = (address(nvda), address(tsla));
        in_.markets = both;
        in_.registeredMarkets = both;

        bool pausedBefore = ch.createPaused();
        bool nvdaBefore = ch.market(address(nvda)).enabled;
        bool tslaBefore = ch.market(address(tsla)).enabled;
        bool bookBefore = book.tradingPaused();

        (,, FreezeV7.Call[] memory calls) = tool.runWith(in_);
        assertEq(calls.length, 3, "one pause and two markets, planned only");

        assertEq(ch.createPaused(), pausedBefore, "nothing was sent");
        assertEq(ch.market(address(nvda)).enabled, nvdaBefore, "nothing was sent");
        assertEq(ch.market(address(tsla)).enabled, tslaBefore, "nothing was sent");
        assertEq(book.tradingPaused(), bookBefore, "the book was never touched");
        assertEq(address(tool).balance, 0, "the tool holds nothing");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _inputs() internal view returns (FreezeV7.Inputs memory in_) {
        in_ = FreezeV7.Inputs({
            clearinghouse: address(ch),
            orderBook: address(book),
            markets: _markets(),
            guardian: guardian,
            admin: admin,
            registeredMarkets: _markets(),
            knownSeries: new uint256[](0),
            fromBlock: 0,
            logChunk: tool.DEFAULT_LOG_CHUNK(),
            maxSeries: tool.DEFAULT_MAX_SERIES(),
            // casting to 'uint40' is safe because START is a 2026 timestamp
            // forge-lint: disable-next-line(unsafe-typecast)
            gridFrom: uint40(START),
            extraExpiries: new uint40[](0),
            writePlan: false,
            guardianPlanOut: "",
            adminPlanOut: "",
            expectChainId: block.chainid
        });
    }

    function _markets() internal view returns (address[] memory set) {
        set = new address[](1);
        set[0] = address(nvda);
    }

    /// @dev Sends the planned calls from the role holders the plan names, byte for byte.
    function _applyFreeze() internal {
        FreezeV7.Inputs memory in_ = _inputs();
        FreezeV7.Call[] memory calls = tool.plan(in_);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(calls[i].guardianRole ? in_.guardian : in_.admin);
            (bool ok,) = calls[i].to.call(calls[i].data);
            assertTrue(ok, calls[i].what);
        }
    }

    function _write(address who, uint128 strike, uint40 expiry, uint64 units) internal returns (uint256 longId) {
        vm.prank(who);
        longId = ch.createSeries(address(nvda), false, strike, expiry);
        _deposit(who, address(nvda), units * ch.collateralPerUnit(longId) + ch.mintFee(longId, units));
        vm.prank(who);
        ch.setOperator(address(this), true);
        ch.mint(longId, units, who, who);
    }

    function _settleAt(uint256 longId, uint256 price) internal {
        V2Types.Series memory s = ch.series(longId);
        _print(price, TICK_220, uint256(s.expiry) - 1);
        vm.warp(uint256(s.expiry) + 1);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), s.expiry);
        vm.warp(uint256(s.expiry) + V2Constants.FINALIZE_DELAY + 1);
        vm.prank(keeper);
        oracle.finalize(address(nvda), s.expiry);
        vm.prank(keeper);
        ch.settle(longId);
    }

    function _decodeConfig(bytes memory data) internal pure returns (address underlying, MarketConfigV7 memory cfg) {
        bytes memory tail = new bytes(data.length - 4);
        for (uint256 i; i < tail.length; ++i) {
            tail[i] = data[i + 4];
        }
        return abi.decode(tail, (address, MarketConfigV7));
    }

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (a, b);
    }
}
