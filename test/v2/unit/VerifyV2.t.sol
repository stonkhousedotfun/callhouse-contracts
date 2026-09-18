// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployV2Fixture} from "./DeployV2Fixture.t.sol";
import {VerifyV2} from "../../../script/v2/VerifyV2.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";

/// @notice `script/v2/VerifyV2.s.sol` has teeth: clean on a set DeployV2 deployed and RegisterMarkets configured, and
///         exactly the expected failures for each kind of drift (bytecode, pointer, role, route, source list, tuned
///         parameter fresh vs live, a registered market the registry does not list, a paused market).
contract VerifyV2Test is DeployV2Fixture {
    V2DeployBase.Contracts internal d;

    function setUp() public override {
        super.setUp();
        d = _deploy();
        registerScript.runWith(_registerInputs(d), _signer(admin));
    }

    function test_verify_cleanOnTheDeployedSet() public {
        (uint256 passed, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 0, "no failure");
        assertGt(passed, 100, "more than a hundred checks");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 0, "no failure as a live set either");
    }

    function test_verify_bytecodeTamper() public {
        // one byte of the Clearinghouse's trailing CBOR (never executed) flipped: only the runtime comparison can see it
        bytes memory code = d.clearinghouse.code;
        code[code.length - 2] = code[code.length - 2] ^ 0x01;
        vm.etch(d.clearinghouse, code);
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "the clearinghouse runtime check");
    }

    function test_verify_pointerRoleAndRouteDrift() public {
        vm.startPrank(admin);
        SettlementOracle(d.settlementOracle).setKeeperRewards(address(0)); // pointers
        Clearinghouse(d.clearinghouse).revokeRole(V2Constants.GUARDIAN_ROLE, guardian); // guardian holders
        OrderBook(d.orderBook).grantRole(V2Constants.DEFAULT_ADMIN_ROLE, cranker); // stray admin
        UniV3PayoutAdapter(d.payoutAdapter).setRoute(address(nvda), 0); // NVDA route
        vm.stopPrank();
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 4, "oracle rewards pointer, guardian holders, stray admin, NVDA route");
    }

    /// The pin wiring (INTERFACE_VERSION 6): a source that no longer lists the oracle, and one that lets the admin pin.
    function test_verify_pinWiringDrift() public {
        vm.prank(admin);
        DataStreamsSource(d.dataStreamsSource).setOracle(d.settlementOracle, false);
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "a source does not accept the oracle's pins");

        vm.startPrank(admin);
        DataStreamsSource(d.dataStreamsSource).setOracle(d.settlementOracle, true);
        ChainlinkFeedSource(d.chainlinkSource).setOracle(admin, true);
        vm.stopPrank();
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 1, "the admin may pin: a failure on a live set too");
    }

    /// The pin dry run (INTERFACE_VERSION 6) catches what would refuse the next series: the hidden pre-pin (the admin
    /// points the oracle at its own account, pins NVDA's next expiry with Chainlink alone, and restores the list and the
    /// pointer, so every other check passes), and the Clearinghouse pointer lost.
    function test_verify_pinDryRun() public {
        address shadow = makeAddr("adminShadow");
        // casting to 'uint40' is safe because the test clock is a 2026 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 next = ExpiryCalendar(d.expiryCalendar).nextExpiry(uint40(block.timestamp + 1 hours - 1), false);
        address[] memory one = new address[](1);
        one[0] = d.chainlinkSource;
        address[] memory both = new address[](2);
        (both[0], both[1]) = (d.chainlinkSource, d.univ3Source);
        SettlementOracle oracle = SettlementOracle(d.settlementOracle);
        vm.startPrank(admin);
        oracle.setMarket(address(nvda), one, 150, 21_600, 3600);
        oracle.setClearinghouse(shadow);
        vm.stopPrank();
        vm.prank(shadow);
        oracle.pin(address(nvda), next);
        vm.startPrank(admin);
        oracle.setMarket(address(nvda), both, 150, 21_600, 3600);
        oracle.setClearinghouse(d.clearinghouse);
        vm.stopPrank();
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "NVDA's next expiry is pinned to something else: its series would revert PinMismatch");

        vm.prank(admin);
        oracle.setClearinghouse(address(0));
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 3, "the pointer, and both markets' dry runs");
    }

    /// A registry pool above the 1 % fee tier: the Clearinghouse counts at most MAX_ROUTE_FEE_BPS of a route's fee, so
    /// VerifyV2 names the tier on its own line (the route cannot match either: setRoute refuses such a tier).
    function test_verify_poolFeeTierAboveOnePercent() public {
        VerifyV2.Inputs memory in_ = _verifyInputs(d, true);
        in_.markets[0].poolFee = 20_000;
        (, uint256 failed) = verifyScript.check(in_);
        assertEq(failed, 2, "NVDA pool fee tier above 10000, and its payout route is not (pool, 20000)");
        in_.markets[0].poolFee = V2Constants.MAX_ROUTE_FEE_TIER;
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 1, "exactly 1 % passes the tier check; only the route (still 500 on chain) fails");
    }

    function test_verify_marketDrift() public {
        address[] memory both = new address[](2);
        both[0] = d.chainlinkSource;
        both[1] = d.univ3Source;
        vm.prank(admin);
        SettlementOracle(d.settlementOracle).setMarket(address(tsla), both, 150, 21_600, 3600);
        vm.prank(guardian);
        Clearinghouse(d.clearinghouse).setMintPaused(address(nvda), true);

        VerifyV2.Inputs memory in_ = _verifyInputs(d, true);
        (, uint256 failed) = verifyScript.check(in_);
        // TSLA now lists the pool source, which has no TSLA pool: pinning fails closed, so the dry run fails too
        assertEq(failed, 3, "TSLA source list, TSLA pin dry run, NVDA mint paused (fresh)");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 2, "a live set may be paused; the source list and the dry run still fail");

        // a registered market the registry has no registeredAt for
        in_ = _verifyInputs(d, false);
        in_.markets = new V2DeployBase.MarketIn[](1);
        in_.markets[0] = _nvdaMarket();
        in_.unregistered = new address[](1);
        in_.unregistered[0] = address(tsla);
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 1, "TSLA is registered but listed as unregistered");
    }

    function test_verify_tunedParameters() public {
        vm.startPrank(admin);
        KeeperRewards(d.keeperRewards).setBounty(V2Constants.ACTION_ROLL, 30_000);
        AutoRoller(d.autoRoller).setMinRollUnits(500);
        MakerVault(d.makerVault)
            .setLimits(
                MakerVault.Limits({
                maxSeriesUnits: 1,
                maxTotalNotional: 1,
                askToleranceBps: 0,
                maxBidBpsOfSpot: 0,
                maxOrderLifetime: 0,
                maxDailyOutflow: 0
            })
            );
        vm.stopPrank();
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 3, "fresh: the three launch values");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 0, "live: tuned values are info lines");
    }

    /// @dev Fee changes wait FEE_CHANGE_DELAY, so VerifyV2 compares the registry with the scheduled change while one is
    ///      pending and with the fees in effect otherwise.
    function test_verify_scheduledFeeChange() public {
        OrderBook book = OrderBook(d.orderBook);
        V2Types.FeeParams memory launch = book.feeParams();
        V2Types.FeeParams memory tuned = book.feeParams(); // a copy, not an alias of `launch`
        // Both move together: from INTERFACE_VERSION 7 `premiumFeeBps <= resaleFeeBps` is its own check, in effect
        // and scheduled, so a premium-only rise would fail on that as well and hide what this test is about.
        tuned.premiumFeeBps = launch.premiumFeeBps + 100;
        tuned.resaleFeeBps = launch.resaleFeeBps + 100;

        vm.prank(admin);
        book.setFeeParams(tuned); // in effect 24 h from now; the launch fees still apply
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 2, "fresh: the scheduled premium and resale fees are not the registry's");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 0, "live: info lines");

        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY); // now in effect, nothing pending
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 2, "fresh: the fees in effect are not the registry's");

        vm.prank(admin);
        book.setFeeParams(launch); // back to the registry, in effect 24 h from now
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 0, "a scheduled change back to the registry's fees passes, with its effectiveAt printed");
        assertEq(book.feeParams().premiumFeeBps, tuned.premiumFeeBps, "while the tuned fee is still in effect");
    }

    /*//////////////////////////////////////////////////////////////
                          INTERFACE_VERSION 7
    //////////////////////////////////////////////////////////////*/

    /// @dev c05: a premium fee above the resale fee is the dodge the collateral rent replaces -- write into a one-tick
    ///      bid of a second address of your own, resell the long, pay the smaller of the two. It is a ceiling-style
    ///      `_check`, not a `_param`, so it FAILs on a live set as well as a fresh one, both in effect and scheduled.
    function test_verify_premiumFeeAboveResaleFee() public {
        OrderBook book = OrderBook(d.orderBook);
        V2Types.FeeParams memory tuned = book.feeParams();
        tuned.premiumFeeBps = 500; // resale stays 0
        vm.prank(admin);
        book.setFeeParams(tuned);
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 1, "live: the scheduled premium fee is above the resale fee");

        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY);
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 1, "live: it is in effect now and still refused");
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 2, "fresh: and the premium fee is not the registry's 0 either");
    }

    /// @dev c05: the rent rate the registry asks of each market, pinned into every series created after registration.
    ///      Admin-tunable for new series, so a live set that differs is an info line and a fresh one FAILs.
    function test_verify_mintFeePpmDrift() public {
        VerifyV2.Inputs memory in_ = _verifyInputs(d, true);
        in_.mintFeePpm[0] = 125; // the chain holds NVDA's 80
        (, uint256 failed) = verifyScript.check(in_);
        assertEq(failed, 1, "fresh: NVDA's rent rate is not the registry's");
        in_.expectFresh = false;
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 0, "live: an admin may raise it for new series");

        // above the compiled ceiling it FAILs either way -- but the Clearinghouse itself refuses such a config, so
        // the only way to see it is to write the slot.
        V2Types.MarketConfig memory cfg = Clearinghouse(d.clearinghouse).market(address(nvda));
        assertLe(cfg.mintFeePpm, V2Constants.MINT_FEE_CEIL_PPM, "the deploy could not have exceeded the ceiling");
    }

    /// @dev The release blocker of DECISIONS-2026-09-17 §11: a LIVE market whose rent rate is 0 charges its writers
    ///      nothing at all, because `premiumFeeBps` is 0 at launch. That is a FAIL on a fresh and on a live set, and
    ///      it does not become an info line just because the registry asks for 0 too -- only an explicit
    ///      `allowZeroRent` (`--allow-zero-rent`, refused with `--broadcast`) clears it.
    function test_verify_zeroMintFeePpmIsAFailureNotADrift() public {
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        V2Types.MarketConfig memory cfg = ch.market(address(tsla));
        cfg.mintFeePpm = 0;
        vm.prank(admin);
        ch.setMarketConfig(address(tsla), cfg);

        VerifyV2.Inputs memory in_ = _verifyInputs(d, false);
        (, uint256 failed) = verifyScript.check(in_);
        assertEq(failed, 1, "live: TSLA charges its writers nothing");
        in_.mintFeePpm[1] = 0;
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 1, "still a FAIL when the registry asks for 0: this is a floor, not a tuned parameter");
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 2, "fresh: the rent is 0 and it is not the registry's 300 either");

        in_.allowZeroRent = true;
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 0, "unless the run opted in, which a broadcast never can");
    }

    /// @dev c21: the vault's outflow cap is the sixth field of `Limits`, so it rides the one limits comparison; 0 is a
    ///      spend freeze and gets its own info line.
    function test_verify_vaultOutflowCapDrift() public {
        MakerVault vault = MakerVault(d.makerVault);
        MakerVault.Limits memory l = vault.limits();
        assertEq(l.maxDailyOutflow, 2_500e6, "the launch cap was deployed");
        (uint256 used, uint256 available) = vault.outflow();
        assertEq(used, 0, "a fresh vault has spent nothing");
        assertEq(available, 2_500e6, "the whole cap is available");

        l.maxDailyOutflow = 5_000e6;
        vm.prank(admin);
        vault.setLimits(l);
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "fresh: the vault limits are not the launch tuple");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 0, "live: an admin-tuned cap is an info line");
    }

    /// @dev c16: CANCEL_STALE is the sixth bounty and is compared like the other five.
    function test_verify_cancelStaleBounty() public {
        KeeperRewards kr = KeeperRewards(d.keeperRewards);
        assertEq(kr.bounty(V2Constants.ACTION_CANCEL_STALE), 20_000, "the deploy set it");
        vm.prank(admin);
        kr.setBounty(V2Constants.ACTION_CANCEL_STALE, 35_000);
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "fresh: the CANCEL_STALE bounty is not the launch value");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 0, "live: an info line");

        // The ceiling half of the check cannot be reached through the contract: KeeperRewards.setBounty refuses
        // anything above MAX_BOUNTY itself, which is why the verifier's `underMax` line can only ever fail on a set
        // deployed from other bytecode.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("CeilingExceeded()"));
        kr.setBounty(V2Constants.ACTION_CANCEL_STALE, V2Constants.MAX_BOUNTY + 1);
    }

    /// @dev Owner sign-off c10 (DECISIONS-2026-09-17 §7): a market may only carry a Uniswap v3 source when the pool's
    ///      observation ring outlasts a flood through the snapshot grace. Every launch pool but NVDA's and SPCX's is
    ///      below it and must be registered Chainlink-only, so this refusal is what stops the other 11 shipping with a
    ///      TWAP source. `UniV3TwapSource.setPool` and `RegisterMarkets`' preflight refuse it before the deploy; this
    ///      is the same refusal after the fact, for a ring that was raised for the deploy and let shrink.
    function test_verify_poolObservationRingBelowTheMinimum() public {
        assertEq(V2Constants.MIN_POOL_OBSERVATION_CARDINALITY, 2401, "SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1");
        pool.setObservationCardinality(uint16(V2Constants.MIN_POOL_OBSERVATION_CARDINALITY));
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 0, "exactly the minimum passes");

        pool.setObservationCardinality(uint16(V2Constants.MIN_POOL_OBSERVATION_CARDINALITY - 1));
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "fresh: one below the minimum FAILs");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 1, "a live set fails too: this is a safety floor, not a tuned parameter");

        pool.setObservationCardinality(1801); // the ring every launch pool but NVDA's and SPCX's actually has
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "the real shallow-pool reading");

        // TSLA is Chainlink-only (no pool on either side), so nothing is checked for it and nothing fails.
        VerifyV2.Inputs memory in_ = _verifyInputs(d, true);
        in_.markets = new V2DeployBase.MarketIn[](1);
        in_.markets[0] = _tslaMarket();
        in_.mintFeePpm = new uint32[](1);
        in_.mintFeePpm[0] = 300;
        in_.unregistered = new address[](0);
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 0, "a Chainlink-only market has no ring to check");
    }
}
