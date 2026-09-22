// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DeployV2Fixture} from "./DeployV2Fixture.t.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";

/// @notice A Stock-Token-shaped ERC-20 (18 dp, `uiMultiplier()`, `oraclePaused()`, the symbol the test names) whose
///         transfers between two non-zero addresses burn `feeBps` of the amount: from the SENDER on top of the amount
///         when `senderPays`, out of what the RECIPIENT receives otherwise.
/// @dev SEC-12. Every preflight check before the transfer probe passes on it, so only the probe can refuse it.
contract FeeChargingStockToken is ERC20 {
    uint256 public immutable feeBps;
    bool public immutable senderPays;

    constructor(string memory symbol_, uint256 feeBps_, bool senderPays_) ERC20("Fee Charging Stock Token", symbol_) {
        feeBps = feeBps_;
        senderPays = senderPays_;
    }

    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, address(0), fee);
            if (!senderPays) value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice A Stock-Token-shaped ERC-20 whose `balanceOf` is computed from two slots (a share count times an index),
///         the way a rebasing token's is. SEC-12: no single slot seeds it, so the probe refuses it before any leg.
contract ScaledBalanceStockToken is ERC20 {
    uint256 public index = 2e18;

    constructor(string memory symbol_) ERC20("Scaled Balance Stock Token", symbol_) {}

    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) * index / 1e18;
    }
}

/// @notice RegisterMarkets pinned to the SCHEDULE phase of the two-run delayed flow.
/// @dev SEC-12. Under v8 the fixture's admin Safe holds LISTING and CONFIG_ADMIN with execution delays, so a single
///      `runWith` refuses it in {RegisterMarkets._signerCanList} before it reaches any market; that is why the rest of
///      this suite is red at base (DEFERRED-VERIFICATION, T-248: 0/13). The schedule phase is the first half of the
///      real flow an operator runs: it preflights and probes every market, then only schedules, so it reaches
///      {RegisterMarkets.probeTransfers} through `runWith` exactly as a deployment does. Nothing else is overridden.
contract ProbeSchedulePhaseHarness is RegisterMarkets {
    function _scheduleEnabled() internal pure override returns (bool) {
        return true;
    }

    function _schedulePhase() internal pure override returns (uint8) {
        return PHASE_SCHEDULE;
    }
}

/// @notice `script/v2/RegisterMarkets.s.sol` over the mocks on a set deployed by DeployV2: NVDA with its pool (two
///         sources, payout route) and TSLA Chainlink-only are configured and registered, a re-run sends nothing, a
///         config drift is repaired, and each preflight refusal reverts with its message before any call is sent.
/// @dev The refusals run in ONE function, in order, as test/unit/DeploySoloPreflight.t.sol does.
contract RegisterMarketsPreflightTest is DeployV2Fixture {
    V2DeployBase.Contracts internal d;

    function setUp() public override {
        super.setUp();
        d = _deploy();
    }

    function test_register_nvdaWithPoolAndTslaChainlinkOnly() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        (uint256 registered, uint256 sent) = _launchRun(_registerInputs(d));
        assertEq(registered, 2, "two registerMarket calls");
        // NVDA: setFeed, setPool, setMarket, registerMarket (no payout route in this fixture: venue none); TSLA:
        // setFeed, setMarket, registerMarket. Measured from the run's own `call` lines (T-OP-205; was 8 with a route).
        assertEq(sent, 7, "7 direct calls by the in-window deployer");

        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        V2Types.MarketConfig memory n = ch.market(address(nvda));
        assertTrue(n.enabled && !n.mintPaused, "NVDA enabled");
        assertEq(n.strikeTick, TICK_2_50);
        assertEq(n.exerciseFeeBps, 25);
        assertEq(n.oracle, d.settlementOracle);
        assertEq(ch.market(address(tsla)).strikeTick, TICK_2_50, "TSLA registered");

        (address feed, uint32 stale, uint16 jump) = ChainlinkFeedSource(d.chainlinkSource).feeds(address(nvda));
        assertEq(feed, address(nvdaFeed));
        assertEq(stale, 26 hours);
        assertEq(jump, 2000);
        (address p,,, uint32 window, uint128 floor) = UniV3TwapSource(d.univ3Source).pools(address(nvda));
        assertEq(p, address(pool));
        assertEq(window, 300);
        assertEq(floor, NVDA_FLOOR);
        (p,,,,) = UniV3TwapSource(d.univ3Source).pools(address(tsla));
        assertEq(p, address(0), "TSLA has no pool");

        (address[] memory sources, uint16 dev, uint32 delay, uint32 age) =
            SettlementOracle(d.settlementOracle).marketConfig(address(nvda));
        assertEq(sources.length, 2);
        assertEq(sources[0], d.chainlinkSource);
        assertEq(sources[1], d.univ3Source);
        assertEq(dev, 150);
        assertEq(delay, 21_600);
        assertEq(age, 3600);
        (sources,,,) = SettlementOracle(d.settlementOracle).marketConfig(address(tsla));
        assertEq(sources.length, 1, "TSLA: Chainlink only");
        assertEq(sources[0], d.chainlinkSource);

        // No payout route in this fixture (venue none, {_nvdaMarket}): neither market has one after registration.
        (address routePool, uint24 fee) = UniV3PayoutAdapter(d.payoutRouter).routes(address(nvda));
        assertEq(routePool, address(0), "NVDA: no route in this fixture");
        assertEq(fee, 0);
        (, fee) = UniV3PayoutAdapter(d.payoutRouter).routes(address(tsla));
        assertEq(fee, 0, "TSLA no route");
        (bool ok, uint256 spot,) = SettlementOracle(d.settlementOracle).trySpot(address(tsla));
        assertTrue(ok, "TSLA spot through the registered source");
        assertEq(spot, 358_040_000, "358.04: the last pushed round");

        // idempotent
        (registered, sent) = _launchRun(_registerInputs(d));
        assertEq(registered, 0, "nothing registered twice");
        assertEq(sent, 0, "nothing sent twice");

        // a drifted source config is put back; the registration is not repeated. (T-OP-205: the route-drift leg that
        // used to sit here -- setRoute(NVDA, 0) then "route restored" -- has no subject in this fixture, which carries
        // no payout route; the source de-listing below is the drift this case keeps.)
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        RegisterMarkets.Call[] memory calls;
        bool registers;

        // a source that stopped accepting the oracle's pins is re-allowed first (DeployV2 wired both; TSLA needs only
        // Chainlink, so the pool source is NVDA's call alone)
        vm.startPrank(deployer);
        ChainlinkFeedSource(d.chainlinkSource).setOracle(d.settlementOracle, false);
        UniV3TwapSource(d.univ3Source).setOracle(d.settlementOracle, false);
        vm.stopPrank();
        in_ = _registerInputs(d);
        (calls, registers) = registerScript.plan(in_, in_.markets[0]);
        assertFalse(registers, "no registration");
        assertEq(calls.length, 2, "NVDA: both sources re-allowed");
        assertEq(calls[0].what, "chainlinkSource.setOracle(settlementOracle, true)", "Chainlink first");
        assertEq(calls[1].what, "univ3Source.setOracle(settlementOracle, true)");
        (calls,) = registerScript.plan(in_, in_.markets[1]);
        assertEq(calls.length, 1, "TSLA: Chainlink only");
        (registered, sent) = _launchRun(in_);
        assertEq(sent, 2, "sent once, for NVDA; TSLA's plan is empty by then");
        assertTrue(ChainlinkFeedSource(d.chainlinkSource).isOracle(d.settlementOracle), "chainlink re-allowed");
        assertTrue(UniV3TwapSource(d.univ3Source).isOracle(d.settlementOracle), "pool re-allowed");
    }

    /// A registry row that drops NVDA's pool: the plan unlists the pool source before it removes the pool, so after
    /// every single call a first series of a new expiry can still pin (pinning fails closed while the list names an
    /// unconfigured source).
    /*//////////////////////////////////////////////////////////////
        T-OP-162: THE DEPLOYER AT EXECUTION DELAY 0 REGISTERS DIRECTLY
    //////////////////////////////////////////////////////////////*/

    // Launch day (owner decision 05:50Z, T-OP-153 / T-OP-161): inside the deferred window the deployer holds LISTING
    // and CONFIG_ADMIN at execution delay 0, and the driver runs this script with V2_ADMIN=<deployer>,
    // ADMIN_PK=<DEPLOYER_PK> and V2_SCHEDULE unset. The script has no special branch for it -- {_signerCanList} reads
    // the delays off the manager and {_executeScheduled} takes the single-run path -- and these cases pin that the
    // path exists, that it is the MANAGER's answer that opens it, and that the two ways it closes are refusals by
    // name before anything is sent. (The narrowing M-28bdec846189442d: verify and pin, not a new branch.)

    /// @dev The manager of the deployed set.
    function _mgr() internal view returns (AccessManager) {
        return AccessManager(Clearinghouse(d.clearinghouse).authority());
    }

    /// @dev One delayed Admin Safe mutation of the manager, the way the chain requires it after hand-over:
    ///      schedule from the Safe, wait the ADMIN execution delay, call the target. The feeds are refreshed across
    ///      the wait so the market preflight (`_feed`, V2_MAX_FEED_AGE_S) does not age out behind the test.
    function _adminExecute(bytes memory data) internal {
        AccessManager mgr = _mgr();
        // casting to 'bytes4' keeps the leading four bytes on purpose: they are the call's selector
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool immediate, uint32 delay) = mgr.canCall(adminSafe, address(mgr), bytes4(data));
        if (!immediate) {
            require(delay != 0, "the Safe cannot make this call at all");
            vm.prank(adminSafe);
            mgr.schedule(address(mgr), data, 0);
            vm.warp(block.timestamp + delay);
            nvdaFeed.push(NVDA_ANSWER, block.timestamp - 1 hours);
            tslaFeed.push(TSLA_ANSWER, block.timestamp - 1 hours);
        }
        vm.prank(adminSafe);
        (bool ok, bytes memory reason) = address(mgr).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    /// @dev The deferred window, made by hand: the fixture's {_deploy} ends with the deployer holding nothing, so
    ///      the Admin Safe grants (through its own delay) what DeployV8 step 4 would have left in place. `delay`
    ///      is the execution delay the deployer gets on each role.
    function _grantDeployer(uint32 delay) internal {
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (V8Roles.LISTING, deployer, delay)));
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (V8Roles.CONFIG_ADMIN, deployer, delay)));
    }

    /// @dev HandBack, the way DeployV8 does it: the holder renounces its transient roles, instantly.
    function _revokeDeployer() internal {
        vm.startPrank(deployer);
        _mgr().renounceRole(V8Roles.LISTING, deployer);
        _mgr().renounceRole(V8Roles.CONFIG_ADMIN, deployer);
        vm.stopPrank();
    }

    /// @dev The register step's inputs as the driver exports them in the window: V2_ADMIN is the deployer.
    function _inWindowInputs() internal view returns (RegisterMarkets.Inputs memory in_) {
        in_ = _registerInputs(d);
        in_.admin = deployer;
    }

    /// @dev T-OP-205. The thirteen registration cases below used to run `runWith(..., _signer(adminSafe))` in ONE
    ///      run; since the T-217 hand-over the Safe holds LISTING at 3600 s / CONFIG_ADMIN at 86400 s and
    ///      {_signerCanList} refuses a delayed signer in a single run, so every one of them died in that preflight
    ///      (13/19 red since then). The LANDED registration path is the launch-day one (T-OP-161/162, owner decision
    ///      05:50Z): the deployer registers DIRECTLY inside the deferred window it holds at execution delay 0; the
    ///      Safe-scheduled path stays for post-launch listings and is pinned by {test_register_safeAdminDelayedPathUnchanged}.
    ///      So the cases open the window once and sign as the deployer; the admin mutations they make between runs
    ///      (a route cleared, a source de-listed, a pointer broken) are the in-window deployer's too, at delay 0 --
    ///      the Safe's own calls on the targets would need their lane's delay and a schedule, which is not the
    ///      subject of any of them. What each case ASSERTS (calls planned, values reaching the contracts, refusals
    ///      by name) is unchanged; only the signer moved to the path the chain actually takes.
    bool internal launchWindowOpen;

    function _launch() internal {
        if (launchWindowOpen) return;
        _grantDeployer(0);
        launchWindowOpen = true;
    }

    /// @dev The launch window carries LISTING + CONFIG_ADMIN only (DeployV8 step 4); launch day registers every market at
    ///      rent 0, so it never sends `setMarketFees`. The four rent cases below register or re-price a market at a
    ///      NON-ZERO rate (the v7 mechanics, kept under the v8 opt-in), and that call rides the MARKET_FEE_MANAGER
    ///      lane -- the Safe's 72 h lane after launch. In this dev fixture the window is widened by that one role at
    ///      delay 0 so the case can send it; a broadcast never has it (`rentAllowed` is test-only).
    function _grantDeployerFeeManager() internal {
        _launch();
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (V8Roles.MARKET_FEE_MANAGER, deployer, 0)));
    }

    /// @dev The v8 refusal for a rent-bearing registration without the opt-in (V2DeployBase._WHY_RENT, verbatim).
    function _rentRefusal(string memory ticker, uint256 ppm) internal pure returns (string memory) {
        return string.concat(
            ticker,
            ": mintFeePpm is ",
            vm.toString(ppm),
            ", not 0. INTERFACE_VERSION 8 charges 5% of the premium on first sale and launches collateral rent at 0 on every market"
            " (V8-DESIGN 4.3), so a deploy script must never put a rent-bearing market on chain: turn rent on afterwards"
            " through Clearinghouse.setMarketFees under the 72 h MARKET_FEE_MANAGER lane. The rent opt-in is honoured only"
            " under forge test (the fixtures); no forge script run reaches it, whatever the RPC, the chain id or the flags."
        );
    }

    /// @dev `runWith` as the driver runs it on launch day: V2_ADMIN = the deployer, signer = the deployer, no schedule.
    ///      Only the fixture's default admin (the Safe) is re-pointed at the deployer: a case that sets `in_.admin` to
    ///      something else on purpose (the V2_ADMIN refusal in {test_preflight_everyRefusalInOrder}) keeps its value.
    function _launchRun(RegisterMarkets.Inputs memory in_) internal returns (uint256 registered, uint256 sent) {
        _launch();
        if (in_.admin == adminSafe) in_.admin = deployer;
        return registerScript.runWith(in_, _signer(deployer));
    }

    /// @notice (a) Direct path: the deployer at delay 0 registers the launch set in ONE run -- no V2_SCHEDULE, no
    ///         Safe, and the calls land. The preflight line names the signer that actually sends.
    function test_register_deployerAtDelayZero_registersDirectlyInOneRun() public {
        _grantDeployer(0);
        (bool listing, uint32 listingDelay) = _mgr().hasRole(V8Roles.LISTING, deployer);
        (bool config, uint32 configDelay) = _mgr().hasRole(V8Roles.CONFIG_ADMIN, deployer);
        assertTrue(listing && config && listingDelay == 0 && configDelay == 0, "the window is open");
        // V2_SCHEDULE is unset in this process (the base script reads the environment; nothing here sets it).
        (uint256 registered, uint256 sent) = registerScript.runWith(_inWindowInputs(), _signer(deployer));
        assertEq(registered, 2, "two registerMarket calls, sent directly by the deployer");
        // NVDA: setFeed, setPool, setMarket, registerMarket (no payout route in this fixture); TSLA: setFeed,
        // setMarket, registerMarket. Measured from the run's own `call` lines, not assumed.
        assertEq(sent, 7, "7 direct calls, none scheduled");
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        assertTrue(ch.market(address(nvda)).enabled, "NVDA registered and enabled");
        assertEq(ch.market(address(tsla)).strikeTick, TICK_2_50, "TSLA registered");
        // Nothing waits in the manager: a re-run sends nothing, which is how a scheduled operation would show.
        (registered, sent) = registerScript.runWith(_inWindowInputs(), _signer(deployer));
        assertEq(registered + sent, 0, "idempotent: nothing left to send and nothing pending");
    }

    /// @notice (b) Fail-closed by the manager, not a flag: the same environment after HandBack dies in the preflight,
    ///         by name, before any call -- and a signer that holds the roles at a DELAY is refused too.
    function test_register_afterHandBack_sameEnvIsRefusedByName() public {
        _grantDeployer(0);
        _revokeDeployer();
        (bool listing,) = _mgr().hasRole(V8Roles.LISTING, deployer);
        assertFalse(listing, "the window is closed");
        vm.expectRevert(
            bytes(string.concat("signer ", vm.toString(deployer), " does not hold LISTING on the accessManager"))
        );
        registerScript.runWith(_inWindowInputs(), _signer(deployer));
        assertEq(Clearinghouse(d.clearinghouse).market(address(nvda)).strikeTick, 0, "nothing was sent");

        // The roles back, but at the manifest's delays: not a single-run signer.
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (V8Roles.LISTING, deployer, V8Roles.LISTING_DELAY)));
        _adminExecute(
            abi.encodeCall(IAccessManager.grantRole, (V8Roles.CONFIG_ADMIN, deployer, V8Roles.CONFIG_ADMIN_DELAY))
        );
        vm.expectRevert(
            bytes(
                string.concat(
                    "signer ",
                    vm.toString(deployer),
                    " holds LISTING at ",
                    vm.toString(uint256(V8Roles.LISTING_DELAY)),
                    "s and CONFIG_ADMIN at ",
                    vm.toString(uint256(V8Roles.CONFIG_ADMIN_DELAY)),
                    "s: a delayed signer cannot register in a single run. Re-run with V2_SCHEDULE=true and",
                    " V2_SCHEDULE_PHASE=schedule, move the node clock past the delay, then run again with",
                    " V2_SCHEDULE_PHASE=execute."
                )
            )
        );
        registerScript.runWith(_inWindowInputs(), _signer(deployer));
        assertEq(Clearinghouse(d.clearinghouse).market(address(nvda)).strikeTick, 0, "still nothing sent");
    }

    /// @notice (c) The Safe path is unchanged: with V2_ADMIN the Safe (the registry's value), a delayed signer is
    ///         refused in one run exactly as before, so post-launch listings still go through V2_SCHEDULE.
    function test_register_safeAdminDelayedPathUnchanged() public {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        assertEq(in_.admin, adminSafe, "V2_ADMIN is the Safe outside the window");
        // After hand-over the Safe holds LISTING and CONFIG_ADMIN at the manifest's delays (which is why every
        // one-run registration from the Safe in this file is refused since T-217). Read both delays off the
        // manager: the refusal must quote what the manager says, not what this test assumes.
        (, uint32 listingDelay) = _mgr().hasRole(V8Roles.LISTING, adminSafe);
        (, uint32 configDelay) = _mgr().hasRole(V8Roles.CONFIG_ADMIN, adminSafe);
        assertTrue(listingDelay != 0 || configDelay != 0, "the Safe is a delayed signer after hand-over");
        vm.expectRevert(
            bytes(
                string.concat(
                    "signer ",
                    vm.toString(adminSafe),
                    " holds LISTING at ",
                    vm.toString(uint256(listingDelay)),
                    "s and CONFIG_ADMIN at ",
                    vm.toString(uint256(configDelay)),
                    "s: a delayed signer cannot register in a single run. Re-run with V2_SCHEDULE=true and",
                    " V2_SCHEDULE_PHASE=schedule, move the node clock past the delay, then run again with",
                    " V2_SCHEDULE_PHASE=execute."
                )
            )
        );
        registerScript.runWith(in_, _signer(adminSafe));
    }

    function test_register_droppedPool_unlistsBeforeUnconfiguring() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        _launchRun(_registerInputs(d));
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        (in_.markets[0].pool, in_.markets[0].minLiquidity, in_.markets[0].poolFee) = (address(0), 0, 0);
        (RegisterMarkets.Call[] memory calls,) = registerScript.plan(in_, in_.markets[0]);
        assertEq(calls.length, 2, "setMarket, setPool(0) (no route to clear in this fixture; T-OP-205)");
        assertEq(calls[0].to, d.settlementOracle, "the list first");
        assertEq(
            calls[1].what, "univ3Source.setPool(NVDA, 0): remove a pool the registry does not list", "then the pool"
        );
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = calls[i].to.call(calls[i].data);
            assertTrue(ok, calls[i].what);
            uint256 snap = vm.snapshotState();
            vm.prank(d.clearinghouse);
            // casting to 'uint40' is safe because i < 3
            // forge-lint: disable-next-line(unsafe-typecast)
            SettlementOracle(d.settlementOracle).pin(address(nvda), uint40(2_000_000_000 + i));
            vm.revertToState(snap);
        }
        (address p,,,,) = UniV3TwapSource(d.univ3Source).pools(address(nvda));
        assertEq(p, address(0), "pool removed");
    }

    function test_preflight_everyRefusalInOrder() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_;

        // ---------------------------------------------------------------- the contract set
        in_ = _registerInputs(d);
        in_.markets = new V2DeployBase.MarketIn[](0);
        _refused(in_, "V2_TICKERS is empty");

        in_ = _registerInputs(d);
        in_.c.payoutRouter = address(0);
        _refused(in_, "V2_PAYOUT_ROUTER is zero");

        MockERC20 otherUsdg = new MockERC20("Global Dollar", "USDG", 6);
        in_ = _registerInputs(d);
        in_.usdg = address(otherUsdg);
        _refused(
            in_,
            string.concat(
                "clearinghouse.usdg() ", vm.toString(address(usdg)), " is not V2_USDG ", vm.toString(address(otherUsdg))
            )
        );

        // T-OP-205: the v7 refusal here ("V2_ADMIN ... does not hold DEFAULT_ADMIN_ROLE on the Clearinghouse") no longer
        // exists -- every target is AccessManaged and {_signerCanList} judges the SIGNER's roles on the manager
        // (RegisterMarkets.s.sol:339-377). The landed equivalent: a signer that holds no LISTING is refused by name
        // before anything is sent. (The in-window deployer's own refusal after HandBack is
        // {test_register_afterHandBack_sameEnvIsRefusedByName}.)
        in_ = _registerInputs(d);
        in_.admin = guardianKey;
        vm.expectRevert(
            bytes(string.concat("signer ", vm.toString(guardianKey), " does not hold LISTING on the accessManager"))
        );
        registerScript.runWith(in_, _signer(guardianKey));

        vm.prank(deployer);
        SettlementOracle(d.settlementOracle).setClearinghouse(address(0));
        _refused(
            _registerInputs(d),
            "settlementOracle.clearinghouse() 0x0000000000000000000000000000000000000000 is not V2_CLEARINGHOUSE: every createSeries would revert in oracle.pin (run the deploy wiring first)"
        );
        vm.prank(deployer);
        SettlementOracle(d.settlementOracle).setClearinghouse(d.clearinghouse);

        in_ = _registerInputs(d);
        in_.exerciseFeeBps = 201;
        _refused(in_, "V2_EXERCISE_FEE_BPS above EXERCISE_FEE_CEIL_BPS (200)");

        in_ = _registerInputs(d);
        in_.markets[1] = _nvdaMarket();
        _refused(in_, "duplicate ticker in V2_TICKERS");

        // ---------------------------------------------------------------- the token (TSLA row)
        MockStockToken aapl = new MockStockToken("Apple Stock Token", "AAPL");
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(aapl);
        _refused(
            in_,
            string.concat(
                "asset symbol mismatch: V2_MARKET_TSLA_ASSET ",
                vm.toString(address(aapl)),
                " is \"AAPL\", ticker is \"TSLA\""
            )
        );

        MockERC20 sixDp = new MockERC20("Tesla", "TSLA", 6);
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(sixDp);
        _refused(in_, "TSLA: asset decimals != 18");

        MockERC20 plain = new MockERC20("Tesla", "TSLA", 18);
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(plain);
        _refused(in_, "TSLA: asset uiMultiplier() probe failed: not a Robinhood Stock Token?");

        tsla.setUiMultiplier(0);
        _refused(_registerInputs(d), "TSLA: asset uiMultiplier() == 0");
        tsla.setUiMultiplier(1e18);

        tsla.setOraclePaused(true);
        _refused(_registerInputs(d), "TSLA: asset oraclePaused() is true: the issuer has halted its oracle");
        tsla.setOraclePaused(false);

        // ---------------------------------------------------------------- the feed
        MockRoundFeed aaplFeed = _feed("Robinhood AAPL / USD", TSLA_ANSWER);
        in_ = _registerInputs(d);
        in_.markets[1].feed = address(aaplFeed);
        _refused(
            in_,
            string.concat(
                "feed description mismatch: V2_MARKET_TSLA_FEED ",
                vm.toString(address(aaplFeed)),
                " is \"Robinhood AAPL / USD\", ticker is \"TSLA\""
            )
        );

        MockRoundFeed sixDpFeed = new MockRoundFeed(6, "RHTSLA / USD");
        sixDpFeed.push(358_040000, START - 1 hours);
        in_ = _registerInputs(d);
        in_.markets[1].feed = address(sixDpFeed);
        _refused(in_, "TSLA: unexpected feed decimals");

        MockRoundFeed zeroFeed = new MockRoundFeed(8, "RHTSLA / USD");
        zeroFeed.push(0, START - 1 hours);
        in_ = _registerInputs(d);
        in_.markets[1].feed = address(zeroFeed);
        _refused(in_, "TSLA: feed answer <= 0");

        // The age is measured from `block.timestamp`, which the launch window's two scheduled grants moved forward
        // (T-OP-205: {_launch} warps twice by the ADMIN delay), so it is computed, not typed as 5 days.
        MockRoundFeed staleFeed = new MockRoundFeed(8, "RHTSLA / USD");
        staleFeed.push(TSLA_ANSWER, START - 5 days);
        in_ = _registerInputs(d);
        in_.markets[1].feed = address(staleFeed);
        _refused(
            in_,
            string.concat(
                "TSLA: feed is stale: age ",
                vm.toString(block.timestamp - (START - 5 days)),
                " s > V2_MAX_FEED_AGE_S 345600"
            )
        );

        // ---------------------------------------------------------------- parameters
        in_ = _registerInputs(d);
        in_.markets[1].strikeTick = 2_500_050;
        _refused(in_, "TSLA: strikeTick 2500050 must be a non-zero multiple of 100");

        in_ = _registerInputs(d);
        in_.markets[1].maxDeviationBps = 1001;
        _refused(in_, "TSLA: maxDeviationBps outside [1, 1000]");

        in_ = _registerInputs(d);
        in_.markets[1].uncorroboratedDelay = 600;
        _refused(in_, "TSLA: uncorroboratedDelay outside [1800, 86400] s");

        in_ = _registerInputs(d);
        in_.markets[1].spotMaxAge = 0;
        _refused(in_, "TSLA: spotMaxAge outside [1, 345600] s");

        in_ = _registerInputs(d);
        in_.markets[1].minLiquidity = 1;
        _refused(in_, "TSLA: univ3MinLiquidity set without a pool");

        // ---------------------------------------------------------------- the pool (NVDA row)
        MockUniV3Pool tslaPool = new MockUniV3Pool(address(usdg), address(tsla), 500);
        in_ = _registerInputs(d);
        in_.markets[0].pool = address(tslaPool);
        _refused(
            in_,
            string.concat(
                "NVDA: pool tokens ",
                vm.toString(address(usdg)),
                ", ",
                vm.toString(address(tsla)),
                " are not {asset, USDG}"
            )
        );

        in_ = _registerInputs(d);
        in_.markets[0].poolFee = 3000;
        _refused(in_, "NVDA: pool fee() 500 is not V2_MARKET_NVDA_POOL_FEE 3000");

        MockUniV3Pool costly = new MockUniV3Pool(address(nvda), address(usdg), 20_000);
        in_ = _registerInputs(d);
        in_.markets[0].pool = address(costly);
        in_.markets[0].poolFee = 20_000;
        _refused(
            in_,
            "NVDA: pool fee tier 20000 is above 10000 (1 %): the Clearinghouse counts at most MAX_ROUTE_FEE_BPS (100 bps) of a payout route's fee, so every conversion through this pool would pay in kind, and UniV3PayoutAdapter.setRoute refuses it (CeilingExceeded)"
        );

        MockUniV3Pool stray = new MockUniV3Pool(address(nvda), address(usdg), 3000);
        in_ = _registerInputs(d);
        in_.markets[0].pool = address(stray);
        in_.markets[0].poolFee = 0;
        _refused(
            in_,
            "NVDA: the Uniswap v3 factory's (asset, USDG) pool at fee 3000 is 0x0000000000000000000000000000000000000000, not the registry pool"
        );

        pool.setLiquidity(0);
        _refused(_registerInputs(d), "NVDA: pool liquidity() == 0");
        pool.setLiquidity(POOL_LIQUIDITY);

        pool.setObserveReverts(true);
        _refused(_registerInputs(d), "NVDA: pool observe([1800, 0]) failed: no 30-minute TWAP");
        pool.setObserveReverts(false);

        // sweep contracts-c10: a ring the live 1801-slot pools could have flooded past a snapshot's window
        pool.setObservationCardinality(2400);
        _refused(
            _registerInputs(d),
            "NVDA: pool observationCardinality 2400 is below 2401 (SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1): one dust mint or burn per second could overwrite an expiry's window before the snapshot grace ends, and UniV3TwapSource.setPool refuses the pool (UnsupportedAsset); call increaseObservationCardinalityNext(2401) on the pool and wait until slot0().observationCardinality reaches it"
        );
        pool.setObservationCardinality(type(uint16).max);

        in_ = _registerInputs(d);
        in_.markets[0].minLiquidity = 0;
        _refused(in_, "NVDA: univ3MinLiquidity must be > 0 with a pool");

        // ---------------------------------------------------------------- already registered with another config
        _launchRun(_registerInputs(d));
        in_ = _registerInputs(d);
        in_.markets[1].strikeTick = 1_000_000;
        _refused(
            in_,
            string.concat(
                "TSLA: already registered on the Clearinghouse with another config (enabled true, strikeTick 2500000, exerciseFeeBps 25, mintFeePpm 0, oracle ",
                vm.toString(d.settlementOracle),
                "): change a live market with setMarketConfig by hand, not here"
            )
        );

        // a pool under its floor only warns: registration goes through (the config already matches, so nothing to send)
        in_ = _registerInputs(d);
        in_.markets[0].minLiquidity = POOL_LIQUIDITY + 1;
        (RegisterMarkets.Call[] memory calls,) = registerScript.plan(in_, in_.markets[0]);
        assertEq(calls.length, 1, "only the floor differs");
        _launchRun(in_);
        (,,,, uint128 floor) = UniV3TwapSource(d.univ3Source).pools(address(nvda));
        assertEq(floor, POOL_LIQUIDITY + 1, "floor above live liquidity accepted with a WARN");
    }

    /// @dev Expect `runWith` to revert with exactly `reason`, with no adminSafe call sent: every preflight runs first.
    /*//////////////////////////////////////////////////////////////
                   COLLATERAL RENT (INTERFACE_VERSION 7)
    //////////////////////////////////////////////////////////////*/

    /// @notice The per-market rate reaches `MarketConfig.mintFeePpm`, and a re-run at the same rate sends nothing.
    /// @dev The rates are the design's §5.1 launch values (NVDA 80); TSLA keeps 0 here, so the same run covers both a
    ///      market that charges rent and one that does not. A 0 needs `allowRent`, which is what a local fixture
    ///      or a devnet passes (DECISIONS §11) -- a run that can broadcast never has it.
    function test_register_mintFeePpmReachesTheMarketConfig() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm = new uint32[](2);
        in_.mintFeePpm[0] = 80;
        in_.allowRent = true; // C8-10A: the v8 opt-in name; the guard is inverted (V8-DESIGN 4.3)
        _grantDeployerFeeManager(); // setMarketFees(NVDA, 25, 80) rides the MARKET_FEE_MANAGER lane
        _launchRun(in_);

        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        assertEq(ch.market(address(nvda)).mintFeePpm, 80, "NVDA registered at the opted-in rate");
        assertEq(ch.market(address(tsla)).mintFeePpm, 0, "TSLA registered with no rent");

        // A series created afterwards pins the rate and charges it.
        uint256 longId = ch.createSeries(address(nvda), false, 220_000_000, _nextWeekly());
        assertEq(ch.series(longId).mintFeePpm, 80, "pinned at creation");
        assertGt(ch.mintFee(longId, 100), 0, "and charged");

        (RegisterMarkets.Call[] memory again,) = registerScript.plan(in_, in_.markets[0]);
        assertEq(again.length, 0, "a re-run at the same rate sends nothing");
    }

    /*//////////////////////////////////////////////////////////////
                    STAGED LISTING (C3-102)
    //////////////////////////////////////////////////////////////*/

    /// @notice `enabled` follows the registry row: planned registers disabled; createSeries reverts MarketDisabled.
    function test_register_plannedRowRegistersDisabledAndCannotCreateSeries() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.markets[1].enabled = false; // TSLA planned
        _launchRun(in_);

        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        assertTrue(ch.market(address(nvda)).enabled, "NVDA live stays enabled");
        assertFalse(ch.market(address(tsla)).enabled, "planned TSLA is disabled");

        uint40 expiry = _nextWeekly();
        vm.expectRevert(V2Errors.MarketDisabled.selector);
        ch.createSeries(address(tsla), false, 220_000_000, expiry);
    }

    /// @notice --resync of a disabled market sends setMarketListing to enable (the staged listing, C3-102); the call
    ///         matches the registry.
    function test_register_resyncEnableSendsSetMarketConfig() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.markets[0].enabled = false;
        _launchRun(in_);
        assertFalse(Clearinghouse(d.clearinghouse).market(address(nvda)).enabled);

        in_.markets[0].enabled = true;
        in_.resync = true;
        (RegisterMarkets.Call[] memory calls, bool registers) = registerScript.plan(in_, in_.markets[0]);
        assertFalse(registers, "already registered");
        assertEq(calls.length, 1, "one setMarketListing");
        // The landed re-enable is the staged listing call on the LISTING lane (C3-102), not setMarketConfig (T-OP-205).
        assertEq(
            calls[0].what,
            string.concat(
                "clearinghouse.setMarketListing(NVDA, enabled, strikeTick ", vm.toString(uint256(TICK_2_50)), "): LISTING lane, 1 h"
            )
        );
        _launchRun(in_);
        assertTrue(Clearinghouse(d.clearinghouse).market(address(nvda)).enabled, "enabled after resync");
        uint256 longId = Clearinghouse(d.clearinghouse).createSeries(address(nvda), false, 220_000_000, _nextWeekly());
        assertGt(longId, 0, "createSeries after enable");
    }

    /// @notice An enabled market refuses a mintFeePpm change even under --resync.
    function test_register_enabledRentChangesRefused() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        _launchRun(in_);
        in_.resync = true;
        in_.mintFeePpm[0] = 200;
        in_.allowRent = true; // v8: a non-zero rate needs the opt-in, or the rent refusal fires before this one
        _refused(in_, "NVDA: enabled mintFeePpm changes refused (mintFeePpm 0 -> 200): disable the market first");
    }

    /// @notice An enabled market refuses a strikeTick change even under --resync.
    function test_register_enabledTickChangesRefused() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        _launchRun(in_);
        in_.resync = true;
        in_.markets[0].strikeTick = 1_000_000;
        _refused(in_, "NVDA: enabled tick changes refused (strikeTick 2500000 -> 1000000): disable the market first");
    }

    /// @notice Unchanged NVDA (live, already matching) produces no adminSafe call, with or without --resync.
    function test_register_unchangedNvdaProducesNoCall() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        _launchRun(in_);
        (RegisterMarkets.Call[] memory calls, bool registers) = registerScript.plan(in_, in_.markets[0]);
        assertEq(calls.length, 0);
        assertFalse(registers);
        in_.resync = true;
        (calls, registers) = registerScript.plan(in_, in_.markets[0]);
        assertEq(calls.length, 0, "resync of an unchanged live row is a no-op");
        assertFalse(registers);
    }

    /// @notice While disabled, --resync may change strikeTick and mintFeePpm.
    function test_register_resyncTickAndRentWhileDisabled() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.markets[0].enabled = false;
        _launchRun(in_);
        in_.resync = true;
        in_.markets[0].strikeTick = 1_000_000;
        in_.mintFeePpm[0] = 200;
        in_.allowRent = true; // v8 opt-in (test context only)
        _grantDeployerFeeManager(); // the rate change is setMarketFees on the MARKET_FEE_MANAGER lane
        _launchRun(in_);
        V2Types.MarketConfig memory n = Clearinghouse(d.clearinghouse).market(address(nvda));
        assertFalse(n.enabled);
        assertEq(n.strikeTick, 1_000_000);
        assertEq(n.mintFeePpm, 200);
    }

    /// @notice A market already registered at another rate is refused, so a re-run cannot silently re-price mints.
    /// @dev `setMarketConfig` reaches NEW series only, so changing a live market's rate is a deliberate adminSafe act, not
    ///      something a registry re-run does on its own.
    function test_register_refusesAMarketAlreadyRegisteredAtAnotherRate() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d); // rent 0 on both (v8 launch value)
        _launchRun(in_);

        in_.mintFeePpm[0] = 200;
        in_.allowRent = true; // v8 opt-in, so the "another config" refusal is the one that fires
        _refused(
            in_,
            string.concat(
                "NVDA: already registered on the Clearinghouse with another config (enabled true, strikeTick 2500000, exerciseFeeBps 25, mintFeePpm 0, oracle ",
                vm.toString(d.settlementOracle),
                "): change a live market with setMarketConfig by hand, not here"
            )
        );
    }

    /// @notice A rate above MINT_FEE_CEIL_PPM is refused in the preflight, naming the ticker and the variable, before
    ///         anything is broadcast -- rather than reverting CeilingExceeded halfway through a 35-market run.
    function test_register_refusesAMintFeePpmAboveTheCeiling() public {
        _launch(); // T-OP-205: launch-day signer (the deployer inside the deferred window), see {_launchRun}
        RegisterMarkets.Inputs memory in_ = _registerInputs(d); // rent 0 on both (v8 launch value)
        in_.allowRent = true; // v8 opt-in: the ceiling is checked after the rent refusal
        in_.mintFeePpm[0] = V2Constants.MINT_FEE_CEIL_PPM + 1;
        _refused(
            in_,
            "NVDA: mintFeePpm 5001 is above MINT_FEE_CEIL_PPM (5000): lower V2_MARKET_NVDA_MINT_FEE_PPM or V2_MINT_FEE_PPM"
        );

        // The ceiling itself registers (a rate reaches the chain through setMarketFees: the fee-manager lane).
        in_.mintFeePpm[0] = V2Constants.MINT_FEE_CEIL_PPM;
        _grantDeployerFeeManager();
        _launchRun(in_);
        assertEq(
            Clearinghouse(d.clearinghouse).market(address(nvda)).mintFeePpm,
            V2Constants.MINT_FEE_CEIL_PPM,
            "the ceiling is allowed"
        );
    }

    /// @notice A market with a NON-ZERO rent rate is refused before anything is broadcast (INTERFACE_VERSION 8 launches
    ///         rent at 0 and takes 5% of the premium on first sale, V8-DESIGN 4.3); the only way through is `allowRent`,
    ///         honoured under forge test alone. Zero needs no opt-in.
    function test_register_refusesANonZeroRentRateUnlessOptedIn() public {
        // T-OP-205. This case used to pin the v7 rule (a ZERO rate refused unless opted in). V8-DESIGN 4.3 inverted it:
        // launch is rent 0 on every market, a NON-ZERO rate is refused by name unless the test-only opt-in is set, and
        // the refusal points at setMarketFees under the 72 h MARKET_FEE_MANAGER lane for turning rent on afterwards.
        _launch();
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = 300; // TSLA
        _refused(in_, _rentRefusal("TSLA", 300));

        // zero on every market is the launch value and needs no opt-in
        in_ = _registerInputs(d);
        (uint256 registered,) = _launchRun(in_);
        assertEq(registered, 2, "rent 0 registers without any opt-in");
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        assertEq(ch.market(address(nvda)).mintFeePpm, 0, "NVDA at 0");
        assertEq(ch.market(address(tsla)).mintFeePpm, 0, "TSLA at 0");
    }


    /*//////////////////////////////////////////////////////////////
                         TRANSFER PROBE (SEC-12)
    //////////////////////////////////////////////////////////////*/

    /// @dev SEC-12, through `runWith`. Each token below passes every other preflight check, so each refusal is the
    ///      probe's own. A fee the RECIPIENT absorbs does not break I2' at the Clearinghouse, and the probe refuses it
    ///      anyway: the listed universe is tokens that move exactly the amount.
    function test_preflight_transferProbeRefusesAnInexactToken() public {
        ProbeSchedulePhaseHarness run = new ProbeSchedulePhaseHarness();
        uint256 amount = run.TRANSFER_PROBE_AMOUNT();
        uint256 fee = amount * 100 / 10_000;
        RegisterMarkets.Inputs memory in_;

        // The sender pays on top: the holder was seeded 2 * amount and is debited amount + fee.
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(new FeeChargingStockToken("TSLA", 100, true));
        _probeRefused(run, in_, _inexact("deposit", amount - fee, amount, amount, amount));

        // The recipient pays: the Clearinghouse is credited amount - fee.
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(new FeeChargingStockToken("TSLA", 100, false));
        _probeRefused(run, in_, _inexact("deposit", amount, amount, amount - fee, amount));

        // A balance computed from two slots cannot be seeded, so it is refused before either leg.
        in_ = _registerInputs(d);
        in_.markets[1].asset = address(new ScaledBalanceStockToken("TSLA"));
        _probeRefused(
            run,
            in_,
            "TSLA: asset transfer probe cannot seed a balance: balanceOf is not one storage slot (a rebasing or"
            " computed balance?)"
        );

        // A token that cannot move at all right now (the issuer paused it) is refused at the leg that reverted.
        tsla.pause();
        _probeRefused(
            run,
            _registerInputs(d),
            "TSLA: asset transfer probe: transferFrom into the Clearinghouse reverted or returned false"
        );
        tsla.unpause();

        // The positive control: the same inputs with the plain fixture tokens pass the probe and the run completes
        // its schedule phase. The refusals above were the probe's, not the fixture's.
        (uint256 registered, uint256 sent) = run.runWith(_registerInputs(d), _signer(adminSafe));
        assertEq(registered + sent, 0, "the schedule phase registers and sends nothing to the targets");
    }

    /// @dev The probe on its own: a plain Stock Token passes, and it leaves nothing behind -- no seeded balance, no
    ///      approval, the Clearinghouse's balance and the supply as they were.
    function test_preflight_transferProbePassesAPlainTokenAndLeavesNoTrace() public {
        address holder = registerScript.TRANSFER_PROBE_HOLDER();
        uint256 held = tsla.balanceOf(d.clearinghouse);
        uint256 supply = tsla.totalSupply();
        registerScript.probeTransfers(_registerInputs(d), _tslaMarket());
        assertEq(tsla.balanceOf(holder), 0, "the seeded balance is gone");
        assertEq(tsla.allowance(holder, d.clearinghouse), 0, "the approval is gone");
        assertEq(tsla.balanceOf(d.clearinghouse), held, "the Clearinghouse holds what it held");
        assertEq(tsla.totalSupply(), supply, "the supply did not move");
    }

    /// @dev A market already registered is not probed: a --resync must not fail because its issuer paused transfers.
    ///      TSLA is registered through the manager (schedule, wait out LISTING's delay, call from the Safe), then
    ///      paused; the run preflights it as registered with this config and does not refuse it.
    function test_preflight_transferProbeSkipsARegisteredMarket() public {
        V2DeployBase.MarketIn memory m = _tslaMarket();
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        bytes memory data = abi.encodeCall(Clearinghouse.registerMarket, (m.asset, m.strikeTick, m.enabled));
        AccessManager manager = AccessManager(ch.authority());
        vm.prank(adminSafe);
        manager.schedule(address(ch), data, 0);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(adminSafe);
        ch.registerMarket(m.asset, m.strikeTick, m.enabled);
        assertEq(ch.market(address(tsla)).strikeTick, m.strikeTick, "TSLA is registered");

        tsla.pause();
        ProbeSchedulePhaseHarness run = new ProbeSchedulePhaseHarness();
        run.runWith(_registerInputs(d), _signer(adminSafe));

        // Control: the same paused token IS refused while it is not registered, directly through the probe.
        vm.expectRevert(
            bytes("TSLA: asset transfer probe: transferFrom into the Clearinghouse reverted or returned false")
        );
        run.probeTransfers(_registerInputs(d), m);
    }

    /// @dev `runWith` must revert with exactly `reason`; the revert undoes anything the run did.
    function _probeRefused(ProbeSchedulePhaseHarness run, RegisterMarkets.Inputs memory in_, string memory reason)
        internal
    {
        vm.expectRevert(bytes(reason));
        run.runWith(in_, _signer(adminSafe));
    }

    function _inexact(string memory leg, uint256 fromGot, uint256 fromWant, uint256 toGot, uint256 toWant)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "TSLA: asset does not transfer exactly: the ",
            leg,
            " leg left the sender ",
            vm.toString(fromGot),
            " (expected ",
            vm.toString(fromWant),
            ") and the recipient ",
            vm.toString(toGot),
            " (expected ",
            vm.toString(toWant),
            ")"
        );
    }

    /// @dev The next weekly expiry the calendar accepts, so a series can be created in a test.
    function _nextWeekly() internal view returns (uint40) {
        return ExpiryCalendar(d.expiryCalendar).nextExpiry(uint40(block.timestamp), true);
    }

    function _refused(RegisterMarkets.Inputs memory in_, string memory reason) internal {
        uint256 registeredBefore = Clearinghouse(d.clearinghouse).market(address(nvda)).strikeTick;
        vm.expectRevert(bytes(reason));
        _launchRun(in_);
        assertEq(
            Clearinghouse(d.clearinghouse).market(address(nvda)).strikeTick, registeredBefore, "nothing registered"
        );
    }
}
