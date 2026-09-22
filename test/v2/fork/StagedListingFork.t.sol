// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";

import {ForkFloor} from "./ForkFloor.sol";

/// @notice C3-102 on a 4663 fork: a planned (disabled) registration of real NVDA cannot createSeries;
///         enabling via setMarketListing unblocks it. Skips cleanly when not forked.
/// @dev FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --fork-block-number <recorded> -j 1 --match-path test/v2/fork/StagedListingFork.t.sol
///      Without `--fork-url` this suite is GREEN HAVING RUN NOTHING (`06-QUIRKS.md` §A.1). Record the block; do not
///      report a skip as a pass. This suite already deploys through V8AccessTest (AccessManager, not AccessControl).
contract StagedListingForkTest is V8AccessTest {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_plannedNvdaCannotCreateSeriesUntilEnabled() public onlyFork {
        address admin = makeAddr("admin");
        address guardian = makeAddr("guardian");
        address fees = makeAddr("fees");
        ExpiryCalendar calendar = _newCalendar(new uint32[](0), admin);
        _deployManager();
        ChainlinkFeedSource cl = new ChainlinkFeedSource(address(manager));
        _wire(address(cl), "ChainlinkFeedSource", admin, 0);
        SettlementOracle oracle = new SettlementOracle(address(manager));
        _wire(address(oracle), "SettlementOracle", admin, 0);
        _grant(V8Roles.GUARDIAN, guardian, 0);
        Clearinghouse ch =
            new Clearinghouse(address(manager), USDG, address(calendar), fees, "https://app.stonkhouse.fun/api/token/");
        _wire(address(ch), "Clearinghouse", admin, 0);

        vm.startPrank(admin);
        cl.setFeed(NVDA, NVDA_FEED, cl.DEFAULT_MAX_STALE(), cl.DEFAULT_MAX_ROUND_JUMP_BPS());
        cl.setOracle(address(oracle), true);
        address[] memory sources = new address[](1);
        sources[0] = address(cl);
        oracle.setMarket(NVDA, sources, 150, 21600, 90000);
        oracle.setClearinghouse(address(ch));
        ch.setDefaultOracle(address(oracle));
        ch.setDefaultMarketFees(25, 80);
        ch.registerMarket(NVDA, 2_500_000, false);
        ch.setMarketFees(NVDA, 25, 80);
        ch.setMarketOracle(NVDA, address(oracle));
        vm.stopPrank();

        uint40 expiry = calendar.nextExpiry(uint40(block.timestamp + 2 days), true);
        vm.expectRevert(V2Errors.MarketDisabled.selector);
        ch.createSeries(NVDA, false, 220_000_000, expiry);

        vm.prank(admin);
        ch.setMarketListing(NVDA, true, 2_500_000);
        uint256 id = ch.createSeries(NVDA, false, 220_000_000, expiry);
        assertGt(id, 0, "createSeries after enable");
    }

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `USDG`, an address this suite's own tests read.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_stagedListingForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(USDG, "StagedListingFork");
    }
}
