// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseV2Test} from "../BaseV2.t.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";

/// @notice Pins what test/v2/BaseV2.t.sol promises every v2 suite: the clock and its expiry constants, the actors,
///         token decimals, the issuer switches the payout tests rely on, and the order the setUp hooks run in.
/// @dev The hooks are overridden here only to record when they run, which is exactly what a later suite's override
///      depends on (feeds before core, core after funding).
contract BaseV2FixtureTest is BaseV2Test {
    /// @dev New York is UTC-4 (EDT) from the second Sunday of March to the first Sunday of November; every fixture
    ///      instant is in September.
    uint256 internal constant EDT_OFFSET = 4 hours;

    uint256 internal hookCalls;
    uint256 internal feedsRanAt;
    uint256 internal coreRanAt;
    uint256 internal usdgSeenByCore;

    function _deployFeeds() internal override {
        feedsRanAt = ++hookCalls;
    }

    function _deployCore() internal override {
        coreRanAt = ++hookCalls;
        usdgSeenByCore = usdg.balanceOf(alice);
    }

    /// @dev Local New York seconds-of-day and weekday (0 = Monday) of a unix time. 1970-01-01 was a Thursday.
    function _nyClock(uint256 ts) internal pure returns (uint256 secondsOfDay, uint256 weekday) {
        uint256 local = ts - EDT_OFFSET;
        secondsOfDay = local % 1 days;
        weekday = (local / 1 days + 3) % 7;
    }

    /*//////////////////////////////////////////////////////////////
                                  CLOCK
    //////////////////////////////////////////////////////////////*/

    function test_clock_startsWednesdayEveningAfterTheClose() public view {
        assertEq(block.timestamp, START, "setUp warps to START");
        (uint256 sod, uint256 weekday) = _nyClock(START);
        assertEq(weekday, 2, "Wednesday");
        assertEq(sod, 20 hours + 26 minutes + 40, "20:26:40 New York");
    }

    function test_clock_expiriesAre1600NewYork() public pure {
        uint40[3] memory expiries = [THU_2026_09_10, FRI_2026_09_11, FRI_2026_09_18];
        uint256[3] memory weekdays = [uint256(3), 4, 4];
        for (uint256 i; i < expiries.length; ++i) {
            (uint256 sod, uint256 weekday) = _nyClock(expiries[i]);
            assertEq(sod, 16 hours, "16:00 New York");
            assertEq(weekday, weekdays[i], "Thursday / Friday");
        }
        assertEq(FRI_2026_09_11 - THU_2026_09_10, 1 days, "Friday follows Thursday");
        assertEq(FRI_2026_09_18 - FRI_2026_09_11, 7 days, "next week's weekly");
    }

    /// @dev A suite can create series on all three straight after setUp: each is at least MIN_SERIES_LEAD away, none
    ///      beyond MAX_TENOR, and none has reached its mint cutoff.
    function test_clock_expiriesAreCreatableFromStart() public pure {
        assertGe(THU_2026_09_10, START + V2Constants.MIN_SERIES_LEAD, "daily far enough ahead");
        assertLe(FRI_2026_09_18, START + V2Constants.MAX_TENOR, "weekly within tenor");
        assertLt(START, THU_2026_09_10 - V2Constants.SETTLEMENT_WINDOW, "before the daily's mint cutoff");
    }

    /*//////////////////////////////////////////////////////////////
                             ACTORS AND HOOKS
    //////////////////////////////////////////////////////////////*/

    function test_actors_distinctAndNonZero() public view {
        address[8] memory a = [admin, guardian, keeper, alice, bob, carol, mm, treasury];
        for (uint256 i; i < a.length; ++i) {
            assertTrue(a[i] != address(0), "non-zero actor");
            assertEq(a[i].code.length, 0, "actors are EOAs");
            for (uint256 j = i + 1; j < a.length; ++j) {
                assertTrue(a[i] != a[j], "distinct actors");
            }
        }
    }

    function test_actors_funding() public view {
        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            assertEq(usdg.balanceOf(traders[i]), ACTOR_USDG, "trader USDG");
            assertEq(nvda.balanceOf(traders[i]), ACTOR_SHARES, "trader NVDA");
            assertEq(tsla.balanceOf(traders[i]), ACTOR_SHARES, "trader TSLA");
        }
        address[4] memory roles = [admin, guardian, keeper, treasury];
        for (uint256 i; i < roles.length; ++i) {
            assertEq(usdg.balanceOf(roles[i]), 0, "role accounts start without USDG");
            assertEq(nvda.balanceOf(roles[i]) + tsla.balanceOf(roles[i]), 0, "role accounts start without shares");
        }
    }

    function test_hooks_runFeedsThenCoreAfterFunding() public view {
        assertEq(feedsRanAt, 1, "feeds first");
        assertEq(coreRanAt, 2, "core second");
        assertEq(usdgSeenByCore, ACTOR_USDG, "actors are funded before the core deploys");
    }

    /*//////////////////////////////////////////////////////////////
                                  TOKENS
    //////////////////////////////////////////////////////////////*/

    /// @dev ADR-04: a unit is 0.01 of an 18-dp share and USDG has 6 dp.
    function test_tokens_decimalsMatchUnits() public view {
        assertEq(usdg.decimals(), 6, "USDG 6 dp");
        assertEq(nvda.decimals(), 18, "NVDA 18 dp");
        assertEq(tsla.decimals(), 18, "TSLA 18 dp");
        assertEq(V2Constants.UNIT * V2Constants.UNITS_PER_SHARE, 10 ** nvda.decimals(), "100 units per share");
        assertTrue(address(nvda) != address(tsla), "two markets");
        assertEq(STRIKE_TICK % V2Constants.PRICE_TICK, 0, "strike grid is on the price grid");
    }

    /// @dev The blocklist switch: a blocked address can neither receive nor send, directly or via transferFrom. The lint
    ///      is disabled on calls expected to revert: there is no return value to check.
    function test_stockToken_blocklistRevertsTransfers() public {
        nvda.blockAccount(bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, bob));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        nvda.transfer(bob, 1e16);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, bob));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        nvda.transfer(alice, 1e16);

        vm.prank(alice);
        nvda.approve(carol, 1e16);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, bob));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        nvda.transferFrom(alice, bob, 1e16);

        nvda.unblockAccount(bob);
        vm.prank(alice);
        assertTrue(nvda.transfer(bob, 1e16), "transfer returns true");
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + 1e16, "unblocked: transfers work again");
    }

    function test_stockToken_oraclePausedAndUiMultiplier() public {
        assertFalse(nvda.oraclePaused(), "oracle live by default");
        assertEq(nvda.uiMultiplier(), 1e18, "multiplier 1.0 by default");
        nvda.setOraclePaused(true);
        nvda.setUiMultiplier(2e18);
        assertTrue(nvda.oraclePaused(), "oracle paused");
        assertEq(nvda.uiMultiplier(), 2e18, "multiplier moved");
        assertFalse(tsla.oraclePaused(), "the other market is independent");
        assertEq(tsla.uiMultiplier(), 1e18, "the other market is independent");
    }

    /// @dev Frozen recipient, then a paused token. Lint disabled on the expected reverts as above.
    function test_usdg_freezeAndPauseRevertTransfers() public {
        usdg.freeze(bob);
        vm.prank(alice);
        vm.expectRevert(MockERC20.AddressFrozen.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdg.transfer(bob, 1);
        usdg.unfreeze(bob);

        usdg.pause();
        vm.prank(alice);
        vm.expectRevert(MockERC20.ContractPaused.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdg.transfer(bob, 1);
        usdg.unpause();

        vm.prank(alice);
        assertTrue(usdg.transfer(bob, 1), "transfer returns true");
        assertEq(usdg.balanceOf(bob), ACTOR_USDG + 1, "live again");
    }
}
