// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {IKeeperRewards} from "../../../src/v2/interfaces/IKeeperRewards.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockOraclePriceSource} from "../../../src/v2/mocks/MockOraclePriceSource.sol";
import {MockOpenInterestClearinghouse} from "../../../src/v2/mocks/MockOpenInterestClearinghouse.sol";

/// @notice Shared fixture of the SettlementOracle suites: the oracle (admin, guardian), three scriptable sources, a real
///         KeeperRewards funded and registered for the oracle, and a Clearinghouse stand-in reporting open interest on
///         the NVDA expiry under test.
/// @dev Extends test/v2/BaseV2.t.sol through its {_deployCore} hook. The expiry is THU_2026_09_10; every source answers
///      "not ok" until a test scripts it. Prices are USDG base units (6 dp) per share.
abstract contract SettlementOracleFixture is BaseV2Test {
    uint40 internal constant E = THU_2026_09_10;
    uint40 internal constant FINALIZABLE = E + V2Constants.FINALIZE_DELAY;
    uint256 internal constant P = 220_000_000;
    uint256 internal constant SNAPSHOT_BOUNTY = 40_000;
    uint256 internal constant FINALIZE_BOUNTY = 60_000;
    uint256 internal constant BUDGET = 10_000_000;

    address internal stranger = makeAddr("stranger");

    SettlementOracle internal oracle;
    KeeperRewards internal rewards;
    MockOpenInterestClearinghouse internal ch;
    MockOraclePriceSource internal s0;
    MockOraclePriceSource internal s1;
    MockOraclePriceSource internal s2;

    function _deployCore() internal virtual override {
        oracle = new SettlementOracle(admin, guardian);
        s0 = new MockOraclePriceSource();
        s1 = new MockOraclePriceSource();
        s2 = new MockOraclePriceSource();
        rewards = new KeeperRewards(IERC20(address(usdg)), admin);
        ch = new MockOpenInterestClearinghouse();
        vm.label(address(oracle), "SettlementOracle");
        vm.label(address(s0), "source0");
        vm.label(address(s1), "source1");
        vm.label(address(s2), "source2");

        vm.startPrank(admin);
        rewards.setCaller(address(oracle), true);
        rewards.setBounty(V2Constants.ACTION_SNAPSHOT, SNAPSHOT_BOUNTY);
        rewards.setBounty(V2Constants.ACTION_FINALIZE, FINALIZE_BOUNTY);
        rewards.setDailyCap(BUDGET);
        oracle.setClearinghouse(address(ch));
        oracle.setKeeperRewards(address(rewards));
        vm.stopPrank();
        usdg.mint(address(rewards), BUDGET);
        ch.setOpenInterest(address(nvda), E, 1_000);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (a, b);
    }

    function _list(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }

    /// @dev NVDA's sources: s0, s1, s2 in that priority order, default parameters.
    function _useThree() internal {
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1), address(s2)), 0, 0, 0);
    }

    function _useTwo() internal {
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 0, 0, 0);
    }

    /// @dev Pins E on the oracle as the Clearinghouse stand-in, as Clearinghouse.createSeries does for the first series
    ///      of an expiry: the SNAPSHOT and FINALIZE bounties are paid only on an expiry the current Clearinghouse
    ///      pinned or confirmed on this oracle (sweep contracts-c11).
    function _pinE() internal {
        vm.prank(address(ch));
        oracle.pin(address(nvda), E);
    }

    function _finalize() internal returns (bool finalized, uint256 price) {
        vm.prank(keeper);
        return oracle.finalize(address(nvda), E);
    }

    function _snapshot() internal returns (uint8 n) {
        vm.prank(keeper);
        return oracle.snapshot(address(nvda), E);
    }

    function _status() internal view returns (V2Types.SettlementStatus status) {
        (status,) = oracle.settlementPrice(address(nvda), E);
    }

    function _now40() internal view returns (uint40) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(block.timestamp);
    }

    /// @dev Logs `emitter` produced since vm.recordLogs().
    function _logsFrom(address emitter) internal view returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) ++count;
        }
    }
}

/*//////////////////////////////////////////////////////////////
                         THE FALLBACK CHAIN
//////////////////////////////////////////////////////////////*/

/// @notice Every branch of ADR-05's chain with scripted sources: corroboration and its priority order, disagreement,
///         a single source before and after the delay, veto / unveto (with `finalizableAt` in events and the candidate
///         view), no source ok, TooEarly, idempotency, candidate changes, pinned sources and malformed replies.
contract SettlementOracleChainTest is SettlementOracleFixture {
    /// Two agreeing sources finalize at once on the higher-priority one.
    function test_corroborated_twoAgree_primaryPrice() public {
        _useTwo();
        s0.setWindow(true, P);
        s1.setWindow(true, 221_000_000); // 45 bps above
        vm.warp(FINALIZABLE);

        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 0, true, P);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 1, true, 221_000_000);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementFinalized(address(nvda), E, P, 0, true);
        (bool finalized, uint256 price) = _finalize();

        assertTrue(finalized, "final");
        assertEq(price, P, "priority order: source 0's price");
        (V2Types.SettlementStatus status, uint256 stored, uint8 idx, bool corroborated, bool resolved, bool captured) =
            oracle.settlementInfo(address(nvda), E);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "Finalized");
        assertEq(stored, P, "stored price");
        assertEq(idx, 0, "source 0");
        assertTrue(corroborated && !resolved && captured, "flags");
        (uint256 cp,,, uint40 at) = oracle.candidate(address(nvda), E);
        assertEq(cp + at, 0, "no candidate on the corroborated path");
    }

    /// Source 0 not ok; 1 and 2 agree: the first agreeing index in priority order is 1.
    function test_corroborated_priorityOrder_skipsNotOkPrimary() public {
        _useThree();
        s1.setWindow(true, 219_000_000);
        s2.setWindow(true, P);
        vm.warp(FINALIZABLE);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementFinalized(address(nvda), E, 219_000_000, 1, true);
        (bool finalized, uint256 price) = _finalize();
        assertTrue(finalized, "final");
        assertEq(price, 219_000_000, "source 1");
    }

    /// The primary disagrees with two sources that agree with each other: the second source's price is used.
    function test_corroborated_primaryDisagrees_secondUsed() public {
        _useThree();
        s0.setWindow(true, 230_000_000);
        s1.setWindow(true, P);
        s2.setWindow(true, 220_500_000);
        vm.warp(FINALIZABLE);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementFinalized(address(nvda), E, P, 1, true);
        (bool finalized, uint256 price) = _finalize();
        assertTrue(finalized, "final");
        assertEq(price, P, "second source");
    }

    /// Exactly maxDeviationBps apart (of the lower price) agrees.
    function test_agreement_exactlyAtBound_corroborates() public {
        _useTwo();
        s0.setWindow(true, 203_000_000);
        s1.setWindow(true, 200_000_000); // 3e6 * 1e4 == 200e6 * 150
        vm.warp(FINALIZABLE);
        (bool finalized, uint256 price) = _finalize();
        assertTrue(finalized, "150 bps of the lower price agrees");
        assertEq(price, 203_000_000, "source 0");
    }

    /// One base unit beyond the bound disagrees.
    function test_agreement_justBeyondBound_disagrees() public {
        _useTwo();
        s0.setWindow(true, 203_000_001);
        s1.setWindow(true, 200_000_000);
        vm.warp(FINALIZABLE);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "beyond 150 bps");
        (uint256 cp, uint8 idx, bool disagreed,) = oracle.candidate(address(nvda), E);
        assertEq(cp, 203_000_001, "candidate source 0");
        assertEq(idx, 0, "index 0");
        assertTrue(disagreed, "disagreed");
    }

    /// All ok sources disagree: Pending, disagreed, highest-priority candidate, finalizableAt = now + 6 h.
    function test_allDisagree_pendingWithHighestPriorityCandidate() public {
        _useThree();
        s0.setWindow(true, 200_000_000);
        s1.setWindow(true, P);
        s2.setWindow(true, 240_000_000);
        vm.warp(FINALIZABLE + 7);
        uint40 at = _now40() + 6 hours;

        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, 200_000_000, 0, true, at);
        (bool finalized, uint256 price) = _finalize();

        assertFalse(finalized, "not final");
        assertEq(price, 0, "price 0 until final");
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "Pending");
        (uint256 cp, uint8 idx, bool disagreed, uint40 finalizableAt) = oracle.candidate(address(nvda), E);
        assertEq(cp, 200_000_000, "candidate price");
        assertEq(idx, 0, "candidate index");
        assertTrue(disagreed, "disagreed");
        assertEq(finalizableAt, at, "finalizableAt");
    }

    /// Disagreement with the primary not ok: the candidate is the first ok source.
    function test_disagree_candidateIsFirstOkSource() public {
        _useThree();
        s1.setWindow(true, P);
        s2.setWindow(true, 240_000_000);
        vm.warp(FINALIZABLE);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, P, 1, true, FINALIZABLE + 6 hours);
        _finalize();
    }

    /// Single ok source: Pending (disagreed false) until finalizableAt, final exactly at it, uncorroborated.
    function test_singleSource_beforeAndAfterDelay() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        uint40 at = FINALIZABLE + 6 hours;
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, P, 0, false, at);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "announced, not final");

        vm.warp(at - 1);
        vm.recordLogs();
        (finalized,) = _finalize();
        assertFalse(finalized, "one second early");
        assertEq(_logsFrom(address(oracle)), 0, "nothing emitted inside the delay");

        vm.warp(at);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementFinalized(address(nvda), E, P, 0, false);
        uint256 price;
        (finalized, price) = _finalize();
        assertTrue(finalized, "final at finalizableAt");
        assertEq(price, P, "candidate price");
        (,,, bool corroborated,,) = oracle.settlementInfo(address(nvda), E);
        assertFalse(corroborated, "uncorroborated");
    }

    /// A vetoed candidate holds: finalize returns (false, 0) without reverting, however late.
    function test_veto_heldReturnsFalseWithoutRevert() public {
        _useTwo();
        _pinE();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();

        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementVetoed(address(nvda), E);
        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Held), "Held");

        vm.warp(FINALIZABLE + 30 days);
        vm.recordLogs();
        (bool finalized, uint256 price) = _finalize();
        assertFalse(finalized, "held");
        assertEq(price, 0, "no price");
        assertEq(_logsFrom(address(oracle)), 0, "nothing emitted");
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Held), "still Held");
        assertEq(usdg.balanceOf(keeper), FINALIZE_BOUNTY, "only the first call advanced");
    }

    /// Held, then a second source starts answering and agrees: corroboration finalizes through the veto.
    function test_veto_thenCorroboration_finalizesNormally() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        vm.prank(guardian);
        oracle.veto(address(nvda), E);

        s1.setWindow(true, 220_100_000);
        vm.warp(FINALIZABLE + 10 minutes);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 1, true, 220_100_000);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementFinalized(address(nvda), E, P, 0, true);
        (bool finalized, uint256 price) = _finalize();
        assertTrue(finalized, "corroboration wins over the veto");
        assertEq(price, P, "source 0");
    }

    /// unveto restores the single-source path with the delay restarted from the unveto.
    function test_unveto_restoresSingleSourcePath_delayRestarts() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        uint40 firstAt = FINALIZABLE + 6 hours;

        vm.warp(FINALIZABLE + 1 hours);
        vm.prank(guardian);
        oracle.veto(address(nvda), E);

        vm.warp(FINALIZABLE + 2 hours);
        uint40 newAt = FINALIZABLE + 2 hours + 6 hours;
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementUnvetoed(address(nvda), E, newAt);
        vm.prank(guardian);
        oracle.unveto(address(nvda), E);
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "Pending again");
        (uint256 cp, uint8 idx, bool disagreed, uint40 at) = oracle.candidate(address(nvda), E);
        assertEq(at, newAt, "candidate view moved");
        assertEq(cp, P, "same candidate");
        assertEq(idx, 0, "same index");
        assertFalse(disagreed, "single source");

        vm.warp(firstAt);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "the old finalizableAt no longer applies");
        vm.warp(newAt - 1);
        (finalized,) = _finalize();
        assertFalse(finalized, "one second early");
        vm.warp(newAt);
        (finalized,) = _finalize();
        assertTrue(finalized, "final at the restarted finalizableAt");
    }

    /// finalizableAt follows the market's delay: a 30-minute market announces now + 30 min; a later delay change leaves
    /// the published value alone, and an unveto restarts with the delay configured at the unveto.
    function test_finalizableAt_followsMarketDelay() public {
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 0, 30 minutes, 0);
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, P, 0, false, FINALIZABLE + 30 minutes);
        _finalize();

        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 0, 2 hours, 0);
        (,,, uint40 at) = oracle.candidate(address(nvda), E);
        assertEq(at, FINALIZABLE + 30 minutes, "published finalizableAt unchanged");

        vm.warp(FINALIZABLE + 10 minutes);
        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementUnvetoed(address(nvda), E, FINALIZABLE + 10 minutes + 2 hours);
        vm.prank(guardian);
        oracle.unveto(address(nvda), E);
        (,,, at) = oracle.candidate(address(nvda), E);
        assertEq(at, FINALIZABLE + 10 minutes + 2 hours, "unveto uses the current delay");
    }

    /// The admin may lift a veto too.
    function test_unveto_byAdmin() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        vm.prank(admin);
        oracle.unveto(address(nvda), E);
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "Pending");
    }

    /// A pre-emptive veto (no candidate yet): capture happens while Held but no candidate is announced; unveto still goes
    /// Held -> Pending with finalizableAt = now + delay (candidate view stays zero); the next finalize announces the
    /// candidate with its own, later, finalizableAt, and that is when it finalizes.
    function test_unveto_preemptiveVeto_pendingThenCandidate() public {
        _useTwo();
        vm.prank(guardian);
        oracle.veto(address(nvda), E); // before expiry
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Held), "Held from None");

        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        vm.recordLogs();
        (bool finalized,) = _finalize();
        assertFalse(finalized, "held");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != ISettlementOracle.SettlementCandidate.selector, "no candidate announced while Held"
            );
        }
        (,,,,, bool captured) = oracle.settlementInfo(address(nvda), E);
        assertTrue(captured, "sources captured while Held");
        (uint256 cp,,, uint40 at) = oracle.candidate(address(nvda), E);
        assertEq(cp + at, 0, "candidate view all zero");

        vm.warp(FINALIZABLE + 1 hours);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementUnvetoed(address(nvda), E, FINALIZABLE + 1 hours + 6 hours);
        vm.prank(guardian);
        oracle.unveto(address(nvda), E);
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "Held -> Pending");
        (cp,,, at) = oracle.candidate(address(nvda), E);
        assertEq(cp + at, 0, "still no candidate to show");

        vm.warp(FINALIZABLE + 2 hours);
        uint40 candidateAt = FINALIZABLE + 2 hours + 6 hours;
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, P, 0, false, candidateAt);
        (finalized,) = _finalize();
        assertFalse(finalized, "announced first");
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "Pending");
        (cp,,, at) = oracle.candidate(address(nvda), E);
        assertEq(cp, P, "candidate view");
        assertEq(at, candidateAt, "candidate's own finalizableAt");

        vm.warp(FINALIZABLE + 1 hours + 6 hours);
        (finalized,) = _finalize();
        assertFalse(finalized, "the unveto's lower bound is not enough");
        vm.warp(candidateAt);
        (finalized,) = _finalize();
        assertTrue(finalized, "final after the candidate's delay");
    }

    /// Unveto before expiry (after a pre-emptive veto) leaves Pending without a candidate; finalize still reverts
    /// TooEarly until expiry + FINALIZE_DELAY and then proceeds normally.
    function test_unveto_beforeExpiry_thenNormalFlow() public {
        _useTwo();
        vm.startPrank(guardian);
        oracle.veto(address(nvda), E);
        oracle.unveto(address(nvda), E);
        vm.stopPrank();
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "Pending");
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, FINALIZABLE));
        oracle.finalize(address(nvda), E);

        s0.setWindow(true, P);
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        (bool finalized, uint256 price) = _finalize();
        assertTrue(finalized, "corroborated");
        assertEq(price, P, "price");
    }

    /// No source ok: (false, 0), nothing stored or emitted; a later call finds sources and proceeds.
    function test_noneOk_thenLaterOk() public {
        _useTwo();
        vm.warp(FINALIZABLE);
        vm.recordLogs();
        (bool finalized, uint256 price) = _finalize();
        assertFalse(finalized, "nothing ok");
        assertEq(price, 0, "no price");
        assertEq(vm.getRecordedLogs().length, 0, "no logs at all, no bounty");
        (,,,,, bool captured) = oracle.settlementInfo(address(nvda), E);
        assertFalse(captured, "nothing captured");
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.None), "None");
        (address[] memory srcs,,, uint16 pinnedDev) = oracle.recordedSources(address(nvda), E);
        assertEq(srcs.length, 0, "no recorded entries");
        assertEq(pinnedDev, 0, "nothing pinned");

        vm.warp(FINALIZABLE + 1 hours);
        s0.setWindow(true, P);
        s1.setWindow(true, P + 1_000);
        (finalized, price) = _finalize();
        assertTrue(finalized, "later ok");
        assertEq(price, P, "source 0");
    }

    /// TooEarly strictly before expiry + FINALIZE_DELAY.
    function test_finalize_tooEarly_onlyBeforeFinalizeDelay() public {
        _useTwo();
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        vm.warp(E);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, FINALIZABLE));
        oracle.finalize(address(nvda), E);
        vm.warp(FINALIZABLE - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, FINALIZABLE));
        oracle.finalize(address(nvda), E);
        vm.warp(FINALIZABLE);
        (bool finalized,) = oracle.finalize(address(nvda), E);
        assertTrue(finalized, "from expiry + 120 s");
    }

    /// Idempotent: a second call returns (true, price), emits nothing and pays nothing.
    function test_finalize_idempotent_noSecondEventNoBounty() public {
        _useTwo();
        _pinE();
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        uint256 paid = usdg.balanceOf(keeper);
        assertEq(paid, FINALIZE_BOUNTY, "first call paid");

        s0.setWindow(true, 1); // sources moving later changes nothing
        vm.warp(FINALIZABLE + 1 days);
        vm.recordLogs();
        (bool finalized, uint256 price) = _finalize();
        assertTrue(finalized, "still final");
        assertEq(price, P, "same price");
        assertEq(vm.getRecordedLogs().length, 0, "no event, no reward transfer");
        assertEq(usdg.balanceOf(keeper), paid, "no second bounty");
        (V2Types.SettlementStatus status, uint256 viewPrice) = oracle.settlementPrice(address(nvda), E);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "view status");
        assertEq(viewPrice, P, "view price");
    }

    /// settlementPrice returns 0 unless Finalized.
    function test_settlementPrice_zeroUntilFinal() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        (V2Types.SettlementStatus status, uint256 price) = oracle.settlementPrice(address(nvda), E);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Pending), "Pending");
        assertEq(price, 0, "0 while Pending");
    }

    /// A higher-priority source starting to answer changes the candidate and restarts the delay.
    function test_candidateChange_newIndex_restartsDelay() public {
        _useTwo();
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, P, 1, false, FINALIZABLE + 6 hours);
        _finalize();

        vm.warp(FINALIZABLE + 1 hours);
        s0.setWindow(true, 230_000_000);
        uint40 newAt = FINALIZABLE + 1 hours + 6 hours;
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 0, true, 230_000_000);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, 230_000_000, 0, true, newAt);
        _finalize();

        vm.warp(FINALIZABLE + 6 hours);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "the first candidate's delay no longer applies");
        vm.warp(newAt);
        uint256 price;
        (finalized, price) = _finalize();
        assertTrue(finalized, "new candidate final after its own delay");
        assertEq(price, 230_000_000, "new candidate's price");
    }

    /// A second source answering and disagreeing flips `disagreed` on the same candidate: announced again.
    function test_candidateChange_disagreedFlip_restartsDelay() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        vm.warp(FINALIZABLE + 5 minutes);
        s1.setWindow(true, 240_000_000);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, P, 0, true, FINALIZABLE + 5 minutes + 6 hours);
        _finalize();
    }

    /// Captured ok prices are never read again (Chainlink's replay dies later; an announced price must not move).
    function test_recordedPrice_neverReread() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        s0.setWindow(true, 300_000_000);
        vm.warp(FINALIZABLE + 6 hours);
        (bool finalized, uint256 price) = _finalize();
        assertTrue(finalized, "final");
        assertEq(price, P, "captured price, not the source's later answer");
        s0.setWindow(false, 0);
        (address[] memory srcs, bool[] memory ok, uint256[] memory prices, uint16 pinnedDev) =
            oracle.recordedSources(address(nvda), E);
        assertEq(pinnedDev, 150, "deviation pinned at capture");
        assertEq(srcs.length, 2, "two entries");
        assertEq(srcs[0], address(s0), "source 0 pinned");
        assertTrue(ok[0] && !ok[1], "ok flags");
        assertEq(prices[0], P, "captured");
        assertEq(prices[1], 0, "not ok: 0");
    }

    /// The source list is pinned at capture: a later setMarket neither adds voters nor shifts indexes.
    function test_sourcesPinnedAtCapture() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();

        s2.setWindow(true, P);
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s2), address(s0)), 0, 0, 0);
        vm.warp(FINALIZABLE + 1 hours);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "s2 was not a source when the expiry was captured");

        s1.setWindow(true, P);
        s2.setRecordable(true);
        _snapshot();
        assertEq(s2.recordCalls(), 0, "snapshot calls the pinned sources");
        assertEq(s1.recordCalls(), 1, "pinned source 1 asked to record");
        uint256 price;
        (finalized, price) = _finalize();
        assertTrue(finalized, "pinned source 1 corroborates");
        (,, uint8 idx,,,) = oracle.settlementInfo(address(nvda), E);
        assertEq(idx, 0, "index 0 is still s0");
        assertEq(price, P, "price");
    }

    /// Reverting, short, dirty-bool, zero and over-wide answers are not ok; they are recorded as such at capture.
    function test_malformedSources_notOk() public {
        _useThree();
        s0.setMode(MockOraclePriceSource.Mode.Reverts);
        s1.setMode(MockOraclePriceSource.Mode.ShortReply);
        s2.setMode(MockOraclePriceSource.Mode.DirtyOk);
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        s2.setWindow(true, P);
        vm.warp(FINALIZABLE);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "nothing usable");
        (,,,,, bool captured) = oracle.settlementInfo(address(nvda), E);
        assertFalse(captured, "not captured");

        s2.setMode(MockOraclePriceSource.Mode.Normal);
        s0.setMode(MockOraclePriceSource.Mode.Normal);
        s0.setWindow(true, 0);
        s1.setMode(MockOraclePriceSource.Mode.Normal);
        s1.setWindow(true, uint256(type(uint128).max) + 1);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 0, false, 0);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 1, false, 0);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 2, true, P);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementCandidate(address(nvda), E, P, 2, false, FINALIZABLE + 6 hours);
        _finalize();
    }

    /// The oracle asks for exactly [expiry - 1800, expiry]: the mock answers nothing else, and an expiry inside the first
    /// 1800 s of unix time has no window.
    function test_window_exactSpan_andTinyExpiry() public {
        _useTwo();
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        (bool finalized,) = _finalize();
        assertTrue(finalized, "mock accepted the span");

        vm.prank(keeper);
        (finalized,) = oracle.finalize(address(nvda), 1000);
        assertFalse(finalized, "no window before unix time 1800");
    }

    /// Another expiry of the same market and the same expiry of another market are independent.
    function test_settlements_independentPerUnderlyingAndExpiry() public {
        _useTwo();
        vm.prank(admin);
        oracle.setMarket(address(tsla), _list(address(s0), address(s1)), 0, 0, 0);
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        (bool finalized,) = oracle.finalize(address(tsla), E);
        assertFalse(finalized, "tsla pending");
        (V2Types.SettlementStatus st,) = oracle.settlementPrice(address(tsla), E);
        assertEq(uint8(st), uint8(V2Types.SettlementStatus.Pending), "tsla unaffected by the nvda veto");
        (st,) = oracle.settlementPrice(address(nvda), FRI_2026_09_11);
        assertEq(uint8(st), uint8(V2Types.SettlementStatus.None), "other expiry untouched");
    }

    /*//////////////////////////////////////////////////////////////
                                SNAPSHOT
    //////////////////////////////////////////////////////////////*/

    function test_snapshot_tooEarlyBeforeExpiry() public {
        _useTwo();
        vm.warp(E - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, E));
        oracle.snapshot(address(nvda), E);
    }

    /// Calls record on every source, counts first-time recordings, and is idempotent.
    function test_snapshot_countsNewRecordings_idempotent() public {
        _useThree();
        s0.setRecordable(true);
        s2.setRecordable(true);
        vm.warp(E);
        assertEq(_snapshot(), 2, "two sources recorded");
        assertEq(s1.recordCalls(), 1, "every source asked");
        assertEq(_snapshot(), 0, "second snapshot records nothing");
    }

    /// A reverting source and one that re-enters the oracle count as not recorded and do not stop the others.
    function test_snapshot_badSourcesDoNotStopOthers() public {
        _useThree();
        s0.setMode(MockOraclePriceSource.Mode.Reverts);
        s1.setRecordable(true);
        s1.setReenter(address(oracle), abi.encodeCall(ISettlementOracle.finalize, (address(nvda), E)));
        s2.setRecordable(true);
        vm.warp(FINALIZABLE);
        assertEq(_snapshot(), 1, "only source 2");
        assertFalse(s1.recorded(address(nvda), E), "re-entry reverted the source's record");
        assertTrue(s2.recorded(address(nvda), E), "source 2 recorded");
    }

    /// Once final, snapshot returns 0 without calling any source.
    function test_snapshot_afterFinal_noCalls() public {
        _useTwo();
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        s0.setRecordable(true);
        vm.warp(FINALIZABLE);
        _finalize();
        assertEq(_snapshot(), 0, "nothing to do");
        assertEq(s0.recordCalls(), 0, "no source called");
    }
}

/*//////////////////////////////////////////////////////////////
                               BOUNTIES
//////////////////////////////////////////////////////////////*/

/// @notice SNAPSHOT and FINALIZE bounties: only with open interest, only for calls that advance, never to the
///         Clearinghouse, never able to break the call.
contract SettlementOracleBountyTest is SettlementOracleFixture {
    function test_snapshotBounty_paidOnceWithOpenInterest() public {
        _useTwo();
        _pinE();
        s0.setRecordable(true);
        s1.setRecordable(true);
        vm.warp(E);
        vm.expectEmit(address(rewards));
        emit IKeeperRewards.Rewarded(keeper, V2Constants.ACTION_SNAPSHOT, SNAPSHOT_BOUNTY);
        assertEq(_snapshot(), 2, "recorded");
        assertEq(usdg.balanceOf(keeper), SNAPSHOT_BOUNTY, "one bounty per call, not per source");
        _snapshot();
        assertEq(usdg.balanceOf(keeper), SNAPSHOT_BOUNTY, "nothing new recorded, no bounty");
    }

    function test_snapshotBounty_noOpenInterest() public {
        _useTwo();
        _pinE();
        s0.setRecordable(true);
        ch.setOpenInterest(address(nvda), E, 0);
        vm.warp(E);
        assertEq(_snapshot(), 1, "still records");
        assertEq(usdg.balanceOf(keeper), 0, "empty expiry pays nothing");
    }

    /// FINALIZE pays per advancing call (capture + candidate, then finalization), nothing inside the delay or after.
    function test_finalizeBounty_paidPerAdvance() public {
        _useTwo();
        _pinE();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        vm.expectEmit(address(rewards));
        emit IKeeperRewards.Rewarded(keeper, V2Constants.ACTION_FINALIZE, FINALIZE_BOUNTY);
        _finalize();
        assertEq(usdg.balanceOf(keeper), FINALIZE_BOUNTY, "candidate announced");
        vm.warp(FINALIZABLE + 1 hours);
        _finalize();
        assertEq(usdg.balanceOf(keeper), FINALIZE_BOUNTY, "inside the delay: nothing");
        vm.warp(FINALIZABLE + 6 hours);
        _finalize();
        assertEq(usdg.balanceOf(keeper), 2 * FINALIZE_BOUNTY, "finalization");
        _finalize();
        assertEq(usdg.balanceOf(keeper), 2 * FINALIZE_BOUNTY, "idempotent");
    }

    function test_finalizeBounty_noOpenInterest() public {
        _useTwo();
        _pinE();
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        ch.setOpenInterest(address(nvda), E, 0);
        vm.warp(FINALIZABLE);
        (bool finalized,) = _finalize();
        assertTrue(finalized, "finalizes anyway");
        assertEq(usdg.balanceOf(keeper), 0, "no bounty");
    }

    function test_finalizeBounty_notWhenNothingOk() public {
        _useTwo();
        _pinE();
        vm.warp(FINALIZABLE);
        _finalize();
        assertEq(usdg.balanceOf(keeper), 0, "no advance, no bounty");
    }

    /// Clearinghouse.settle's internal finalize: the Clearinghouse is msg.sender and is not paid.
    function test_finalizeBounty_notPaidToClearinghouse() public {
        _useTwo();
        _pinE();
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        vm.recordLogs();
        vm.prank(keeper);
        (bool finalized, uint256 price) = ch.settleFinalize(oracle, address(nvda), E);
        assertTrue(finalized, "final");
        assertEq(price, P, "price");
        assertEq(_logsFrom(address(rewards)), 0, "no Rewarded");
        assertEq(usdg.balanceOf(address(ch)) + usdg.balanceOf(keeper), 0, "nobody paid");
    }

    function test_bounty_missingPointers_noBounty() public {
        _useTwo();
        _pinE();
        s0.setWindow(true, P);
        s0.setRecordable(true);
        vm.prank(admin);
        oracle.setKeeperRewards(address(0));
        vm.warp(FINALIZABLE);
        _snapshot();
        _finalize();
        assertEq(usdg.balanceOf(keeper), 0, "no rewards pointer");

        vm.startPrank(admin);
        oracle.setKeeperRewards(address(rewards));
        oracle.setClearinghouse(address(0));
        vm.stopPrank();
        vm.warp(FINALIZABLE + 6 hours);
        (bool finalized,) = _finalize();
        assertTrue(finalized, "final");
        assertEq(usdg.balanceOf(keeper), 0, "no clearinghouse pointer");
    }

    /// A reverting open-interest read, a reverting reward and a code-less rewards pointer never break the call.
    function test_bounty_failuresNeverRevert() public {
        _useTwo();
        _pinE();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        ch.setReverts(true);
        _finalize();
        assertEq(usdg.balanceOf(keeper), 0, "openInterest reverted: no bounty");
        ch.setReverts(false);

        vm.prank(admin);
        rewards.setCaller(address(oracle), false); // reward() now reverts NotAuthorized
        s1.setWindow(true, 240_000_000);
        vm.warp(FINALIZABLE + 1 minutes);
        _finalize();
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "advanced despite the revert");

        vm.prank(admin);
        oracle.setKeeperRewards(makeAddr("no code"));
        vm.warp(FINALIZABLE + 1 minutes + 6 hours);
        (bool finalized,) = _finalize();
        assertTrue(finalized, "code-less rewards pointer is harmless");
        assertEq(usdg.balanceOf(keeper), 0, "never paid");
    }

    /// @dev Sweep contracts-c11, part 1. The open-interest gate reads the Clearinghouse's open interest of the whole
    ///      (underlying, expiry), whichever oracle its series settle on. A second oracle sharing the sources during a
    ///      market migration has no series of E, yet a keeper could capture, announce and finalize E there and collect
    ///      a SNAPSHOT and a FINALIZE bounty per advance on top of the real oracle's. A bounty now also needs E pinned
    ///      on this oracle by the current Clearinghouse.
    function test_bounty_notPaidOnAnExpiryTheClearinghouseDidNotPinHere() public {
        _useTwo();
        s0.setRecordable(true);
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        assertEq(_snapshot(), 1, "records");
        (bool finalized,) = _finalize();
        assertTrue(finalized, "finalizes");
        assertEq(usdg.balanceOf(keeper), 0, "open interest on E, but no series of E on this oracle: no bounty");

        uint40 friday = FRI_2026_09_11;
        ch.setOpenInterest(address(nvda), friday, 1_000);
        vm.prank(address(ch));
        oracle.pin(address(nvda), friday);
        vm.warp(friday + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        oracle.snapshot(address(nvda), friday);
        vm.prank(keeper);
        oracle.finalize(address(nvda), friday);
        assertEq(usdg.balanceOf(keeper), SNAPSHOT_BOUNTY + FINALIZE_BOUNTY, "a pinned expiry still pays");
    }

    /// @dev Sweep contracts-c11, part 2. After a Clearinghouse migration (setClearinghouse(ch2)) the old
    ///      Clearinghouse's settle still calls finalize, and it is no longer `clearinghouse`, so the FINALIZE bounty
    ///      went to the old Clearinghouse, where no function moves USDG it did not account for. Now an expiry the old
    ///      Clearinghouse pinned pays nothing until ch2 confirms the pin, and the confirmation marks the old
    ///      Clearinghouse as a replaced pinner that is never paid. A keeper is paid again once ch2 pinned E.
    function test_bounty_neverPaidToAClearinghouseThePinMovedFrom() public {
        _useTwo();
        _pinE();
        MockOpenInterestClearinghouse ch2 = new MockOpenInterestClearinghouse();
        ch2.setOpenInterest(address(nvda), E, 500);
        vm.prank(admin);
        oracle.setClearinghouse(address(ch2));

        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        vm.prank(keeper);
        ch.settleFinalize(oracle, address(nvda), E);
        assertEq(usdg.balanceOf(address(ch)), 0, "old Clearinghouse: not paid");
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "a candidate was announced");

        vm.prank(address(ch2));
        oracle.pin(address(nvda), E);
        assertEq(oracle.pinnedBy(address(nvda), E), address(ch2), "ch2 confirmed E");
        s1.setWindow(true, 240_000_000);
        vm.warp(FINALIZABLE + 1 minutes);
        ch.settleFinalize(oracle, address(nvda), E);
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "a new candidate was announced");
        assertEq(usdg.balanceOf(address(ch)), 0, "old Clearinghouse after the confirmation: still not paid");

        vm.warp(FINALIZABLE + 1 minutes + 6 hours);
        (bool finalized,) = _finalize();
        assertTrue(finalized, "final");
        assertEq(usdg.balanceOf(keeper), FINALIZE_BOUNTY, "a keeper is paid on the expiry ch2 pinned");
    }
}

/*//////////////////////////////////////////////////////////////
                       ADMIN RESOLVE, VETO RULES
//////////////////////////////////////////////////////////////*/

/// @notice adminResolve timing and band, AlreadyFinal rules, and who may call what.
contract SettlementOracleResolveTest is SettlementOracleFixture {
    uint40 internal constant RESOLVABLE = E + V2Constants.RESOLVE_DELAY;

    /// Recorded 200e6 and 220e6 (disagree): band [200e6 x 0.985, 220e6 x 1.015] = [197e6, 223.3e6].
    function _pendingTwoPrices() internal {
        _useTwo();
        s0.setWindow(true, 200_000_000);
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
    }

    function test_adminResolve_beforeDelayReverts() public {
        _pendingTwoPrices();
        vm.warp(RESOLVABLE - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.TooEarly.selector, RESOLVABLE));
        oracle.adminResolve(address(nvda), E, 210_000_000);
    }

    function test_adminResolve_outOfBandReverts() public {
        _pendingTwoPrices();
        (bool bounded, uint256 lo, uint256 hi) = oracle.resolveBand(address(nvda), E);
        assertTrue(bounded, "bounded");
        assertEq(lo, 197_000_000, "lo");
        assertEq(hi, 223_300_000, "hi");
        vm.warp(RESOLVABLE);
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, lo, hi));
        oracle.adminResolve(address(nvda), E, lo - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, lo, hi));
        oracle.adminResolve(address(nvda), E, hi + 1);
        vm.stopPrank();
    }

    function test_adminResolve_inBandSucceedsAndEmits() public {
        _pendingTwoPrices();
        vm.warp(RESOLVABLE);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementResolved(address(nvda), E, 223_300_000);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), E, 223_300_000); // the inclusive upper edge
        (V2Types.SettlementStatus status, uint256 price,,, bool resolved,) = oracle.settlementInfo(address(nvda), E);
        assertEq(uint8(status), uint8(V2Types.SettlementStatus.Finalized), "Finalized");
        assertEq(price, 223_300_000, "admin price");
        assertTrue(resolved, "resolved");
        vm.recordLogs();
        (bool finalized, uint256 p) = _finalize();
        assertTrue(finalized && p == 223_300_000, "finalize returns the resolved price");
        assertEq(vm.getRecordedLogs().length, 0, "silently");
    }

    function test_adminResolve_lowerEdgeAccepted() public {
        _pendingTwoPrices();
        vm.warp(RESOLVABLE);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), E, 197_000_000);
        (, uint256 price) = oracle.settlementPrice(address(nvda), E);
        assertEq(price, 197_000_000, "inclusive lower edge");
    }

    function test_adminResolve_cannotResolveFinalized() public {
        _useTwo();
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        vm.warp(RESOLVABLE);
        vm.prank(admin);
        vm.expectRevert(V2Errors.AlreadyFinal.selector);
        oracle.adminResolve(address(nvda), E, P);
    }

    function test_adminResolve_heldExpiry() public {
        _pendingTwoPrices();
        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        vm.warp(RESOLVABLE);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), E, 210_000_000);
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Finalized), "held expiry resolved");
    }

    /// @dev Sweep contracts-c12. A single ok source that is wrong by more than maxDeviationBps (a stalled feed, a scale
    ///      fault inside the jump bound, a pushed pool with the other source missing) becomes a candidate. The guardian
    ///      vetoes it, and nothing can record a second price afterwards. The band was that price +- 150 bps forever, so
    ///      the only choices were a wrong settlement or collateral held forever. Now, from expiry + 7 days, a Held
    ///      expiry with exactly one ok recorded price resolves inside [p x 0.8, p / 0.8]: a factor of 1.25 either way,
    ///      which reaches the true price behind any print the default 2000 bps jump rule lets through.
    function test_adminResolve_heldSingleSource_widensAfterSevenDays() public {
        _useTwo();
        s0.setWindow(true, P); // 220.00; the market traded at 200.00
        vm.warp(FINALIZABLE);
        _finalize();
        vm.prank(guardian);
        oracle.veto(address(nvda), E);

        vm.warp(RESOLVABLE);
        (bool bounded, uint256 lo, uint256 hi) = oracle.resolveBand(address(nvda), E);
        assertTrue(bounded, "bounded");
        assertEq(lo, 216_700_000, "from E + 48 h: 220 x 0.985");
        assertEq(hi, 223_300_000, "and 220 x 1.015");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, lo, hi));
        oracle.adminResolve(address(nvda), E, 200_000_000);

        vm.warp(E + 7 days - 1);
        (, lo, hi) = oracle.resolveBand(address(nvda), E);
        assertEq(lo + hi, 216_700_000 + 223_300_000, "one second before E + 7 days: still the pinned deviation");

        vm.warp(E + 7 days);
        (bounded, lo, hi) = oracle.resolveBand(address(nvda), E);
        assertTrue(bounded, "still bounded");
        assertEq(lo, 176_000_000, "220 x 0.8");
        assertEq(hi, 275_000_000, "220 / 0.8");
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, lo, hi));
        oracle.adminResolve(address(nvda), E, lo - 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, lo, hi));
        oracle.adminResolve(address(nvda), E, hi + 1);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementResolved(address(nvda), E, 200_000_000);
        oracle.adminResolve(address(nvda), E, 200_000_000);
        vm.stopPrank();
        (, uint256 price) = oracle.settlementPrice(address(nvda), E);
        assertEq(price, 200_000_000, "the market price");
    }

    /// @dev The wider band of contracts-c12 is only for a HELD expiry with exactly ONE ok recorded price. A Pending
    ///      single source keeps the pinned deviation (nobody vetoed it). So do two disagreeing prices, whose band
    ///      already spans both. And so does a vetoed single source that the resolve's own refresh joins with a second
    ///      price, which the band is then checked against.
    function test_adminResolve_wideBandOnlyForAHeldExpiryWithOneOkPrice() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        vm.warp(E + 7 days);
        (, uint256 lo, uint256 hi) = oracle.resolveBand(address(nvda), E);
        assertEq(lo, 216_700_000, "Pending, not vetoed: the pinned deviation");
        assertEq(hi, 223_300_000, "Pending, not vetoed: the pinned deviation");

        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        s1.setWindow(true, 205_000_000); // recorded by the resolve's refresh
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, 201_925_000, 223_300_000));
        oracle.adminResolve(address(nvda), E, 200_000_000);

        _finalize(); // records the second price outside a resolve
        (, lo, hi) = oracle.resolveBand(address(nvda), E);
        assertEq(lo, 201_925_000, "Held with two disagreeing prices: 205 x 0.985");
        assertEq(hi, 223_300_000, "and 220 x 1.015");
    }

    /// With no ok recorded source any positive price fits uint128; 0 and wider prices are BadPrice.
    function test_adminResolve_noSources_anyPrice_badPrice() public {
        _useTwo();
        vm.warp(RESOLVABLE);
        vm.startPrank(admin);
        vm.expectRevert(V2Errors.BadPrice.selector);
        oracle.adminResolve(address(nvda), E, 0);
        vm.expectRevert(V2Errors.BadPrice.selector);
        oracle.adminResolve(address(nvda), E, uint256(type(uint128).max) + 1);
        (bool bounded,,) = oracle.resolveBand(address(nvda), E);
        assertFalse(bounded, "unbounded");
        oracle.adminResolve(address(nvda), E, 1);
        vm.stopPrank();
        (, uint256 price) = oracle.settlementPrice(address(nvda), E);
        assertEq(price, 1, "any price");
    }

    /// Nobody finalized, but a source answers: adminResolve captures first, so the band still applies.
    function test_adminResolve_capturesBeforeBand() public {
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(RESOLVABLE);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, 216_700_000, 223_300_000));
        oracle.adminResolve(address(nvda), E, 300_000_000);

        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SourceRecorded(address(nvda), E, 0, true, P);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementResolved(address(nvda), E, 221_000_000);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), E, 221_000_000);
    }

    function test_adminResolve_onlyAdmin() public {
        _pendingTwoPrices();
        vm.warp(RESOLVABLE);
        vm.prank(guardian);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        oracle.adminResolve(address(nvda), E, P);
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        oracle.adminResolve(address(nvda), E, P);
    }

    function test_veto_onlyGuardian_andAlreadyFinal() public {
        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        oracle.veto(address(nvda), E);
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        oracle.veto(address(nvda), E);

        _useTwo();
        s0.setWindow(true, P);
        s1.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        vm.prank(guardian);
        vm.expectRevert(V2Errors.AlreadyFinal.selector);
        oracle.veto(address(nvda), E);
        vm.prank(guardian);
        vm.expectRevert(V2Errors.AlreadyFinal.selector);
        oracle.unveto(address(nvda), E);
    }

    function test_veto_whileHeld_noop() public {
        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        vm.recordLogs();
        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        assertEq(vm.getRecordedLogs().length, 0, "no second event");
    }

    function test_unveto_rolesAndNoopUnlessHeld() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        oracle.unveto(address(nvda), E);

        vm.recordLogs();
        vm.prank(guardian);
        oracle.unveto(address(nvda), E); // None
        assertEq(vm.getRecordedLogs().length, 0, "no-op on None");
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.None), "still None");
        _useTwo();
        s0.setWindow(true, P);
        vm.warp(FINALIZABLE);
        _finalize();
        vm.getRecordedLogs();
        vm.prank(admin);
        oracle.unveto(address(nvda), E); // Pending
        assertEq(vm.getRecordedLogs().length, 0, "no-op");
        assertEq(uint8(_status()), uint8(V2Types.SettlementStatus.Pending), "unchanged");
    }

    function test_constructor_zeroAdminReverts_zeroGuardianGrantsNothing() public {
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new SettlementOracle(address(0), guardian);
        SettlementOracle o = new SettlementOracle(admin, address(0));
        assertTrue(o.hasRole(V2Constants.DEFAULT_ADMIN_ROLE, admin), "admin");
        assertFalse(o.hasRole(V2Constants.GUARDIAN_ROLE, address(0)), "no zero guardian");
        assertTrue(oracle.hasRole(V2Constants.GUARDIAN_ROLE, guardian), "fixture guardian");
        assertEq(oracle.SETTLEMENT_WINDOW(), 1800, "window");
    }
}

/*//////////////////////////////////////////////////////////////
                          CONFIGURATION, SPOT
//////////////////////////////////////////////////////////////*/

/// @notice Market configuration bounds, defaults, roles and events; the pointers; spot freshness, paused flag and
///         source-0-only rule.
contract SettlementOracleConfigTest is SettlementOracleFixture {
    function test_marketConfig_defaultsBeforeAndAfterSet() public {
        (address[] memory srcs, uint16 dev, uint32 delay, uint32 age) = oracle.marketConfig(address(nvda));
        assertEq(srcs.length, 0, "unconfigured");
        assertEq(dev, 150, "default deviation");
        assertEq(delay, 6 hours, "default delay");
        assertEq(age, 1 hours, "default spot age");

        address[] memory list = _list(address(s0), address(s1));
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.MarketSourcesSet(address(nvda));
        vm.expectEmit(address(oracle));
        emit SettlementOracle.MarketConfigured(address(nvda), list, 150, 6 hours, 1 hours);
        vm.prank(admin);
        oracle.setMarket(address(nvda), list, 0, 0, 0);
        (srcs, dev, delay, age) = oracle.marketConfig(address(nvda));
        assertEq(srcs.length, 2, "two sources");
        assertEq(srcs[1], address(s1), "priority order kept");
        assertEq(dev + delay + age, 150 + 6 hours + 1 hours, "defaults stored");
    }

    function test_setMarket_bounds() public {
        address[] memory one = _list(address(s0));
        vm.startPrank(admin);
        oracle.setMarket(address(nvda), one, 1000, 30 minutes, 4 days);
        oracle.setMarket(address(nvda), one, 1, 24 hours, 1);

        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        oracle.setMarket(address(nvda), one, 1001, 0, 0);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        oracle.setMarket(address(nvda), one, 0, 30 minutes - 1, 0);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        oracle.setMarket(address(nvda), one, 0, 24 hours + 1, 0);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        oracle.setMarket(address(nvda), one, 0, 0, 4 days + 1);

        address[] memory nine = new address[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = address(new MockOraclePriceSource());
        }
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        oracle.setMarket(address(nvda), nine, 0, 0, 0);
        address[] memory eight = new address[](8);
        for (uint256 i; i < 8; ++i) {
            eight[i] = nine[i];
        }
        oracle.setMarket(address(nvda), eight, 0, 0, 0);

        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.setMarket(address(nvda), _list(address(s0), address(0)), 0, 0, 0);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.setMarket(address(nvda), _list(address(s0), makeAddr("eoa")), 0, 0, 0);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1), address(s0)), 0, 0, 0);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        oracle.setMarket(address(0), one, 0, 0, 0);

        oracle.setMarket(address(nvda), new address[](0), 0, 0, 0);
        vm.stopPrank();
        (address[] memory srcs,,,) = oracle.marketConfig(address(nvda));
        assertEq(srcs.length, 0, "empty list disables the market");
    }

    function test_adminSetters_onlyAdmin() public {
        address[] memory one = _list(address(s0));
        address[2] memory notAdmin = [guardian, stranger];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(notAdmin[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            oracle.setMarket(address(nvda), one, 0, 0, 0);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            oracle.setClearinghouse(address(ch));
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            oracle.setKeeperRewards(address(rewards));
            vm.stopPrank();
        }
        vm.expectEmit(address(oracle));
        emit SettlementOracle.ClearinghouseSet(address(1));
        vm.prank(admin);
        oracle.setClearinghouse(address(1));
        vm.expectEmit(address(oracle));
        emit SettlementOracle.KeeperRewardsSet(address(2));
        vm.prank(admin);
        oracle.setKeeperRewards(address(2));
        assertEq(oracle.clearinghouse(), address(1), "clearinghouse");
        assertEq(oracle.keeperRewards(), address(2), "keeperRewards");
    }

    /// A captured expiry keeps its maxDeviationBps: widening it cannot force a pending disagreement to corroborate, nor
    /// widen its resolve band. A delay change never moves a published finalizableAt. An expiry captured after the
    /// change uses the new deviation.
    function test_paramChanges_pinnedForCapturedExpiry() public {
        _useTwo();
        s0.setWindow(true, P);
        s1.setWindow(true, 230_000_000); // 454 bps apart
        vm.warp(FINALIZABLE);
        _finalize();
        (,,, uint40 at) = oracle.candidate(address(nvda), E);
        (, uint256 lo, uint256 hi) = oracle.resolveBand(address(nvda), E);

        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 500, 24 hours, 0);
        (,,, uint40 atAfter) = oracle.candidate(address(nvda), E);
        assertEq(atAfter, at, "delay change does not move the candidate");
        (bool finalized,) = _finalize();
        assertFalse(finalized, "the pinned 150 bps still disagrees");
        (, uint256 lo2, uint256 hi2) = oracle.resolveBand(address(nvda), E);
        assertEq(lo2 + hi2, lo + hi, "band keeps the pinned deviation");
        assertEq(lo, 216_700_000, "220e6 x 0.985");

        uint40 friday = FRI_2026_09_11;
        ch.setOpenInterest(address(nvda), friday, 1);
        vm.warp(friday + V2Constants.FINALIZE_DELAY);
        uint256 price;
        (finalized, price) = oracle.finalize(address(nvda), friday);
        assertTrue(finalized, "captured after the change: 500 bps corroborates");
        assertEq(price, P, "source 0");
        (,,, uint16 pinnedDev) = oracle.recordedSources(address(nvda), friday);
        assertEq(pinnedDev, 500, "new deviation pinned");
    }

    /// An empty source list: spot has no source and uncaptured expiries find nothing.
    function test_emptyMarket_disablesSpotAndFinalize() public {
        vm.prank(admin);
        oracle.setMarket(address(nvda), new address[](0), 0, 0, 0);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.spot(address(nvda));
        vm.warp(FINALIZABLE);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "nothing to ask");
    }

    /*//////////////////////////////////////////////////////////////
                                   SPOT
    //////////////////////////////////////////////////////////////*/

    function test_spot_fresh_andAgeBoundary() public {
        _useTwo();
        s0.setLatest(true, P, block.timestamp);
        (uint256 price, uint256 updatedAt) = oracle.spot(address(nvda));
        assertEq(price, P, "price");
        assertEq(updatedAt, block.timestamp, "updatedAt");

        s0.setLatest(true, P, block.timestamp - 1 hours);
        (price,) = oracle.spot(address(nvda));
        assertEq(price, P, "exactly spotMaxAge old is fresh");

        uint256 stale = block.timestamp - 1 hours - 1;
        s0.setLatest(true, P, stale);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.StaleSpot.selector, stale));
        oracle.spot(address(nvda));
        (bool ok, uint256 p, uint256 t) = oracle.trySpot(address(nvda));
        assertFalse(ok, "trySpot not ok");
        assertEq(p + t, 0, "zeros");
    }

    function test_spot_customMaxAge() public {
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0)), 0, 0, 2 days);
        s0.setLatest(true, P, block.timestamp - 2 days);
        (bool ok,,) = oracle.trySpot(address(nvda));
        assertTrue(ok, "within 2 days");
    }

    function test_spot_pausedFlag() public {
        _useTwo();
        s0.setLatest(true, P, block.timestamp);
        nvda.setOraclePaused(true);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.spot(address(nvda));
        (bool ok,,) = oracle.trySpot(address(nvda));
        assertFalse(ok, "paused");
        nvda.setOraclePaused(false);
        (ok,,) = oracle.trySpot(address(nvda));
        assertTrue(ok, "unpaused");
    }

    /// A token without oraclePaused() fails closed.
    function test_spot_unreadablePausedFlag_failsClosed() public {
        vm.prank(admin);
        oracle.setMarket(address(usdg), _list(address(s0)), 0, 0, 0);
        s0.setLatest(true, P, block.timestamp);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.spot(address(usdg));
    }

    /// Only source 0 serves spot; not ok, malformed, zero, future-stamped answers have no source.
    function test_spot_sourceZeroOnly_andBadAnswers() public {
        _useTwo();
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.spot(address(tsla)); // no sources

        s1.setLatest(true, P, block.timestamp);
        s0.setLatest(false, P, block.timestamp);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.spot(address(nvda));

        s0.setLatest(true, 0, block.timestamp);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.spot(address(nvda));

        s0.setLatest(true, P, block.timestamp + 1);
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.spot(address(nvda));

        s0.setLatest(true, P, block.timestamp);
        MockOraclePriceSource.Mode[3] memory modes = [
            MockOraclePriceSource.Mode.Reverts,
            MockOraclePriceSource.Mode.ShortReply,
            MockOraclePriceSource.Mode.DirtyOk
        ];
        for (uint256 i; i < 3; ++i) {
            s0.setMode(modes[i]);
            vm.expectRevert(V2Errors.NoSource.selector);
            oracle.spot(address(nvda));
            (bool ok,,) = oracle.trySpot(address(nvda));
            assertFalse(ok, "malformed");
        }
    }
}

/*//////////////////////////////////////////////////////////////
                               PROPERTY
//////////////////////////////////////////////////////////////*/

/// @notice Property: whatever sequence of source answers, finalize calls, vetoes, unvetoes, admin resolutions and time
///         steps happens, a Finalized price equals a recorded ok source price (the corroborating one, or the first ok
///         candidate once nothing corroborates) or an admin price inside the recorded band (the wider band of a Held
///         expiry with one ok price from expiry + 7 days, sweep contracts-c12); recorded ok prices equal
///         what the source answered when recorded and never change; a final price never changes.
contract SettlementOraclePropertyTest is SettlementOracleFixture {
    uint256 private _seed;
    uint256 private _nonce;

    bool private _wasFinal;
    uint256 private _finalPrice;
    /// @dev The admin resolution was of a Held expiry with exactly one ok recorded price at or after E + 7 days.
    bool private _resolvedWide;
    bool[3] private _okSeen;
    uint256[3] private _priceSeen;

    function _rand() private returns (uint256) {
        return uint256(keccak256(abi.encode(_seed, _nonce++)));
    }

    function _source(uint256 i) private view returns (MockOraclePriceSource) {
        return i == 0 ? s0 : i == 1 ? s1 : s2;
    }

    /// Prices cluster around 220e6 so that some pairs agree and some do not; about a third of answers are not ok.
    function _script(uint256 i) private {
        uint256 r = _rand();
        bool ok = r % 3 != 0;
        uint256 price = (r >> 8) % 2 == 0 ? P + ((r >> 16) % 2_000_000) : 180_000_000 + ((r >> 16) % 80_000_000);
        _source(i).setWindow(ok, price);
    }

    function testFuzz_finalPriceIsRecordedSourceOrInBandAdmin(uint256 seed) public {
        _seed = seed;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 dev = uint16(bound(_rand(), 1, 1000));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 delay = uint32(bound(_rand(), 30 minutes, 24 hours));
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1), address(s2)), dev, delay, 0);
        for (uint256 i; i < 3; ++i) {
            _script(i);
        }
        vm.warp(FINALIZABLE);

        for (uint256 step; step < 24; ++step) {
            uint256 action = _rand() % 8;
            if (action == 0) {
                vm.warp(block.timestamp + bound(_rand(), 1, 12 hours));
            } else if (action == 1 || action == 2) {
                _checkedCall(0, 0);
            } else if (action == 3) {
                vm.prank(guardian);
                try oracle.veto(address(nvda), E) {} catch {}
            } else if (action == 4) {
                vm.prank(_rand() % 2 == 0 ? guardian : admin);
                try oracle.unveto(address(nvda), E) {} catch {}
            } else if (action == 5) {
                _script(_rand() % 3);
            } else if (action == 6) {
                if (block.timestamp < E + V2Constants.RESOLVE_DELAY && _rand() % 2 == 0) {
                    vm.warp(E + V2Constants.RESOLVE_DELAY);
                }
                if (vm.getBlockTimestamp() < E + 7 days && _rand() % 4 == 0) vm.warp(E + 7 days); // the wide band's start
                _checkedCall(1, 150_000_000 + _rand() % 150_000_000);
            } else {
                _checkedCall(2, 0);
            }
            _checkProperty(dev);
        }
    }

    /// kind 0: finalize by a keeper; 1: adminResolve(price); 2: finalize through the Clearinghouse. Checks that every
    /// entry that became ok in the call recorded the source's current answer.
    function _checkedCall(uint256 kind, uint256 price) private {
        if (kind == 1) {
            bool wasHeld = _statusIs(V2Types.SettlementStatus.Held);
            vm.prank(admin);
            try oracle.adminResolve(address(nvda), E, price) {
                (, bool[] memory okAfter,,) = oracle.recordedSources(address(nvda), E);
                uint256 okCount;
                for (uint256 i; i < okAfter.length; ++i) {
                    if (okAfter[i]) ++okCount;
                }
                // vm.getBlockTimestamp: via_ir may fold a later block.timestamp read to its first value in the frame
                _resolvedWide = wasHeld && okCount == 1 && vm.getBlockTimestamp() >= E + 7 days;
            } catch {}
        } else if (kind == 0) {
            _finalize();
        } else {
            ch.settleFinalize(oracle, address(nvda), E);
        }
        (address[] memory srcs, bool[] memory ok, uint256[] memory prices,) = oracle.recordedSources(address(nvda), E);
        for (uint256 i; i < srcs.length; ++i) {
            assertEq(srcs[i], address(_source(i)), "pinned in priority order");
            if (_okSeen[i]) {
                assertTrue(ok[i], "ok never reverts to not ok");
                assertEq(prices[i], _priceSeen[i], "recorded ok price never changes");
            } else if (ok[i]) {
                MockOraclePriceSource s = _source(i);
                assertTrue(s.windowOk(), "recorded ok only from an ok answer");
                assertEq(prices[i], s.windowAnswer(), "recorded the answer given");
                (_okSeen[i], _priceSeen[i]) = (true, prices[i]);
            }
        }
    }

    function _statusIs(V2Types.SettlementStatus want) private view returns (bool) {
        (V2Types.SettlementStatus status,) = oracle.settlementPrice(address(nvda), E);
        return status == want;
    }

    function _checkProperty(uint256 dev) private {
        (V2Types.SettlementStatus status, uint256 price, uint8 idx, bool corroborated, bool resolved,) =
            oracle.settlementInfo(address(nvda), E);
        if (status != V2Types.SettlementStatus.Finalized) {
            assertFalse(_wasFinal, "final is final");
            assertEq(price, 0, "no price before final");
            return;
        }
        if (_wasFinal) {
            assertEq(price, _finalPrice, "final price never changes");
            return;
        }
        (_wasFinal, _finalPrice) = (true, price);

        (, bool[] memory ok, uint256[] memory prices, uint16 pinnedDev) = oracle.recordedSources(address(nvda), E);
        if (ok.length != 0) assertEq(pinnedDev, dev, "deviation pinned at capture");
        if (resolved) {
            bool bounded;
            uint256 lo = type(uint256).max;
            uint256 hi;
            for (uint256 i; i < ok.length; ++i) {
                if (!ok[i]) continue;
                bounded = true;
                if (prices[i] < lo) lo = prices[i];
                if (prices[i] > hi) hi = prices[i];
            }
            if (bounded && _resolvedWide) {
                assertEq(lo, hi, "the wide band is around one price");
                assertGe(price, lo * 8_000 / 10_000, "admin price above the wide band floor");
                assertLe(price, hi * 10_000 / 8_000, "admin price below the wide band ceiling");
            } else if (bounded) {
                assertGe(price, lo * (10_000 - dev) / 10_000, "admin price above the band floor");
                assertLe(price, hi * (10_000 + dev) / 10_000, "admin price below the band ceiling");
            }
            return;
        }

        assertTrue(ok[idx], "finalizing source was ok");
        assertEq(price, prices[idx], "final price is that source's recorded price");
        bool anyPairAgrees;
        uint256 firstAgreeing = type(uint256).max;
        uint256 firstOk = type(uint256).max;
        for (uint256 i; i < ok.length; ++i) {
            if (!ok[i]) continue;
            if (firstOk == type(uint256).max) firstOk = i;
            for (uint256 j; j < ok.length; ++j) {
                if (i == j || !ok[j]) continue;
                (uint256 a, uint256 b) = prices[i] < prices[j] ? (prices[i], prices[j]) : (prices[j], prices[i]);
                if ((b - a) * 10_000 <= a * dev) {
                    anyPairAgrees = true;
                    if (firstAgreeing == type(uint256).max) firstAgreeing = i;
                }
            }
        }
        if (corroborated) {
            assertEq(idx, firstAgreeing, "the first source in priority order that another ok source agrees with");
        } else {
            assertFalse(anyPairAgrees, "uncorroborated only when nothing agrees");
            assertEq(idx, firstOk, "uncorroborated candidate is the first ok source");
        }
    }
}
