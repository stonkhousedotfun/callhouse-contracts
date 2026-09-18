// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {SettlementOracleFixture} from "./SettlementOracle.t.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockOraclePriceSource} from "../../../src/v2/mocks/MockOraclePriceSource.sol";

/// @notice SettlementOracle.pin (INTERFACE_VERSION 6, owner decision 2026-09-17: closes C2-16 finding 1): who may pin,
///         what is copied, idempotency and events, the empty-market revert, that any source pin failure (revert,
///         malformed answer, no code, gas starvation) reverts the whole pin, that a pin made by another Clearinghouse
///         (a migration, or the admin's hidden pre-pin) must be confirmed against the current configuration, and that
///         snapshot, finalize, unveto and adminResolve of a pinned expiry ignore every later setMarket while an
///         unpinned expiry follows it. spot stays on the current configuration.
/// @dev The fixture's MockOpenInterestClearinghouse is the configured Clearinghouse, so `vm.prank(address(ch))` is the
///      Clearinghouse calling pin from createSeries. E = THU_2026_09_10, P = 220.00 USDG.
contract SettlementOraclePinTest is SettlementOracleFixture {
    uint40 internal constant FRI = FRI_2026_09_11;

    function _pin(uint40 expiry) internal {
        vm.prank(address(ch));
        oracle.pin(address(nvda), expiry);
    }

    /*//////////////////////////////////////////////////////////////
                           ACCESS, COPY, EVENTS
    //////////////////////////////////////////////////////////////*/

    /// Only the configured Clearinghouse: not the admin, not the guardian, not anyone once the pointer is zero.
    function test_pin_onlyTheClearinghouse() public {
        _useTwo();
        address[3] memory others = [admin, guardian, stranger];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            oracle.pin(address(nvda), E);
        }
        vm.prank(admin);
        oracle.setClearinghouse(address(0));
        vm.prank(address(ch));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        oracle.pin(address(nvda), E);
        (bool pinned,,,,) = oracle.settlementConfig(address(nvda), E);
        assertFalse(pinned, "nothing pinned by a refused call");

        vm.prank(admin);
        oracle.setClearinghouse(address(ch));
        assertEq(oracle.pinnedBy(address(nvda), E), address(0), "pinnedBy is zero while not pinned");
        _pin(E);
        (pinned,,,,) = oracle.settlementConfig(address(nvda), E);
        assertTrue(pinned, "the Clearinghouse pins");
        assertEq(oracle.pinnedBy(address(nvda), E), address(ch), "pinnedBy");
    }

    /// The first pin copies the list and the parameters (defaults filled in), emits SettlementConfigPinned once and
    /// asks every source to pin; the second is a no-op without a log or a source call.
    function test_pin_copiesOnceEmitsOnceAndPinsEverySource() public {
        address[] memory list = _list(address(s0), address(s1), address(s2));
        vm.prank(admin);
        oracle.setMarket(address(nvda), list, 0, 2 hours, 0);

        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementConfigPinned(address(nvda), E, list, 150, 2 hours);
        _pin(E);
        for (uint256 i; i < 3; ++i) {
            MockOraclePriceSource s = i == 0 ? s0 : i == 1 ? s1 : s2;
            assertTrue(s.pinned(address(nvda), E), "source asked to pin the expiry");
            assertEq(s.pinCalls(), 1, "once");
        }
        (bool pinned, address[] memory srcs, uint16 dev, uint32 delay, uint32 age) =
            oracle.settlementConfig(address(nvda), E);
        assertTrue(pinned, "pinned");
        assertEq(keccak256(abi.encode(srcs)), keccak256(abi.encode(list)), "sources in priority order");
        assertEq(dev, 150, "default deviation filled in");
        assertEq(delay, 2 hours, "delay");
        assertEq(age, 1 hours, "default spot age filled in");

        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s1)), 900, 0, 0);
        vm.recordLogs();
        _pin(E);
        assertEq(vm.getRecordedLogs().length, 0, "no second event");
        assertEq(s0.pinCalls() + s1.pinCalls() + s2.pinCalls(), 3, "no source asked again");
        (, srcs, dev, delay,) = oracle.settlementConfig(address(nvda), E);
        assertEq(srcs.length, 3, "the pin did not move");
        assertEq(dev + delay, 150 + 2 hours, "nor its parameters");
    }

    /// A market without sources cannot be pinned, so createSeries fails on it; an expiry already pinned stays pinned
    /// (and re-pinning it is still a no-op) when the list is emptied afterwards.
    function test_pin_emptyMarketReverts_pinnedExpiryUnaffected() public {
        vm.prank(address(ch));
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.pin(address(nvda), E);

        _useTwo();
        _pin(E);
        vm.prank(admin);
        oracle.setMarket(address(nvda), new address[](0), 0, 0, 0);
        _pin(E);
        vm.prank(address(ch));
        vm.expectRevert(V2Errors.NoSource.selector);
        oracle.pin(address(nvda), FRI);
        (bool pinned, address[] memory srcs,,,) = oracle.settlementConfig(address(nvda), E);
        assertTrue(pinned && srcs.length == 2, "E keeps its two sources");
    }

    /*//////////////////////////////////////////////////////////////
                            FAILS CLOSED
    //////////////////////////////////////////////////////////////*/

    /// @dev Asserts the whole pin of E was refused: the oracle holds no pin and no source kept its own.
    function _assertNothingPinned(string memory why) internal view {
        (bool pinned,,,,) = oracle.settlementConfig(address(nvda), E);
        assertFalse(pinned, string.concat(why, ": oracle not pinned"));
        assertEq(oracle.pinnedBy(address(nvda), E), address(0), string.concat(why, ": no pinnedBy"));
        assertFalse(s0.pinned(address(nvda), E), string.concat(why, ": s0 rolled back"));
        assertFalse(s1.pinned(address(nvda), E), string.concat(why, ": s1 rolled back"));
        assertFalse(s2.pinned(address(nvda), E), string.concat(why, ": s2 rolled back"));
    }

    function _expectSourceNotPinned(address source, bytes4 reason) internal {
        vm.prank(address(ch));
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SourceNotPinned.selector, source, reason));
        oracle.pin(address(nvda), E);
    }

    /// Every way a source can fail its pin reverts the whole pin with SourceNotPinned naming it, and nothing stays
    /// pinned, on the oracle or on the sources that pinned before it: a revert (its selector is the reason), a reply
    /// too short or too long, a 32-byte answer that is not the pin selector, and no code at all.
    function test_pin_anySourceFailure_revertsTheWholePin() public {
        _useThree();

        s2.setMode(MockOraclePriceSource.Mode.Reverts);
        _expectSourceNotPinned(address(s2), MockOraclePriceSource.MockSourceReverted.selector);
        _assertNothingPinned("revert");

        s2.setMode(MockOraclePriceSource.Mode.ShortReply);
        _expectSourceNotPinned(address(s2), bytes4(0));
        _assertNothingPinned("31-byte reply");

        s2.setMode(MockOraclePriceSource.Mode.DirtyOk);
        _expectSourceNotPinned(address(s2), bytes4(0));
        _assertNothingPinned("96-byte reply");

        s2.setMode(MockOraclePriceSource.Mode.Normal);
        vm.mockCall(
            address(s1), abi.encodeWithSelector(MockOraclePriceSource.pin.selector), abi.encode(bytes4(0x12345678))
        );
        _expectSourceNotPinned(address(s1), bytes4(0));
        _assertNothingPinned("wrong 32-byte answer");
        // the selector with a dirty low byte is not the ABI encoding of the selector either
        vm.mockCall(
            address(s1),
            abi.encodeWithSelector(MockOraclePriceSource.pin.selector),
            abi.encodePacked(bytes32(MockOraclePriceSource.pin.selector) | bytes32(uint256(1)))
        );
        _expectSourceNotPinned(address(s1), bytes4(0));
        _assertNothingPinned("dirty selector word");
        vm.clearMockedCalls();

        bytes memory code = address(s0).code;
        vm.etch(address(s0), "");
        _expectSourceNotPinned(address(s0), bytes4(0));
        (bool pinned,,,,) = oracle.settlementConfig(address(nvda), E);
        assertFalse(pinned, "no code: not pinned");
        vm.etch(address(s0), code);

        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementConfigPinned(
            address(nvda), E, _list(address(s0), address(s1), address(s2)), 150, 6 hours
        );
        _pin(E);
        assertTrue(s0.pinned(address(nvda), E) && s1.pinned(address(nvda), E) && s2.pinned(address(nvda), E), "all");
        assertEq(oracle.pinnedBy(address(nvda), E), address(ch), "pinned by the Clearinghouse");
    }

    /// A source that runs out of gas fails like any other source: the whole pin reverts with SourceNotPinned (the
    /// 1/64 of the gas EIP-150 leaves the oracle is enough to say so), so no gas limit gets a pin past a source.
    function test_pin_sourceOutOfGas_revertsTheWholePin() public {
        _useTwo();
        s1.setPinBurnsGas(true);
        vm.prank(address(ch));
        vm.expectRevert(abi.encodeWithSelector(V2Errors.SourceNotPinned.selector, address(s1), bytes4(0)));
        oracle.pin(address(nvda), E);
        _assertNothingPinned("out of gas");

        s1.setPinBurnsGas(false);
        _pin(E);
        assertTrue(s0.pinned(address(nvda), E) && s1.pinned(address(nvda), E), "pins with a working source");
    }

    /*//////////////////////////////////////////////////////////////
                  A PIN MADE ELSEWHERE MUST BE CONFIRMED
    //////////////////////////////////////////////////////////////*/

    /// The Clearinghouse pointer moves (a migration): the new Clearinghouse confirms an unchanged pin without a log,
    /// asking every pinned source again, and becomes pinnedBy, after which it takes the cheap path. The old one is
    /// refused (NotAuthorized) even though it pinned the expiry.
    function test_pin_newClearinghouse_confirmsAnUnchangedPin() public {
        _useTwo();
        _pin(E);
        address ch2 = makeAddr("clearinghouse2");
        vm.prank(admin);
        oracle.setClearinghouse(ch2);

        vm.prank(address(ch));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        oracle.pin(address(nvda), E);

        vm.recordLogs();
        vm.prank(ch2);
        oracle.pin(address(nvda), E);
        assertEq(_logsFrom(address(oracle)), 0, "a confirmation logs nothing");
        assertEq(oracle.pinnedBy(address(nvda), E), ch2, "the new Clearinghouse pins from now on");
        assertEq(s0.pinCalls() + s1.pinCalls(), 4, "every pinned source asked to confirm");

        vm.prank(ch2);
        oracle.pin(address(nvda), E);
        assertEq(s0.pinCalls() + s1.pinCalls(), 4, "then the cheap path: no source call");
    }

    /// Any difference between the pinned copy and the market's current configuration refuses the confirmation with
    /// PinMismatch: another list, the same list in another order, a longer list, and each parameter.
    function test_pin_confirmation_refusesEveryDifference() public {
        _useTwo();
        _pin(E);
        address ch2 = makeAddr("clearinghouse2");
        vm.prank(admin);
        oracle.setClearinghouse(ch2);

        address[][4] memory lists = [
            _list(address(s1)),
            _list(address(s1), address(s0)),
            _list(address(s0), address(s1), address(s2)),
            _list(address(s0), address(s1))
        ];
        uint16[4] memory devs = [uint16(0), 0, 0, 151];
        for (uint256 i; i < 4; ++i) {
            vm.prank(admin);
            oracle.setMarket(address(nvda), lists[i], devs[i], 0, 0);
            vm.prank(ch2);
            vm.expectRevert(V2Errors.PinMismatch.selector);
            oracle.pin(address(nvda), E);
        }
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 0, 6 hours + 1, 0);
        vm.prank(ch2);
        vm.expectRevert(V2Errors.PinMismatch.selector);
        oracle.pin(address(nvda), E);
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 0, 0, 1 hours + 1);
        vm.prank(ch2);
        vm.expectRevert(V2Errors.PinMismatch.selector);
        oracle.pin(address(nvda), E);
        assertEq(oracle.pinnedBy(address(nvda), E), address(ch), "unchanged by the refusals");

        // the explicit defaults equal the pinned (filled-in) copy
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 150, 6 hours, 1 hours);
        vm.prank(ch2);
        oracle.pin(address(nvda), E);
        assertEq(oracle.pinnedBy(address(nvda), E), ch2, "confirmed once equal again");
    }

    /// A confirmation also needs every pinned source to pin again: a source that fails reverts it.
    function test_pin_confirmation_needsEverySource() public {
        _useTwo();
        _pin(E);
        address ch2 = makeAddr("clearinghouse2");
        vm.prank(admin);
        oracle.setClearinghouse(ch2);
        s1.setMode(MockOraclePriceSource.Mode.Reverts);
        vm.prank(ch2);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.SourceNotPinned.selector, address(s1), MockOraclePriceSource.MockSourceReverted.selector
            )
        );
        oracle.pin(address(nvda), E);
        assertEq(oracle.pinnedBy(address(nvda), E), address(ch), "not confirmed");
    }

    /// The hidden pre-pin (coordinator finding): the admin points the Clearinghouse pointer at its own account, pins E
    /// with a bad list, and restores the list and the pointer. Every public current-configuration view looks clean,
    /// but the pin is on record (settlementConfig, pinnedBy) and the real Clearinghouse cannot create a series of E on
    /// it: PinMismatch. Only making the bad list the market's CURRENT one, in public, lets a series use it. A pre-pin
    /// with the configuration that is current anyway is harmless and is confirmed.
    function test_pin_hiddenPrePin_blocksTheClearinghouse() public {
        address shadow = makeAddr("adminShadow");
        _useTwo();
        vm.startPrank(admin);
        oracle.setMarket(address(nvda), _list(address(s2)), 1000, 30 minutes, 0);
        oracle.setClearinghouse(shadow);
        vm.stopPrank();
        vm.prank(shadow);
        oracle.pin(address(nvda), E);
        vm.startPrank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 0, 0, 0);
        oracle.setClearinghouse(address(ch));
        vm.stopPrank();

        (address[] memory current,,,) = oracle.marketConfig(address(nvda));
        assertEq(current.length, 2, "the current configuration looks clean");
        (bool pinned, address[] memory srcs,,,) = oracle.settlementConfig(address(nvda), E);
        assertTrue(pinned && srcs.length == 1 && srcs[0] == address(s2), "but E is pinned to [s2], publicly");
        assertEq(oracle.pinnedBy(address(nvda), E), shadow, "by the admin's account");

        vm.prank(address(ch));
        vm.expectRevert(V2Errors.PinMismatch.selector);
        oracle.pin(address(nvda), E);

        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s2)), 1000, 30 minutes, 0);
        _pin(E);
        assertEq(oracle.pinnedBy(address(nvda), E), address(ch), "confirmed only with [s2] current, in public");

        // a pre-pin of FRI with the current configuration: confirmed by the first series
        vm.prank(admin);
        oracle.setClearinghouse(shadow);
        vm.prank(shadow);
        oracle.pin(address(nvda), FRI);
        vm.prank(admin);
        oracle.setClearinghouse(address(ch));
        vm.prank(address(ch));
        oracle.pin(address(nvda), FRI);
        assertEq(oracle.pinnedBy(address(nvda), FRI), address(ch), "an honest pre-pin is confirmed");
    }

    /*//////////////////////////////////////////////////////////////
                    A PINNED EXPIRY IGNORES setMarket
    //////////////////////////////////////////////////////////////*/

    /// After the pin the admin adds an agreeing source ahead of the list and widens the deviation: the pinned expiry
    /// still captures only its own sources and waits as a single-source candidate; the same change applied to an
    /// unpinned expiry corroborates at once.
    function test_pinned_adminAddedAgreeingSource_cannotFinalize() public {
        _useTwo();
        _pin(E);
        s0.setWindow(true, P);
        s2.setWindow(true, P);
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s2), address(s0)), 1000, 30 minutes, 0);

        vm.warp(FINALIZABLE);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "s2 does not vote on the pinned expiry");
        (address[] memory srcs,,, uint16 dev) = oracle.recordedSources(address(nvda), E);
        assertEq(srcs.length, 2, "captured the pinned list");
        assertEq(srcs[0], address(s0), "s0 first");
        assertEq(srcs[1], address(s1), "then s1");
        assertEq(dev, 150, "the pinned deviation");
        (uint256 price, uint8 idx, bool disagreed, uint40 at) = oracle.candidate(address(nvda), E);
        assertEq(price, P, "candidate s0");
        assertEq(idx, 0, "index 0 is s0");
        assertFalse(disagreed, "single source");
        assertEq(at, FINALIZABLE + 6 hours, "the pinned 6 h delay, not the new 30 min");

        // snapshot too asks only the pinned sources
        s2.setRecordable(true);
        s1.setRecordable(true);
        _snapshot();
        assertEq(s2.recordCalls(), 0, "not the added source");
        assertEq(s1.recordCalls(), 1, "the pinned one");

        // an expiry nobody pinned follows the new configuration
        ch.setOpenInterest(address(nvda), FRI, 1);
        vm.warp(FRI + V2Constants.FINALIZE_DELAY);
        uint256 friPrice;
        (finalized, friPrice) = oracle.finalize(address(nvda), FRI);
        assertTrue(finalized, "unpinned: s2 and s0 corroborate");
        assertEq(friPrice, P, "at s2's price");
        (,,, dev) = oracle.recordedSources(address(nvda), FRI);
        assertEq(dev, 1000, "the new deviation");
    }

    /// Widening the deviation after the pin cannot turn a disagreement into corroboration, and unveto restarts the
    /// pinned delay.
    function test_pinned_widerDeviationAndShorterDelay_doNotApply() public {
        _useTwo();
        _pin(E);
        s0.setWindow(true, P);
        s1.setWindow(true, 229_900_000); // 450 bps apart
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s0), address(s1)), 1000, 30 minutes, 0);
        vm.warp(FINALIZABLE);
        (bool finalized,) = _finalize();
        assertFalse(finalized, "150 bps pinned: still a disagreement");
        (,, bool disagreed, uint40 at) = oracle.candidate(address(nvda), E);
        assertTrue(disagreed, "disagreed");
        assertEq(at, FINALIZABLE + 6 hours, "pinned delay");

        vm.prank(guardian);
        oracle.veto(address(nvda), E);
        vm.warp(FINALIZABLE + 1 hours);
        vm.expectEmit(address(oracle));
        emit ISettlementOracle.SettlementUnvetoed(address(nvda), E, FINALIZABLE + 1 hours + 6 hours);
        vm.prank(guardian);
        oracle.unveto(address(nvda), E);
    }

    /// Emptying the market after the pin does not make the pinned expiry unbounded for adminResolve: it still captures
    /// its pinned sources first. An unpinned expiry with the emptied market accepts any price.
    function test_pinned_emptiedMarket_adminResolveStaysBanded() public {
        _useTwo();
        _pin(E);
        s0.setWindow(true, P);
        vm.prank(admin);
        oracle.setMarket(address(nvda), new address[](0), 0, 0, 0);

        vm.warp(E + V2Constants.RESOLVE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.ResolveOutOfBand.selector, 216_700_000, 223_300_000));
        oracle.adminResolve(address(nvda), E, 1);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), E, 223_300_000);
        (, uint256 price) = oracle.settlementPrice(address(nvda), E);
        assertEq(price, 223_300_000, "resolved inside the band of the pinned source");

        vm.warp(FRI + V2Constants.RESOLVE_DELAY);
        vm.prank(admin);
        oracle.adminResolve(address(nvda), FRI, 1);
        (, price) = oracle.settlementPrice(address(nvda), FRI);
        assertEq(price, 1, "unpinned and source-less: any price (the case pinning removes for live series)");
    }

    /// spot is market-level: it reads the CURRENT source 0 and spotMaxAge, not a pinned copy.
    function test_spot_readsTheCurrentConfigurationNotThePin() public {
        _useTwo();
        s0.setLatest(true, P, block.timestamp);
        s1.setLatest(true, 250_000_000, block.timestamp);
        _pin(E);
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s1), address(s0)), 0, 0, 0);
        (uint256 spot,) = oracle.spot(address(nvda));
        assertEq(spot, 250_000_000, "the new source 0");
        (, address[] memory srcs,,,) = oracle.settlementConfig(address(nvda), E);
        assertEq(srcs[0], address(s0), "while E keeps its pinned order");
    }

    /// settlementConfig of an unpinned expiry is the market's current configuration, which may still change.
    function test_settlementConfig_unpinnedFollowsTheMarket() public {
        _useTwo();
        (bool pinned, address[] memory srcs, uint16 dev,,) = oracle.settlementConfig(address(nvda), FRI);
        assertFalse(pinned, "not pinned");
        assertEq(srcs.length, 2, "market list");
        assertEq(dev, 150, "defaults");
        vm.prank(admin);
        oracle.setMarket(address(nvda), _list(address(s2)), 500, 0, 0);
        (pinned, srcs, dev,,) = oracle.settlementConfig(address(nvda), FRI);
        assertFalse(pinned, "still not pinned");
        assertEq(srcs[0], address(s2), "follows");
        assertEq(dev, 500, "follows");
    }

    /// Pins are per (underlying, expiry): pinning NVDA's E pins neither TSLA's E nor NVDA's Friday.
    function test_pin_isPerUnderlyingAndExpiry() public {
        _useTwo();
        vm.prank(admin);
        oracle.setMarket(address(tsla), _list(address(s2)), 0, 0, 0);
        _pin(E);
        vm.recordLogs();
        vm.prank(address(ch));
        oracle.pin(address(tsla), E);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], ISettlementOracle.SettlementConfigPinned.selector, "TSLA's E pins on its own");
        (bool pinned,,,,) = oracle.settlementConfig(address(nvda), FRI);
        assertFalse(pinned, "NVDA's Friday untouched");
        (, address[] memory srcs,,,) = oracle.settlementConfig(address(tsla), E);
        assertEq(srcs[0], address(s2), "TSLA's own list");
        (V2Types.SettlementStatus st,) = oracle.settlementPrice(address(nvda), E);
        assertEq(uint8(st), uint8(V2Types.SettlementStatus.None), "a pin changes no settlement state");
    }
}
