// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployV2Fixture, MockExternalTarget} from "./DeployV2Fixture.t.sol";
import {console2} from "forge-std/console2.sol";
import {VerifyV8, VERIFY_V8_FLYWHEEL_POINTERS} from "../../../script/v2/VerifyV8.s.sol";
import {DEPLOY_V8_SPLITTER_POINTERS, DeployV8} from "../../../script/v2/DeployV8.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {RegisterMarketsHarness} from "./AccessManagerDelays.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {IFeeDiscount} from "../../../src/v2/interfaces/IFeeDiscount.sol";
import {FeeSplitter} from "../../../src/v2/periphery/FeeSplitter.sol";
import {V4BuybackExecutor} from "../../../src/v2/periphery/V4BuybackExecutor.sol";

/// @dev Counts the production walk without replacing it: the override delegates every target to VerifyV8's real
///      artifact reader. A narrowed outer loop therefore stays observable even though each target now gets a fresh
///      EVM memory frame.
contract VerifyV8TargetCounter is VerifyV8 {
    uint256 public targetsVisited;

    function _noUnlistedRestrictedTarget(
        V2DeployBase.Contracts memory c,
        AccessManager mgr,
        string memory json,
        string memory targetName
    ) public override returns (bool clean) {
        ++targetsVisited;
        return super._noUnlistedRestrictedTarget(c, mgr, json, targetName);
    }
}

/// @dev T-426. Records the NAME of every failed check, because a count cannot say WHICH check caught something.
///      `_check` is `virtual` for exactly this (T-258's note above says so), and the override delegates, so the
///      production walk is the thing being observed rather than a reimplementation of it.
contract VerifyV8FailureNames is VerifyV8 {
    string[] internal failedChecks;
    string[] internal notCheckedNames;

    function _check(bool ok, string memory what) internal override {
        if (!ok) failedChecks.push(what);
        super._check(ok, what);
    }

    /// @dev SEC-38-R. Same idea as `_check` above: record the name, then delegate to the production report.
    function _notChecked(string memory what) internal override {
        notCheckedNames.push(what);
        super._notChecked(what);
    }

    /// @dev T-OP-140. The NOT CHECKED TARGET group (V2_SKIP_EXTERNALS), observed by name the same way. `where` is
    ///      the group that declined to read the target; a target is recorded once however many groups decline.
    string[] internal skippedNames;
    string[] internal skippedWhere;

    function _skippedTarget(string memory name, string memory where) internal override {
        skippedNames.push(name);
        skippedWhere.push(where);
        super._skippedTarget(name, where);
    }

    /// @dev How many DISTINCT targets the verdict line would report as NOT CHECKED (the production list).
    function skippedCount() external view returns (uint256) {
        return skippedTargets.length;
    }

    /// @dev How many times some group declined to read `name`: the reach of the skip, group by group.
    function skippedTimes(string memory name) external view returns (uint256 n) {
        for (uint256 i; i < skippedNames.length; ++i) {
            if (keccak256(bytes(skippedNames[i])) == keccak256(bytes(name))) ++n;
        }
    }

    function skippedNamed(string memory name) external view returns (bool) {
        for (uint256 i; i < skippedTargets.length; ++i) {
            if (keccak256(bytes(skippedTargets[i])) == keccak256(bytes(name))) return true;
        }
        return false;
    }

    /// @dev T-OP-140. The production external set, exposed so the test can pin it against DeployV8's.
    function isExternalTarget(string memory name) external pure returns (bool) {
        return _isExternalTarget(name);
    }

    function failedNamed(string memory what) external view returns (bool) {
        for (uint256 i; i < failedChecks.length; ++i) {
            if (keccak256(bytes(failedChecks[i])) == keccak256(bytes(what))) return true;
        }
        return false;
    }

    function notCheckedNamed(string memory what) external view returns (bool) {
        for (uint256 i; i < notCheckedNames.length; ++i) {
            if (keccak256(bytes(notCheckedNames[i])) == keccak256(bytes(what))) return true;
        }
        return false;
    }

    function failedCount() external view returns (uint256) {
        return failedChecks.length;
    }

    /// @dev T-OP-171. Substring matchers: the per-ticker lines carry addresses, so an exact match would pin a test to
    ///      this run's addresses.
    function failedContaining(string memory fragment) external view returns (bool) {
        for (uint256 i; i < failedChecks.length; ++i) {
            if (vm.indexOf(failedChecks[i], fragment) != type(uint256).max) return true;
        }
        return false;
    }

    function notCheckedContaining(string memory fragment) external view returns (bool) {
        for (uint256 i; i < notCheckedNames.length; ++i) {
            if (vm.indexOf(notCheckedNames[i], fragment) != type(uint256).max) return true;
        }
        return false;
    }

    function notCheckedCount() external view returns (uint256) {
        return notCheckedNames.length;
    }
}

/// @dev T-OP-140. Exposes `DeployV8._externallySupplied` so the two scripts' six-name lists can be compared.
contract DeployV8ExternalNames is DeployV8 {
    function isExternal(string memory name) external pure returns (bool) {
        return _externallySupplied(name);
    }
}

/// @dev T-OP-152. Records the whole run's SHAPE without replacing any of it: every group header the script prints
///      and the one summary line, both delegated to the production report. The defect this observes is a run that
///      stops mid-walk -- under `forge script` the group-4 self-calls aborted the script, so nothing after group 3
///      printed and the summary never did, while the log up to that point looked healthy. A Solidity test cannot
///      read the console, so the two hooks record what the console was told.
contract VerifyV8RunRecorder is VerifyV8 {
    string[] public groups;
    bool public summarised;
    uint256 public summaryPassed;
    uint256 public summaryFailed;

    function _group(string memory name) internal override {
        groups.push(name);
        super._group(name);
    }

    function _summary(uint256 passed, uint256 failed) internal override {
        summarised = true;
        summaryPassed = passed;
        summaryFailed = failed;
        super._summary(passed, failed);
    }

    function groupCount() external view returns (uint256) {
        return groups.length;
    }

    function sawGroup(string memory name) external view returns (bool) {
        for (uint256 i; i < groups.length; ++i) {
            if (keccak256(bytes(groups[i])) == keccak256(bytes(name))) return true;
        }
        return false;
    }
}

/// @notice `script/v2/VerifyV8.s.sol` has teeth: clean on a set DeployV2 deployed and RegisterMarkets configured, and
///         exactly the expected failures for each kind of drift (bytecode, pointer, role, route, source list, tuned
///         parameter fresh vs live, a registered market the registry does not list, a paused market).
contract VerifyV8Test is DeployV2Fixture {
    V2DeployBase.Contracts internal d;

    /// @dev T-182. The access-group failure count of this fixture with a lender instance wired in and NOTHING
    ///      broken. It is an ABSOLUTE number rather than a measured delta for a hard reason: one `check()` over
    ///      this set costs ~5e8 gas, foundry's default `gas_limit` is 2^30, and TWO calls in one case exceed it --
    ///      the delta form of these cases died on `EvmError: Revert` at 1.0676e9 gas, twice. So each case makes
    ///      exactly ONE call and compares against this.
    ///
    ///      WHY IT IS NOT ZERO, which is the thing to read before trusting it: `DeployV2Fixture` deploys the
    ///      SIXTEEN-contract set only, so five of the twenty-one manifest targets have no address here and
    ///      `_authorities` FAILS them by name, as T-220 intended. That is a fixture gap, not a defect in the
    ///      verifier, and it is a separate row. If someone supplies those addresses this constant MOVES and these
    ///      cases go red -- which is the correct, loud outcome. Re-measure it, do not delete the assertion.
    ///      MEASURED, NOT ASSUMED: 8 at contracts v8 3d36fcb31f95383e4af55f12063bf5af164b0336, printed by
    ///      `test_verify_manifest_openLenderDistributorIsTheBaseline`. One call costs 684,140,231 gas, which is
    ///      why two do not fit.
    ///
    ///      IT WAS 4, AND THE MOVE FROM 4 TO 8 IS TWO SEPARATE THINGS -- read both before trusting this number.
    ///      SIX of them are T-258: `check()` now calls `_safes()`, which runs the six-check topology battery over
    ///      the Admin and the Treasury Safe. `DeployV2Fixture` gives both a `MockSafe`, which has code but is not
    ///      a Safe, so each contributes exactly three named FAILs -- singleton, the fail-closed
    ///      `safeMinThreshold`/`safeMinOwners` refusal, and `getModulesPaginated() answered` -- while its guard and
    ///      fallback-handler slots pass only because a fresh contract leaves both at zero. That is the right answer
    ///      for the wrong reason and it is the first thing to check if this number ever misbehaves.
    ///      THE OTHER MINUS TWO IS NOT T-258 AND IS NOT EXPLAINED HERE. Measured at the base this was re-derived
    ///      on, the pre-T-258 clean count was 2, not the 4 recorded above at 7ed7d352 -- so two manifest targets
    ///      that used to FAIL by name now resolve. That is the "this constant MOVES" case the paragraph above
    ///      predicts, it happened before this row touched the file, and whichever row supplied those addresses did
    ///      not re-measure. Do not read 8 as evidence that the fixture gap closed.
    ///      T-426 MOVED IT FROM 8 TO 2, AND THE NUMBER WAS MEASURED TWICE, NOT PREDICTED. Two edits in
    ///      `DeployV2Fixture.t.sol`, each measured on its own by running
    ///      `test_verify_manifest_openLenderDistributorIsTheBaseline`:
    ///        8 -> 4  `MockSafe` became a canonical 2-of-3 Safe double (singleton slot, three owners, empty module
    ///                page), so the singleton and `getModulesPaginated()` failures stopped for each of the two
    ///                Safes. THE PARAGRAPH ABOVE PREDICTED 6 AND THE MEASUREMENT SAID 4, which is the whole reason
    ///                it is measured: the third per-Safe failure is the next line.
    ///        4 -> 2  `_verifyInputs` now sets `safeMinThreshold`/`safeMinOwners`. They were 0, so
    ///                `_safeOwnership`'s fail-closed refusal fired once per Safe and the threshold and owner-count
    ///                assertions were never reached at all.
    ///      The remaining 2 are the unchanged fixture gap the paragraph above describes: manifest targets this
    ///      fixture has no address for. That is the same 2 this file records as the pre-T-258 clean count, which is
    ///      the positive control for the move -- the T-258 six were entirely artifacts of the old double.
    uint256 internal constant ACCESS_FAILURES_CLEAN = 2;

    function setUp() public override {
        super.setUp();
        d = _deploy();
        _registerUnderDelays();
    }

    /// @dev REGISTRATION AFTER HANDOVER IS A TWO-RUN OPERATION, AND THIS FIXTURE NOW PERFORMS IT AS ONE.
    ///      {_deploy} ends with `DeployV8` granting the real holders at `roles.v8.json` `.delaysS` and the deployer
    ///      renouncing, so from that line on `adminSafe` is a DELAYED member: LISTING at 1 h, CONFIG_ADMIN at 24 h.
    ///      The previous single `runWith` therefore sent `chainlinkSource.setFeed` raw, `Managed._checkCanCall`
    ///      asked the manager, got a delay, tried to consume a scheduled operation that did not exist, and setUp
    ///      died with "admin call reverted: chainlinkSource.setFeed(...)" -- a message that never mentions a delay.
    ///      T-217 made the script refuse that up front; this drives the path the script (and `DeployV2Batch.sh`)
    ///      actually prescribes instead.
    ///
    ///      THE WAIT IS A REAL WAIT. `vm.warp` is legitimate here and nowhere near a deployment: this is one EVM,
    ///      so moving its clock IS the operator coming back a day later. The delay is read from the manifest with
    ///      {V2DeployBase.roleDelayOf} rather than typed, so changing `.delaysS` moves this fixture with it.
    ///
    ///      THE FEEDS ARE REFRESHED ACROSS THE WAIT because a real Chainlink feed does not stop updating while an
    ///      AccessManager delay runs. `maxFeedAge` is 4 days so the execute run would pass either way, but leaving
    ///      a 25-hour-old round behind would quietly age every spot read in every test in this file.
    function _registerUnderDelays() internal {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        // The mode is INJECTED, not exported. `vm.setEnv` writes the environment of the whole `forge test`
        // process and forge runs cases concurrently, so driving `V2_SCHEDULE` that way would race every other
        // suite in the run. The harness overrides the two seams and changes nothing global.
        RegisterMarketsHarness scheduled = new RegisterMarketsHarness();

        scheduled.setMode(true, scheduled.phaseSchedule());
        scheduled.runWith(in_, _signer(adminSafe));

        string memory json = registerScript.rolesJson();
        uint32 wait = registerScript.roleDelayOf(json, "CONFIG_ADMIN");
        uint32 listing = registerScript.roleDelayOf(json, "LISTING");
        if (listing > wait) wait = listing;
        vm.warp(block.timestamp + wait + 1);
        nvdaFeed.push(NVDA_ANSWER, block.timestamp - 1 hours);
        tslaFeed.push(TSLA_ANSWER, block.timestamp - 1 hours);

        scheduled.setMode(true, scheduled.phaseExecute());
        scheduled.runWith(in_, _signer(adminSafe));
    }

    /// @dev T-426 SHIFTED EVERY ABSOLUTE `failed` COUNT IN THIS FILE BY -6, AND THE 6 WAS MEASURED, NOT PREDICTED.
    ///      `DeployV2Fixture`'s `MockSafe` used to be a contract with code and an `isSafe()` method, so
    ///      `VerifyV8._safes` produced three named failures for each of the two Safes on every single `check()`.
    ///      Those six were in the "clean" baseline of every case below. The double now models a canonical 2-of-3
    ///      Safe and `_verifyInputs` sets the two minimums, so the clean baseline is 0 and each expectation moved
    ///      down by the same six.
    ///
    ///      HOW IT WAS MEASURED, because a blanket arithmetic on a whole file is exactly the kind of edit that
    ///      hides a real regression: the suite was run at the attached base af52421d, then with this row's change,
    ///      and the two failure SETS were compared by name. Base: 29 passed, 8 failed. After: 29 passed, 8 failed,
    ///      the SAME eight cases with the same shapes.
    ///
    ///      THOSE EIGHT FAIL AT THE BASE TOO AND THIS ROW DID NOT TOUCH THEM. Four are off-by-one expectations
    ///      (`pinDryRun`, `poolFeeTierAboveOnePercent`, `premiumFeeAboveResaleFee`, `zeroMintFeePpmIsAFailureNotADrift`
    ///      each expect one more failure than the verifier produces), one is a delta case that catches two named
    ///      checks and asserts one (`money_bookFeeRecipientDiverted`), and three revert on gas
    ///      (`pointerRoleAndRouteDrift`, `poolObservationRingBelowTheMinimum`, `scheduledFeeChange` -- each makes
    ///      two `check()` calls in one case, which this file's own note at `ACCESS_FAILURES_CLEAN` says does not
    ///      fit). They are recorded in DEFERRED-VERIFICATION.md rather than fixed here: they are not this row's
    ///      three findings and two of them sit in the file T-SEC-06 holds.
    function test_verify_cleanOnTheDeployedSet() public {
        (uint256 passed, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 0, "no failure");
        assertGt(passed, 100, "more than a hundred checks");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 0, "no failure as a live set either");
    }

    /// @dev T-OP-152. The WHOLE path, `runWith` -> every group -> the summary line, on the in-test set. Before this
    ///      row nothing but `forge script` itself ran that path, and `forge script` was aborting it in group 4 on
    ///      the script's `this.<fn>()` self-calls -- a test that calls `check()` directly cannot see that, because
    ///      in a test the script is an ordinary contract and self-calls work. So this case asserts the two things
    ///      the drivers read: the summary was reached with the same counts `check()` reports, and every group that
    ///      `check()` sequences printed its header, groups 4 onward included. The self-call itself is proven absent
    ///      by inspection of the source and by the scratch `forge script` run in the ledger; a test cannot run the
    ///      script runner's guard.
    function test_verify_runWithReachesTheSummaryAndEveryGroup() public {
        VerifyV8RunRecorder recorder = new VerifyV8RunRecorder();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        (uint256 passed, uint256 failed) = recorder.check(in_);
        assertEq(failed, 0, "same clean baseline through the recording verifier");
        // A second, full run through the entry point the drivers use. `runWith` reverts on any failure, so
        // reaching the assertions below is itself the PASSED branch.
        recorder.runWith(in_);
        assertTrue(recorder.summarised(), "runWith reached the summary line");
        assertEq(recorder.summaryPassed(), passed, "the summary counts what check() counted");
        assertEq(recorder.summaryFailed(), 0, "the summary reports no failure");
        // Every group `check()` sequences unconditionally on a fresh set, in the words the log prints them.
        // "roles" is the group the self-calls used to abort in; "safes" and everything after it is what the
        // drivers never saw. ("registry rows not registered" prints only when V2_UNREGISTERED_ASSETS names
        // something, which this fixture does not.)
        string[15] memory expected = [
            "chain",
            "contracts have code",
            "bytecode (a pinned live address against its pinned deployed artifact, any other against out/)",
            "immutables",
            "compiled constants",
            "dependencies",
            "pointers",
            "flywheel (V8-DESIGN 6)",
            "maker vault (C2-11)",
            "parameters (fresh: launch values)",
            "calendar",
            "roles",
            "safes",
            "house vaults (markets[].v2.houseVault, one per ticker)",
            "fresh state"
        ];
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(recorder.sawGroup(expected[i]), string.concat("group header printed: ", expected[i]));
        }
        assertEq(in_.unregistered.length, 0, "the fixture names no unregistered asset, so that group is absent");
        for (uint256 i; i < in_.markets.length; ++i) {
            assertTrue(
                recorder.sawGroup(string.concat("market ", in_.markets[i].ticker)),
                string.concat("market group printed: ", in_.markets[i].ticker)
            );
        }
        // Two runs (check, then runWith) each print the full sequence once; a truncated second run would show as
        // fewer than twice the headers.
        assertEq(recorder.groupCount(), 2 * (expected.length + in_.markets.length), "both runs printed every group");
    }

    function test_verify_manifestWalkVisitsEveryTargetInFreshFrames() public {
        VerifyV8TargetCounter counter = new VerifyV8TargetCounter();
        (, uint256 failed) = counter.check(_verifyInputs(d, true));
        assertEq(failed, 0, "same clean baseline through the counting verifier");
        assertEq(
            counter.targetsVisited(),
            counter.targetNames(counter.rolesJson()).length,
            "the memory split still visits every roles.v8.json target"
        );
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
        AccessManager mgr = _mgr(d);
        _adminExecute(mgr, d.settlementOracle, abi.encodeCall(SettlementOracle.setKeeperRewards, (address(0)))); // pointers
        vm.prank(adminSafe);
        mgr.revokeRole(V8Roles.GUARDIAN, guardianKey); // OPS_ADMIN is an intentional zero-delay rotation lane
        // C8-03: the book is Managed, so there is no on-contract role table left to corrupt with a stray admin.
        // The injection that used to do it -- OrderBook.grantRole(DEFAULT_ADMIN_ROLE, crankerKey) -- no longer
        // compiles, and the managed-world drift probes belong to VerifyV8 (C8-10b). Expected failures drop from
        // four to the three that are still injectable.
        // T-CV-DEPLOY-VERIFY-SCRIPTS. This test used to cast the v8 {PayoutRouter} to the v7
        // {UniV3PayoutAdapter} and call `setRoute(address,uint24)` (selector 0x3d16c0f8). {PayoutRouter}
        // has `setRouteV3`/`setRouteV4`/`clearRoute` and no fallback, so the call reverted with an opaque
        // `EvmError: Revert` and the assertion below was NEVER REACHED. That is the hazard
        // {VerifyV8.s.sol:453} already names: a v7 cast compiles against any address and reverts here.
        //
        // The count of 3 is REAL but its old label was wrong, and the route was never part of it. Measured
        // from the verifier's own FAIL lines, the three are:
        //   settlementOracle.keeperRewards == keeperRewards                              <- the pointer above
        //   every roles.v8.json holder holds every role the manifest gives it            <- the GUARDIAN revoke
        //   every known principal holds exactly its roles.v8.json roles, over every role <- the SAME revoke
        // The revoke trips two separate role checks; the payout route contributes nothing.
        //
        // NO ROUTE DRIFT IS INJECTED HERE, deliberately. `clearRoute` cannot express one: {VerifyV8.s.sol:139}
        // accepts "the payout route == (pool, fee) ... or no route", so clearing NVDA's route moves it to an
        // ACCEPTED state, not a drifting one. Proved by breaking: with the `clearRoute` call removed entirely
        // this test still passed at failed == 3 and near-identical gas, which is what showed the injection was
        // inert. A genuine route drift needs a wrong-but-accepted route and is filed as its own finding rather
        // than invented here.
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 3, "oracle rewards pointer, and the GUARDIAN revoke tripping both role checks");
    }

    /// The pin wiring (INTERFACE_VERSION 6): a source that no longer lists the oracle, and one that lets the adminSafe pin.
    function test_verify_pinWiringDrift() public {
        AccessManager mgr = _mgr(d);
        _adminExecute(
            mgr, d.dataStreamsSource, abi.encodeCall(DataStreamsSource.setOracle, (d.settlementOracle, false))
        );
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "a source does not accept the oracle's pins");

        _adminExecute(mgr, d.dataStreamsSource, abi.encodeCall(DataStreamsSource.setOracle, (d.settlementOracle, true)));
        _adminExecute(mgr, d.chainlinkSource, abi.encodeCall(ChainlinkFeedSource.setOracle, (adminSafe, true)));
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 1, "the adminSafe may pin: a failure on a live set too");
    }

    /// The pin dry run (INTERFACE_VERSION 6) catches what would refuse the next series: the hidden pre-pin (the adminSafe
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
        AccessManager mgr = _mgr(d);
        _adminExecute(
            mgr, address(oracle), abi.encodeCall(SettlementOracle.setMarket, (address(nvda), one, 150, 21_600, 3600))
        );
        _adminExecute(mgr, address(oracle), abi.encodeCall(SettlementOracle.setClearinghouse, (shadow)));
        vm.prank(shadow);
        oracle.pin(address(nvda), next);
        _adminExecute(
            mgr, address(oracle), abi.encodeCall(SettlementOracle.setMarket, (address(nvda), both, 150, 21_600, 3600))
        );
        _adminExecute(mgr, address(oracle), abi.encodeCall(SettlementOracle.setClearinghouse, (d.clearinghouse)));
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "NVDA's next expiry is pinned to something else: its series would revert PinMismatch");

        _adminExecute(mgr, address(oracle), abi.encodeCall(SettlementOracle.setClearinghouse, (address(0))));
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 3, "the pointer, and both markets' dry runs");
    }

    /// A registry pool above the 1 % fee tier: the Clearinghouse counts at most MAX_ROUTE_FEE_BPS of a route's fee, so
    /// VerifyV8 names the tier on its own line (the route cannot match either: setRoute refuses such a tier).
    function test_verify_poolFeeTierAboveOnePercent() public {
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
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
        _adminExecute(
            _mgr(d),
            d.settlementOracle,
            abi.encodeCall(SettlementOracle.setMarket, (address(tsla), both, 150, 21_600, 3600))
        );
        vm.prank(guardianKey);
        Clearinghouse(d.clearinghouse).setMintPaused(address(nvda), true);

        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
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

    /// @notice C3-102 check 10: registry live vs chain disabled is a FAIL (DeployV2Batch dies on any FAIL).
    function test_verify_enabledMismatchFailsCheck10() public {
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        V2Types.MarketConfig memory cfg = ch.market(address(nvda));
        cfg.enabled = false;
        _adminReconfigure(ch, address(nvda), cfg);

        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "registry live, chain disabled");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 1, "same FAIL on a live set");
    }

    /// @notice A planned row registered disabled matches check 10 and does not FAIL.
    function test_verify_plannedDisabledRowPassesCheck10() public {
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        V2Types.MarketConfig memory cfg = ch.market(address(nvda));
        cfg.enabled = false;
        _adminReconfigure(ch, address(nvda), cfg);

        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.markets[0].enabled = false;
        (, uint256 failed) = verifyScript.check(in_);
        assertEq(failed, 0, "planned row correctly disabled");
        in_.expectFresh = false;
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 0, "same PASS on a live set");
    }

    function test_verify_tunedParameters() public {
        AccessManager mgr = _mgr(d);
        _adminExecute(mgr, d.keeperRewards, abi.encodeCall(KeeperRewards.setBounty, (V2Constants.ACTION_ROLL, 30_000)));
        _adminExecute(mgr, d.autoRoller, abi.encodeCall(AutoRoller.setMinRollUnits, (uint64(500))));
        MakerVault.Limits memory limits = MakerVault.Limits({
            maxSeriesUnits: 1,
            maxTotalNotional: 1,
            askToleranceBps: 0,
            maxBidBpsOfSpot: 0,
            maxOrderLifetime: 0,
            maxDailyOutflow: 0
        });
        _adminExecute(mgr, d.makerVault, abi.encodeCall(MakerVault.setLimits, (limits)));
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 3, "fresh: the three launch values");
        // T-OP-171 (T-OP-166 F2). A live set no longer silences a mismatch by itself: the three are FAILs until the
        // caller lists each SUBJECT in V2_EXPECT_CHANGED; listed, each is an info line; a fresh verify ignores the
        // list; a name that is not a subject reverts before any group runs.
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 3, "live, nothing listed: the three tuned values are still FAILs");
        VerifyV8.Inputs memory opted = _verifyInputs(d, false);
        opted.expectChanged = new string[](3);
        opted.expectChanged[0] = "keeperRewards.bounty.ROLL";
        opted.expectChanged[1] = "autoRoller.minRollUnits";
        opted.expectChanged[2] = "makerVault.limits";
        (, failed) = verifyScript.check(opted);
        assertEq(failed, 0, "live, all three listed: info lines");
        opted.expectChanged = new string[](1);
        opted.expectChanged[0] = "makerVault.limits";
        (, failed) = verifyScript.check(opted);
        assertEq(failed, 2, "live, one listed: the other two are still FAILs (per subject, never blanket)");
        opted.expectFresh = true;
        (, failed) = verifyScript.check(opted);
        assertEq(failed, 3, "fresh: the list is ignored, launch values are launch values");
        opted.expectFresh = false;
        opted.expectChanged[0] = "makerVault.limit"; // a misspelling
        vm.expectRevert();
        verifyScript.check(opted);
    }

    /// @dev T-OP-171. The subject list is validated fail-closed before any group runs, and the accepted names are
    ///      exactly the `_param` call sites: every {VerifyV8.paramSubjects} entry is accepted, a market rent subject is
    ///      accepted for a ticker of the run and refused for one that is not, and a duplicate is refused.
    function test_verify_expectChangedFailsClosed() public {
        string[] memory known = verifyScript.paramSubjects();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        in_.expectChanged = known;
        (, uint256 failed) = verifyScript.check(in_);
        assertEq(failed, 0, "every known subject is accepted, and the clean set stays clean");
        in_.expectChanged = new string[](1);
        in_.expectChanged[0] = "market.NVDA.mintFeePpm";
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 0, "a market rent subject for a ticker of the run is accepted");
        in_.expectChanged[0] = "market.ZZZZ.mintFeePpm";
        vm.expectRevert();
        verifyScript.check(in_);
        in_.expectChanged = new string[](2);
        in_.expectChanged[0] = "keeperRewards.dailyCap";
        in_.expectChanged[1] = "keeperRewards.dailyCap";
        vm.expectRevert();
        verifyScript.check(in_);
    }

    /// @dev Fee changes wait FEE_CHANGE_DELAY, so VerifyV8 compares the registry with the scheduled change while one is
    ///      pending and with the fees in effect otherwise.
    function test_verify_scheduledFeeChange() public {
        OrderBook book = OrderBook(d.orderBook);
        V2Types.FeeParams memory launch = book.feeParams();
        V2Types.FeeParams memory tuned = book.feeParams(); // a copy, not an alias of `launch`
        // Both move together: from INTERFACE_VERSION 7 `premiumFeeBps <= resaleFeeBps` is its own check, in effect
        // and scheduled, so a premium-only rise would fail on that as well and hide what this test is about.
        tuned.premiumFeeBps = launch.premiumFeeBps + 100;
        tuned.resaleFeeBps = launch.resaleFeeBps + 100;

        _adminExecute(_mgr(d), address(book), abi.encodeCall(OrderBook.setFeeParams, (tuned)));
        // The book's own pending window starts only after the AccessManager wait.
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 2, "fresh: the scheduled premium and resale fees are not the registry's");
        (, failed) = verifyScript.check(_verifyInputs(d, false));
        assertEq(failed, 2, "live, nothing listed: still FAILs (T-OP-171)");
        VerifyV8.Inputs memory opted = _verifyInputs(d, false);
        opted.expectChanged = new string[](2);
        opted.expectChanged[0] = "orderBook.premiumFeeBps";
        opted.expectChanged[1] = "orderBook.resaleFeeBps";
        (, failed) = verifyScript.check(opted);
        assertEq(failed, 0, "live, both listed: info lines");

        vm.warp(block.timestamp + V2Constants.FEE_CHANGE_DELAY); // now in effect, nothing pending
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 2, "fresh: the fees in effect are not the registry's");

        _adminExecute(_mgr(d), address(book), abi.encodeCall(OrderBook.setFeeParams, (launch)));
        (, failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 0, "a scheduled change back to the registry's fees passes, with its effectiveAt printed");
        assertEq(book.feeParams().premiumFeeBps, tuned.premiumFeeBps, "while the tuned fee is still in effect");
    }

    /*//////////////////////////////////////////////////////////////
                 T-OP-171: NOT CHECKED BY NAME, TWO HOUSE VAULTS
    //////////////////////////////////////////////////////////////*/

    /// @dev T-OP-166 F3. An empty market list and an empty unregistered list are NOT CHECKED by name and counted,
    ///      exactly as an unset deployer is; a supplied list is not.
    function test_verify_emptyMarketInputsAreNotCheckedByName() public {
        VerifyV8FailureNames names = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        in_.marketVaults = new address[](0);
        names.check(in_);
        assertTrue(names.notCheckedContaining("V2_TICKERS is unset or empty"), "no market: NOT CHECKED by name");
        assertTrue(
            names.notCheckedContaining("V2_UNREGISTERED_ASSETS is unset or empty"), "no unregistered list: NOT CHECKED"
        );
        assertEq(names.notCheckedCount(), 2, "counted for the verdict line: the two market-shaped inputs");

        VerifyV8FailureNames withMarkets = new VerifyV8FailureNames();
        VerifyV8.Inputs memory full = _verifyInputs(d, true);
        full.unregistered = new address[](1);
        full.unregistered[0] = address(usdg); // never a market
        withMarkets.check(full);
        assertFalse(withMarkets.notCheckedContaining("V2_TICKERS"), "markets supplied: not NOT CHECKED");
        assertFalse(withMarkets.notCheckedContaining("V2_UNREGISTERED_ASSETS"), "list supplied: not NOT CHECKED");
        // the two null per-ticker vault slots are the only NOT CHECKED lines left
        assertEq(withMarkets.notCheckedCount(), 2, "two tickers, both vault slots null");
        assertTrue(withMarkets.notCheckedContaining("market NVDA: markets[].v2.houseVault is null"), "NVDA slot");
        assertTrue(withMarkets.notCheckedContaining("market TSLA: markets[].v2.houseVault is null"), "TSLA slot");
    }

    /// @dev A second HouseVault double for the second ticker: mapped by the Safe through the ADMIN lane (the real
    ///      MapExternals shape, played here), gated on the manifest rows, answering TSLA's identity.
    function _secondVault(address underlying_) internal returns (address v) {
        MockExternalTarget m = new MockExternalTarget(MockExternalTarget.Kind.HouseVault);
        m.point(d.accessManager, address(0));
        m.setVaultIdentity(underlying_, d.clearinghouse, d.orderBook, d.feeSplitter);
        v = address(m);
        _gate(v, "HouseVault");
        AccessManager mgr = _mgr(d);
        string memory json = verifyScript.rolesJson();
        string[] memory sigs = verifyScript.targetSigs(json, "HouseVault");
        for (uint256 i; i < sigs.length; ++i) {
            bytes4[] memory one = new bytes4[](1);
            one[0] = verifyScript.selectorOf(sigs[i]);
            uint64 role = verifyScript.roleIdOf(json, verifyScript.roleNameOfSig(json, "HouseVault", sigs[i]));
            _adminExecute(mgr, d.accessManager, abi.encodeCall(AccessManager.setTargetFunctionRole, (v, one, role)));
        }
    }

    /// @dev The two-vault launch: NVDA's vault is the roles walk's single target AND market NVDA's slot; TSLA's is a
    ///      second instance. Both are walked with the ticker named; nothing is NOT CHECKED; the set is clean.
    function test_verify_twoHouseVaultsBothWalked() public {
        MockExternalTarget(houseVault).setVaultIdentity(address(nvda), d.clearinghouse, d.orderBook, d.feeSplitter);
        address second = _secondVault(address(tsla));
        VerifyV8FailureNames names = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.marketVaults[0] = houseVault;
        in_.marketVaults[1] = second;
        in_.unregistered = new address[](1);
        in_.unregistered[0] = address(usdg); // never a market: the list is present, so that group is not NOT CHECKED
        (, uint256 failed) = names.check(in_);
        assertEq(failed, 0, "both vaults verify clean");
        assertEq(names.notCheckedCount(), 0, "nothing NOT CHECKED: both slots supplied, deployer set, lists present");
    }

    /// @dev One null slot is NOT CHECKED naming its ticker; the other is still walked.
    function test_verify_oneNullVaultSlotIsNotCheckedByTicker() public {
        MockExternalTarget(houseVault).setVaultIdentity(address(nvda), d.clearinghouse, d.orderBook, d.feeSplitter);
        VerifyV8FailureNames names = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.marketVaults[0] = houseVault; // TSLA's slot stays null
        (, uint256 failed) = names.check(in_);
        assertEq(failed, 0, "NVDA's vault verifies; TSLA's absence is not a failure");
        assertTrue(names.notCheckedContaining("market TSLA: markets[].v2.houseVault is null"), "TSLA NOT CHECKED");
        assertFalse(names.notCheckedContaining("market NVDA:"), "NVDA was walked");
    }

    /// @dev A WRONG second vault -- TSLA's slot pointing at a vault whose underlying is NVDA -- is a FAIL naming the
    ///      ticker; so is a second vault that is the first ticker's (one vault per ticker), an unmapped one, and one
    ///      that refuses nobody (T-OP-166 F1 applies to the per-ticker walk too).
    function test_verify_wrongSecondVaultFailsNamingTheTicker() public {
        MockExternalTarget(houseVault).setVaultIdentity(address(nvda), d.clearinghouse, d.orderBook, d.feeSplitter);
        // (a) wrong underlying
        address wrongAsset = _secondVault(address(nvda));
        VerifyV8FailureNames names = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.marketVaults[0] = houseVault;
        in_.marketVaults[1] = wrongAsset;
        (, uint256 failed) = names.check(in_);
        assertEq(failed, 1, "exactly the identity line");
        assertTrue(names.failedContaining("market TSLA: house vault underlying() == the ticker's asset"), "by ticker");

        // (b) the same vault for both tickers
        VerifyV8FailureNames dup = new VerifyV8FailureNames();
        VerifyV8.Inputs memory both = _verifyInputs(d, true);
        both.marketVaults[0] = houseVault;
        both.marketVaults[1] = houseVault;
        dup.check(both);
        assertTrue(dup.failedContaining("market TSLA: house vault is not another ticker's vault"), "duplicate named");
        assertTrue(
            dup.failedContaining("market TSLA: house vault underlying() == the ticker's asset"), "and wrong asset"
        );

        // (c) an unmapped second vault: identity right, selectors never mapped on its address
        MockExternalTarget bare = new MockExternalTarget(MockExternalTarget.Kind.HouseVault);
        bare.point(d.accessManager, address(0));
        bare.setVaultIdentity(address(tsla), d.clearinghouse, d.orderBook, d.feeSplitter);
        _gate(address(bare), "HouseVault");
        VerifyV8FailureNames unmapped = new VerifyV8FailureNames();
        VerifyV8.Inputs memory um = _verifyInputs(d, true);
        um.marketVaults[0] = houseVault;
        um.marketVaults[1] = address(bare);
        unmapped.check(um);
        assertTrue(
            unmapped.failedContaining("market TSLA: house vault every HouseVault selector is mapped"), "unmapped named"
        );

        // (d) a second vault that refuses nobody: F1's rule, on the per-ticker walk, by ticker
        MockExternalTarget lax = new MockExternalTarget(MockExternalTarget.Kind.HouseVault);
        lax.point(d.accessManager, address(0));
        lax.setVaultIdentity(address(tsla), d.clearinghouse, d.orderBook, d.feeSplitter);
        VerifyV8FailureNames soft = new VerifyV8FailureNames();
        VerifyV8.Inputs memory sx = _verifyInputs(d, true);
        sx.marketVaults[0] = houseVault;
        sx.marketVaults[1] = address(lax);
        soft.check(sx);
        assertTrue(
            soft.failedContaining(
                "market TSLA: house vault no selector outside roles.v8.json is mapped to a role or refuses a stranger"
            ),
            "refuses nobody: the per-ticker stranger probe fails by ticker"
        );
    }

    /// @dev Option A: market NVDA's slot must be v2.contracts.houseVault; a first-ticker slot pointing elsewhere FAILs.
    function test_verify_firstTickerVaultMustBeTheRolesWalkTarget() public {
        MockExternalTarget(houseVault).setVaultIdentity(address(nvda), d.clearinghouse, d.orderBook, d.feeSplitter);
        address other = _secondVault(address(nvda)); // a correct-looking NVDA vault that is NOT v2.contracts.houseVault
        VerifyV8FailureNames names = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.marketVaults[0] = other;
        (, uint256 failed) = names.check(in_);
        assertEq(failed, 1, "exactly the option-A line");
        assertTrue(
            names.failedContaining("market NVDA: house vault is v2.contracts.houseVault (V2_HOUSE_VAULT)"), "named"
        );
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
        _adminExecute(_mgr(d), address(book), abi.encodeCall(OrderBook.setFeeParams, (tuned)));
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
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.mintFeePpm[0] = 125; // the chain holds NVDA's 80
        (, uint256 failed) = verifyScript.check(in_);
        assertEq(failed, 1, "fresh: NVDA's rent rate is not the registry's");
        in_.expectFresh = false;
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 1, "live, not listed: still a FAIL (T-OP-171)");
        in_.expectChanged = new string[](1);
        in_.expectChanged[0] = "market.NVDA.mintFeePpm";
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 0, "live, listed by ticker: an adminSafe may raise it for new series");

        // above the compiled ceiling it FAILs either way -- but the Clearinghouse itself refuses such a config, so
        // the only way to see it is to write the slot.
        V2Types.MarketConfig memory cfg = Clearinghouse(d.clearinghouse).market(address(nvda));
        assertLe(cfg.mintFeePpm, V2Constants.MINT_FEE_CEIL_PPM, "the deploy could not have exceeded the ceiling");
    }

    /// @dev REPAIRED BY T-593. THIS TEST ASSERTED THE v7 RULE AND SURVIVED THE v8 INVERSION.
    ///      Its previous body required a rent rate of 0 to FAIL - the v7 release blocker of
    ///      DECISIONS-2026-09-17 §11, where rent was the only writer fee. INTERFACE_VERSION 8 inverted that:
    ///      `v8-plan/V8-DESIGN.md:124` says writer rent "launches at 0 on every market" and that "in v8 that
    ///      guard is inverted: the deploy refuses a NON-ZERO rent unless explicitly allowed", and the guard at
    ///      `script/v2/VerifyV8.s.sol:2189` is `cfg.mintFeePpm == 0 || rentAllowed(in_.allowRent)`. So 0 is the
    ///      EXPECTED value and a rate is the failure - the exact opposite of what this test used to require.
    ///      THE NAME IS LEFT ALONE DELIBERATELY: T-593 forbids renaming, so the history stays traceable. It
    ///      still reads as the v7 claim and deserves its own cleanup row.
    ///
    ///      IT IS A ROUND TRIP, AND THAT IS NOT DECORATION. A first draft simply set the rate to 0 and required
    ///      the count not to move. That draft PASSED WITH THE GUARD INVERTED, because the fixture already
    ///      launches TSLA at 0 - setting it to 0 is a no-op, so the count was unchanged either way and the test
    ///      could not see its own subject. Going up to a rate and back down is what makes it sensitive.
    ///
    ///      NO SUBTRACTION. `_failures` returns a count and the inverted guard RAISES the baseline, so
    ///      `after - baseline` underflows and the failure surfaces as `panic 0x11` instead of naming the rule.
    ///      Comparing the two counts directly keeps the message readable when it goes red.
    function test_verify_zeroMintFeePpmIsAFailureNotADrift() public {
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        uint256 atZero = _failures(d);

        V2Types.MarketConfig memory cfg = ch.market(address(tsla));
        cfg.mintFeePpm = 300;
        _adminReconfigure(ch, address(tsla), cfg);
        uint256 atRate = _failures(d);
        assertEq(atRate, atZero + 1, "v8 rent rule: a NON-ZERO rate must add exactly one failure (VerifyV8.s.sol:2189)");

        cfg.mintFeePpm = 0;
        _adminReconfigure(ch, address(tsla), cfg);
        assertEq(_failures(d), atZero, "v8 rent rule: 0 is the launch value and clears the refusal");
    }

    /// @notice The rent rule's opt-in: a non-zero rate is refused, and only `allowRent` clears it.
    /// @dev T-593. The rule had no test at all, and the one test that named it asserted the v7 rule - an
    ///      inverted test is worse than a missing one, because a red test whose name claims the rule reads as
    ///      already-owned. This covers the third direction the repaired test above does not: the opt-in.
    ///
    ///      DERIVED FROM SOURCE, NOT FROM A RUN, as T-593 requires. `v8-plan/V8-DESIGN.md:124` and the guard
    ///      `cfg.mintFeePpm == 0 || rentAllowed(in_.allowRent)` at `script/v2/VerifyV8.s.sol:2189`. That is ONE
    ///      `_check`, and `_failures` reads the LIVE arm where the drift line at :2198 is an `_param` info line,
    ///      so the rule is the only check on this field that can move the count.
    function test_verify_rentRule_onlyTheOptInClearsANonZeroRate() public {
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        uint256 atZero = _failures(d);

        V2Types.MarketConfig memory cfg = ch.market(address(tsla));
        cfg.mintFeePpm = 300;
        _adminReconfigure(ch, address(tsla), cfg);
        assertEq(_failures(d), atZero + 1, "a non-zero rent rate is refused without the opt-in");

        VerifyV8.Inputs memory opted = _verifyInputs(d, false);
        opted.allowRent = true;
        opted.expectChanged = new string[](1);
        opted.expectChanged[0] = "market.TSLA.mintFeePpm"; // as {_failures} does: the drift line is not the subject
        (, uint256 withOptIn) = verifyScript.check(opted);
        assertEq(withOptIn, atZero, "allowRent clears the rent refusal and nothing else");
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
        _adminExecute(_mgr(d), address(vault), abi.encodeCall(MakerVault.setLimits, (l)));
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "fresh: the vault limits are not the launch tuple");
        VerifyV8.Inputs memory opted = _verifyInputs(d, false);
        opted.expectChanged = new string[](1);
        opted.expectChanged[0] = "makerVault.limits";
        (, failed) = verifyScript.check(opted);
        assertEq(failed, 0, "live, listed: an adminSafe-tuned cap is an info line");
    }

    /// @dev c16: CANCEL_STALE is the sixth bounty and is compared like the other five.
    function test_verify_cancelStaleBounty() public {
        KeeperRewards kr = KeeperRewards(d.keeperRewards);
        assertEq(kr.bounty(V2Constants.ACTION_CANCEL_STALE), 20_000, "the deploy set it");
        _adminExecute(
            _mgr(d), address(kr), abi.encodeCall(KeeperRewards.setBounty, (V2Constants.ACTION_CANCEL_STALE, 35_000))
        );
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 1, "fresh: the CANCEL_STALE bounty is not the launch value");
        VerifyV8.Inputs memory opted = _verifyInputs(d, false);
        opted.expectChanged = new string[](1);
        opted.expectChanged[0] = "keeperRewards.bounty.CANCEL_STALE";
        (, failed) = verifyScript.check(opted);
        assertEq(failed, 0, "live, listed: an info line");

        // The ceiling half of the check cannot be reached through the contract: KeeperRewards.setBounty refuses
        // anything above MAX_BOUNTY itself, which is why the verifier's `underMax` line can only ever fail on a set
        // deployed from other bytecode.
        bytes memory overCeiling =
            abi.encodeCall(KeeperRewards.setBounty, (V2Constants.ACTION_CANCEL_STALE, V2Constants.MAX_BOUNTY + 1));
        _adminSchedule(_mgr(d), address(kr), overCeiling);
        vm.prank(adminSafe);
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
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.markets = new V2DeployBase.MarketIn[](1);
        in_.markets[0] = _tslaMarket();
        in_.mintFeePpm = new uint32[](1);
        in_.mintFeePpm[0] = 300;
        in_.unregistered = new address[](0);
        (, failed) = verifyScript.check(in_);
        assertEq(failed, 0, "a Chainlink-only market has no ring to check");
    }

    /*//////////////////////////////////////////////////////////////
                  ACCESS: ONE BREAK PER CHECK GROUP (C8-10B)
    //////////////////////////////////////////////////////////////*/

    /// @dev The manager of the deployed set.
    function _mgr(V2DeployBase.Contracts memory set) internal view returns (AccessManager) {
        return AccessManager(Clearinghouse(set.clearinghouse).authority());
    }

    /// @dev Failures on the CURRENT chain state, so a test can measure its own break as a DELTA rather than trusting
    ///      an absolute count. Every break below that needs a delayed lane has to warp, and a warp can age a mock feed
    ///      or cross a fee window and add failures that are nothing to do with the check under test.
    function _failures(V2DeployBase.Contracts memory set) internal returns (uint256 failed) {
        // T-OP-171: a live-set mismatch is a FAIL unless its subject is listed; the rent tests move TSLA's rate on
        // purpose, so the drift subject is opted out here and the v8 rent RULE stays the only check that can move
        // this count (the two tests above say so in their NatSpec).
        VerifyV8.Inputs memory in_ = _verifyInputs(set, false);
        in_.expectChanged = new string[](1);
        in_.expectChanged[0] = "market.TSLA.mintFeePpm";
        (, failed) = verifyScript.check(in_);
    }

    /// @dev {_failures} with NO markets, for the access groups only. T-182.
    ///
    ///      THIS EXISTS FOR A MEASURED REASON, not a stylistic one. One full `check()` over this set costs ~1.07e9
    ///      gas, and the T-182 cases below add a twenty-first resolvable manifest target (a real second
    ///      `RewardsDistributor`), whose compiled ABI `_noUnlistedRestricted` then walks as well. Two full calls in
    ///      one case died on `[MemoryOOG] EvmError: MemoryOOG` inside the second -- memory accumulates across both
    ///      calls in a single test frame, so splitting the case in two did not help either. Measured twice.
    ///
    ///      DROPPING THE MARKETS IS SOUND FOR WHAT THESE CASES ASSERT, and only for that: check group 3 reads the
    ///      manager, `roles.v8.json` and target state. It does not look at a market. `_market()` is what the
    ///      per-market loop costs, and it is pure overhead for a break in the access groups. Any case that asserts
    ///      something about a MARKET must keep using {_failures}.
    /*//////////////////////////////////////////////////////////////
        T-436 P1-b: EXACTLY ITS ROLES, OVER EVERY ROLE ID
    //////////////////////////////////////////////////////////////*/

    /// @notice A surplus membership in an INSTANT lane is named, and the old sweep cannot see it.
    /// @dev QUOTER is role id 9. The pre-existing sweep walks ids 0..`DELAYED_ROLE_MAX` (6) over five addresses, so
    ///      a bot key handed QUOTER -- 29 mapped selectors, delay 0, no window in which to react -- was invisible to
    ///      every check in this file. BOTH assertions matter: the new sweep names it, and the old one still does
    ///      not, which is what makes this a test of the new code rather than of a rename.
    function test_verify_surplusInstantRoleOnABotKeyIsNamed() public {
        AccessManager mgr = _mgr(d);
        // NO SCHEDULE HERE, and the reason is the finding's other half: QUOTER's role admin is OPS_ADMIN
        // (roles.v8.json `.roleAdmin`), which the Admin Safe holds at delay 0. Handing a bot key 29 mapped
        // selectors is therefore an INSTANT operation with no window in which anyone could react to it -- unlike
        // the delayed lanes the pre-existing sweep is restricted to.
        vm.prank(adminSafe);
        mgr.grantRole(V8Roles.QUOTER, pricerKey, 0);
        (bool member,) = mgr.hasRole(V8Roles.QUOTER, pricerKey);
        assertTrue(member, "the break landed: the pricer key holds QUOTER");

        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertTrue(
            probe.failedNamed("every known principal holds exactly its roles.v8.json roles, over every role id"),
            "the surplus instant-lane membership is named"
        );
        assertFalse(
            probe.failedNamed("no bot key and not the deployer holds any role in 0..6"),
            "and the pre-existing sweep is blind to it, which is the finding"
        );
    }

    /// @notice A surplus membership on the TREASURY Safe is named. Nothing asked about that address before.
    /// @dev `treasurySafe` appeared in this file only inside the distinct-address array. It is the only address
    ///      KeeperRewards, MakerVault, RewardsDistributor and FeeSplitter can ever pay, and the manifest gives it
    ///      no role at all, so any membership it holds is surplus by definition.
    function test_verify_surplusRoleOnTheTreasurySafeIsNamed() public {
        AccessManager mgr = _mgr(d);
        bytes memory data = abi.encodeCall(IAccessManager.grantRole, (V8Roles.LISTING, treasurySafe, 0));
        _adminSchedule(mgr, address(mgr), data);
        vm.prank(adminSafe);
        mgr.grantRole(V8Roles.LISTING, treasurySafe, 0);

        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertTrue(
            probe.failedNamed("every known principal holds exactly its roles.v8.json roles, over every role id"),
            "a role on the treasury Safe is named"
        );
    }

    /*//////////////////////////////////////////////////////////////
        SEC-38: THE DEPLOYER AND THE INSTANT LANES
    //////////////////////////////////////////////////////////////*/

    string internal constant DEPLOYER_UNSET =
        "V2_DEPLOYER is unset, so no check in this group asserts that the deployer shed its roles";

    /// @notice SEC-38, pinned rather than fixed: a deployer that kept an instant lane is named by the standalone gate.
    /// @dev SEC-38 said the deployer sweep in {VerifyV8._principals} stops at `DELAYED_ROLE_MAX` (6), so a deployer
    ///      that kept GUARDIAN, PRICER, QUOTER or BUYBACK (7..10) printed VERIFY PASSED. True when filed; T-436's
    ///      {VerifyV8._noSurplusMemberships} closed it before this row reached the code, because the deployer is in
    ///      that sweep with no manifest roles. This adds no guard. It pins that one for the address SEC-38 was
    ///      about: T-436's own cases break a bot key and the treasury Safe, so dropping the deployer from that
    ///      sweep would pass every other case in this file.
    ///
    ///      NO SCHEDULE: PRICER's role admin is OPS_ADMIN, which the Admin Safe holds at delay 0. BOTH assertions
    ///      matter: the wide sweep names it, and the 0..6 sweep still cannot see it, which is what SEC-38 was.
    function test_verify_surplusInstantRoleOnTheDeployerIsNamed() public {
        AccessManager mgr = _mgr(d);
        vm.prank(adminSafe);
        mgr.grantRole(V8Roles.PRICER, deployer, 0);
        (bool member,) = mgr.hasRole(V8Roles.PRICER, deployer);
        assertTrue(member, "the break landed: the deployer holds PRICER, an instant lane");

        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        assertEq(in_.deployer, deployer, "the verify inputs name the deployer this case broke");
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertTrue(
            probe.failedNamed("every known principal holds exactly its roles.v8.json roles, over every role id"),
            "the deployer's instant-lane membership is named"
        );
        assertFalse(
            probe.failedNamed("no bot key and not the deployer holds any role in 0..6"),
            "and the 0..6 sweep is blind to it, which is what SEC-38 described"
        );
    }

    /// @notice SEC-38-R: with V2_DEPLOYER unset the hand-over is reported NOT CHECKED, not silently passed.
    /// @dev `inputsFromEnv` defaults the deployer to zero and all three deployer assertions skip a zero address,
    ///      so this is the only line in the run that says the deployer was never looked at. It is not a FAIL on
    ///      purpose: `DeployV2Batch.sh --verify` passes no deployer, and a FAIL would break that path.
    ///
    ///      THE BREAK IS A REAL RETENTION the run cannot see: the deployer keeps PRICER, the same state the case
    ///      above shows is named when the deployer is supplied. Here it is not named, and the NOT CHECKED line is
    ///      the only thing that says so. One `check()` per case: two in one frame have died on MemoryOOG here.
    function test_verify_unsetDeployerIsReportedNotChecked() public {
        AccessManager mgr = _mgr(d);
        vm.prank(adminSafe);
        mgr.grantRole(V8Roles.PRICER, deployer, 0);

        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        in_.deployer = address(0);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertTrue(probe.notCheckedNamed(DEPLOYER_UNSET), "an unset deployer is reported, not skipped silently");
        assertFalse(
            probe.failedNamed("every known principal holds exactly its roles.v8.json roles, over every role id"),
            "and the retention really is invisible without it, which is why the report has to exist"
        );
    }

    /// @notice The NOT CHECKED line is about an ABSENT deployer, not a constant: a run that names one never prints it.
    /// @dev The negative half of the case above, so that case cannot pass for a report that fires on every run.
    function test_verify_suppliedDeployerIsNotReportedNotChecked() public {
        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        assertTrue(in_.deployer != address(0), "the fixture supplies a deployer");
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertFalse(probe.notCheckedNamed(DEPLOYER_UNSET), "a supplied deployer is checked, so nothing is reported");
    }

    /*//////////////////////////////////////////////////////////////
                T-OP-140: V2_SKIP_EXTERNALS -- A NOT CHECKED TARGET GROUP
    //////////////////////////////////////////////////////////////*/

    string internal constant TARGETS_PRESENT = "every roles.v8.json target resolves to an address this run was given";
    string internal constant SELECTORS_MAPPED = "every roles.v8.json selector is mapped to its manifest role on chain";

    /// @dev The verifier's inputs with ONE external undeployed (address(0)), as the driver leaves it after
    ///      `--skip-external hedger`, and the manifest name the driver exports in V2_SKIP_EXTERNALS for it.
    function _inputsWithoutHedger(bool skip) internal view returns (VerifyV8.Inputs memory in_) {
        in_ = _verifyInputs(d, false);
        in_.c.hedger = address(0);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        if (skip) {
            in_.skipExternals = new string[](1);
            in_.skipExternals[0] = "Hedger";
        }
    }

    /// @notice (a) A skip of an UNDEPLOYED external is a PASS with that target NOT CHECKED, by name, in every group
    ///         that would have read it -- never a bare pass and never a "has no address" FAIL.
    /// @dev THE FORBIDDEN SHAPE THIS PINS: a skip that marks the target `present` and records nothing would make
    ///      `run()` print a bare `VERIFY PASSED` for a set with a hole in it. `skippedCount() == 1` is what turns
    ///      that into a red: prove-by-breaking = make `_authorities` treat a skipped target as present and drop
    ///      the `_skippedTarget` call; this case then fails on the count while `failed` stays 0.
    function test_verify_skipUndeployedExternal_passesWithTheTargetNotChecked() public {
        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        (, uint256 failed) = probe.check(_inputsWithoutHedger(true));
        assertEq(failed, 0, "a declared skip is not a failure");
        assertEq(
            probe.skippedCount(), 1, "exactly one target is NOT CHECKED, so the verdict line cannot be a bare PASS"
        );
        assertTrue(probe.skippedNamed("Hedger"), "and it is the one the caller named");
        // Every group that reads the Hedger declined by name: authorities, manifest selectors, the unlisted-selector
        // probe and the money-lane treasury walk. Fewer than four means one of them read address(0) instead.
        assertEq(probe.skippedTimes("Hedger"), 4, "authorities + manifest + unlisted probe + money lane");
        assertFalse(probe.failedNamed(TARGETS_PRESENT), "the skip is not reported as a missing address");
        assertFalse(probe.failedNamed(SELECTORS_MAPPED), "and its selectors are not reported unmapped");
    }

    /// @notice (a, launch shape) The owner's 05:45Z ruling (M-2a83cfc9443c4150): Hedger, RewardsDistributorLender and
    ///         StockVenueAdapter are OUT for launch, all three via V2_SKIP_EXTERNALS, with EarnVault and the House
    ///         contracts deployed. That exact triple is a PASS with three targets NOT CHECKED, and the EarnVault
    ///         beside the skipped adapter is still fully checked.
    function test_verify_launchTriple_hedgerLenderVenueSkipped_passesWithThreeNotChecked() public {
        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        in_.c.hedger = address(0);
        in_.c.rewardsDistributorLender = address(0);
        in_.c.stockVenueAdapter = address(0);
        in_.skipExternals = new string[](3);
        in_.skipExternals[0] = "Hedger";
        in_.skipExternals[1] = "RewardsDistributorLender";
        in_.skipExternals[2] = "StockVenueAdapter";
        (, uint256 failed) = probe.check(in_);
        assertEq(failed, 0, "the launch triple is a declared skip, not a failure");
        assertEq(probe.skippedCount(), 3, "three targets NOT CHECKED on the verdict line");
        assertTrue(
            probe.skippedNamed("Hedger") && probe.skippedNamed("RewardsDistributorLender")
                && probe.skippedNamed("StockVenueAdapter")
        );
        // The money lane declines both of its skippable subjects and still walks the other four.
        assertEq(probe.skippedTimes("Hedger"), 4);
        assertEq(probe.skippedTimes("RewardsDistributorLender"), 4);
        // The venue adapter is not a money-lane subject: authorities, manifest, unlisted probe only.
        assertEq(probe.skippedTimes("StockVenueAdapter"), 3);
        assertFalse(probe.failedNamed(TARGETS_PRESENT));
        assertFalse(probe.failedNamed(SELECTORS_MAPPED));
        assertFalse(probe.skippedNamed("EarnVault"), "EarnVault was supplied and is checked, not skipped");
    }

    /// @notice (b) A skip of a SUPPLIED external reverts naming the target and its variable: a skip of something
    ///         the run was given is exactly the look-away a verifier must refuse.
    function test_verify_skipSuppliedExternal_reverts() public {
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        assertTrue(in_.c.hedger != address(0), "the fixture supplies a Hedger");
        in_.skipExternals = new string[](1);
        in_.skipExternals[0] = "Hedger";
        vm.expectRevert(
            bytes(
                string.concat(
                    "V2_SKIP_EXTERNALS names Hedger but V2_HEDGER is supplied (",
                    vm.toString(in_.c.hedger),
                    "): a supplied target is verified, never skipped; unset the variable or drop the skip"
                )
            )
        );
        verifyScript.check(in_);
    }

    /// @notice (c) An unknown name reverts: a core target, a misspelling and the REGISTRY-KEY spelling the driver
    ///         takes on its command line are all refused, so nothing but the manifest name of an external is a skip.
    function test_verify_skipUnknownName_reverts() public {
        string[3] memory bad = ["Clearinghouse", "Hedgr", "hedger"];
        for (uint256 i; i < bad.length; ++i) {
            VerifyV8.Inputs memory in_ = _inputsWithoutHedger(false);
            in_.skipExternals = new string[](1);
            in_.skipExternals[0] = bad[i];
            vm.expectRevert(
                bytes(
                    string.concat(
                        "V2_SKIP_EXTERNALS names '",
                        bad[i],
                        "', which is not an externally supplied target (HouseVault, HouseVaultFactory, Hedger, RewardsDistributorLender, EarnVault, StockVenueAdapter): a core target cannot be skipped, and the spelling is the manifest name"
                    )
                )
            );
            verifyScript.check(in_);
        }
        // Named twice is refused too: the count on the verdict line must mean what it says.
        VerifyV8.Inputs memory twice = _inputsWithoutHedger(false);
        twice.skipExternals = new string[](2);
        twice.skipExternals[0] = "Hedger";
        twice.skipExternals[1] = "Hedger";
        vm.expectRevert(bytes("V2_SKIP_EXTERNALS names Hedger twice"));
        verifyScript.check(twice);
    }

    /// @notice (d) Without a skip list an undeployed external is what it was before this row: two named FAILs
    ///         ("has no address" in the authorities walk, "not mapped" in the manifest walk) and nothing NOT CHECKED.
    function test_verify_noSkipList_undeployedExternalStillFailsByName() public {
        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        (, uint256 failed) = probe.check(_inputsWithoutHedger(false));
        assertGt(failed, 0, "an undeclared hole is a failure");
        assertTrue(probe.failedNamed(TARGETS_PRESENT), "the authorities walk names the missing address");
        assertTrue(probe.failedNamed(SELECTORS_MAPPED), "the manifest walk names the unmapped selectors");
        assertEq(probe.skippedCount(), 0, "nothing was declared, so nothing is NOT CHECKED");
    }

    /// @notice The six names VerifyV8 will accept as skippable are exactly the six DeployV8 says it does not deploy,
    ///         over the whole manifest: a seventh on either side, or a renamed target, is a red here.
    function test_verify_skippableSetMirrorsDeployV8sExternallySupplied() public {
        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        DeployV8ExternalNames deploy = new DeployV8ExternalNames();
        string[] memory names = verifyScript.targetNames(verifyScript.rolesJson());
        uint256 externals;
        for (uint256 i; i < names.length; ++i) {
            bool v = probe.isExternalTarget(names[i]);
            assertEq(v, deploy.isExternal(names[i]), string.concat("VerifyV8 and DeployV8 disagree about ", names[i]));
            if (v) ++externals;
        }
        assertEq(externals, 6, "six externals in the manifest");
        assertFalse(probe.isExternalTarget("hedger"), "the registry-key spelling is not a manifest name");
    }

    /// @notice A pending reduction of a holder's execution delay is named by the verifier.
    /// @dev T-436 P1-a on the verify side. `hasRole` reports the CURRENT delay, so until the effect time this reads
    ///      as a correct manifest delay. A verifier that certifies a state already scheduled to change has not
    ///      checked it.
    function test_verify_pendingHolderDelayReductionIsNamed() public {
        AccessManager mgr = _mgr(d);
        bytes memory data = abi.encodeCall(IAccessManager.grantRole, (V8Roles.LISTING, adminSafe, 0));
        _adminSchedule(mgr, address(mgr), data);
        vm.prank(adminSafe);
        mgr.grantRole(V8Roles.LISTING, adminSafe, 0);
        (, uint32 current) = mgr.hasRole(V8Roles.LISTING, adminSafe);
        assertEq(current, V8Roles.LISTING_DELAY, "hasRole still reports the manifest delay");

        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertTrue(
            probe.failedNamed("every holder's execution delay is the manifest delay for that role"),
            "the pending reduction is named"
        );
    }

    /*//////////////////////////////////////////////////////////////
       T-426 F-05-03: EXEMPT BY NAME, AND A TARGET IS WHAT IT CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice One address under two manifest names is named, and the aliased target stops exempting itself.
    /// @dev THE EXACT SHAPE THE FINDING NAMES: `V2_HOUSE_VAULT = V2_BUYBACK_EXECUTOR`. Before this row,
    ///      `_authorities` and `_targetsOpen` both skipped `target == c.buybackExecutor`, so setting the HouseVault
    ///      to the executor's address made the HOUSE VAULT skip those walks -- a check that passes because it can
    ///      no longer see its subject. Two things are asserted, and the second is the one that matters: the alias
    ///      is NAMED, and the HouseVault is no longer exempt from the authority walk it was aliased out of.
    function test_verify_aliasedTargetIsNamedAndNoLongerExemptsItself() public {
        V2DeployBase.Contracts memory set = d;
        set.houseVault = set.buybackExecutor;
        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(set, false);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertTrue(
            probe.failedNamed("no two roles.v8.json targets are the same address"), "the alias is named by the verifier"
        );
        assertTrue(
            probe.failedNamed("every roles.v8.json target is Managed (C8-03 converts the orderBook last)"),
            "the aliased HouseVault is walked instead of exempting itself: the executor is not Managed"
        );
    }

    /// @notice A supplied target that does not answer its name's interface is a named failure.
    /// @dev The double is a correctly-built stand-in for a DIFFERENT one of the six, so it has code, answers
    ///      `authority()` and satisfies every property the verifier asked about before this row. Only the
    ///      interface says the manifest name and the contract disagree.
    function test_verify_suppliedTargetThatIsADifferentContractIsNamed() public {
        V2DeployBase.Contracts memory set = d;
        MockExternalTarget wrong = new MockExternalTarget(MockExternalTarget.Kind.Hedger);
        wrong.point(set.accessManager, address(0));
        set.earnVault = address(wrong);
        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(set, false);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertTrue(
            probe.failedNamed("EarnVault answers queue(): it is the contract its name claims"),
            "the wrong contract under a manifest name is named"
        );
    }

    /// @notice The clean set names neither, so the two cases above are not asserting on a guard that always fails.
    function test_verify_cleanSetNamesNeitherTheAliasNorTheIdentity() public {
        VerifyV8FailureNames probe = new VerifyV8FailureNames();
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        probe.check(in_);
        assertFalse(probe.failedNamed("no two roles.v8.json targets are the same address"), "no alias on a clean set");
        assertFalse(
            probe.failedNamed("EarnVault answers queue(): it is the contract its name claims"),
            "the EarnVault double answers its own interface"
        );
    }

    function _accessFailures(V2DeployBase.Contracts memory set) internal returns (uint256 failed) {
        VerifyV8.Inputs memory in_ = _verifyInputs(set, false);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        (, failed) = verifyScript.check(in_);
    }

    /// @dev Schedule an admin-restricted manager call as the Admin Safe and warp its execution delay. Mirrors
    ///      test/v2/unit/FeeSplitter.t.sol:188-195 and 06-QUIRKS §D.2: the target is called DIRECTLY after the wait,
    ///      never through `manager.execute`, so `msg.sender` is still the member. Feed rounds are refreshed after
    ///      every wait: several cases exercise different delayed lanes in sequence, and those waits must not turn
    ///      an access-drift test into a stale-feed test.
    function _adminSchedule(AccessManager mgr, address target, bytes memory data) internal returns (uint32 delay) {
        bytes4 selector = bytes4(data);
        (bool immediate, uint32 targetDelay) = mgr.canCall(adminSafe, target, selector);
        require(!immediate && targetDelay != 0, "admin operation is not delayed");
        delay = targetDelay;
        vm.prank(adminSafe);
        mgr.schedule(target, data, 0);
        vm.warp(block.timestamp + delay);
        nvdaFeed.push(NVDA_ANSWER, block.timestamp - 1 hours);
        tslaFeed.push(TSLA_ANSWER, block.timestamp - 1 hours);
    }

    /// @dev The normal schedule -> wait -> direct-call path for a delayed Admin Safe mutation. `data` is used for
    ///      both legs, so the test cannot accidentally schedule a different operation from the one it executes.
    function _adminExecute(AccessManager mgr, address target, bytes memory data) internal {
        _adminSchedule(mgr, target, data);
        vm.prank(adminSafe);
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _adminReconfigure(Clearinghouse house, address underlying, V2Types.MarketConfig memory cfg) internal {
        AccessManager mgr = _mgr(d);
        _adminExecute(
            mgr,
            address(house),
            abi.encodeCall(Clearinghouse.setMarketListing, (underlying, cfg.enabled, cfg.strikeTick))
        );
        _adminExecute(
            mgr,
            address(house),
            abi.encodeCall(Clearinghouse.setMarketFees, (underlying, cfg.exerciseFeeBps, cfg.mintFeePpm))
        );
        _adminExecute(mgr, address(house), abi.encodeCall(Clearinghouse.setMarketOracle, (underlying, cfg.oracle)));
    }

    /// @dev CHECK GROUP 1, HANDOVER. The deployer keeping ADMIN is the failure that matters most: it means one key
    ///      still owns all sixteen contracts. GUARDIAN is parented to OPS_ADMIN, which the Safe holds at delay 0, so
    ///      this break needs no warp -- but ADMIN itself is delayed, hence the schedule.
    function test_verify_handover_deployerStillHoldsAdmin() public {
        AccessManager mgr = _mgr(d);
        uint256 before = _failures(d);
        bytes memory data = abi.encodeCall(AccessManager.grantRole, (mgr.ADMIN_ROLE(), deployer, 0));
        _adminSchedule(mgr, address(mgr), data);
        uint256 baseline = _failures(d); // after the warp, before the break
        // HOISTED ON PURPOSE. `vm.prank` is single-use and Solidity evaluates arguments BEFORE the outer call, so
        // `mgr.grantRole(mgr.ADMIN_ROLE(), ...)` spends the prank on the ADMIN_ROLE() getter and sends grantRole
        // from the TEST CONTRACT. The break would then fail as unauthorised rather than happening, and this test
        // would be measuring something other than the thing it names.
        uint64 adminRole = mgr.ADMIN_ROLE();
        vm.prank(adminSafe);
        mgr.grantRole(adminRole, deployer, 0);
        // Two independent groups catch this: handover sees ADMIN retained, and the principal sweep sees the
        // deployer holding a delayed role. That redundancy became reachable once the manifest walk stopped OOMing.
        // T-436 MEASURED 2 -> 3. The third is `every known principal holds exactly its roles.v8.json roles, over
        // every role id`, which gives the deployer no role at all and so names ADMIN as a surplus membership.
        // Measured by running this case, not predicted: the delta form makes it immune to the baseline moving.
        assertEq(_failures(d) - baseline, 3, "handover, delayed-principal and exact-membership checks catch it");
        assertEq(before, 0, "the set was clean before the break");
    }

    /// @dev CHECK GROUP 2a, PRINCIPALS: a manifest holder that does not hold what the manifest gives it. QUOTER is
    ///      parented to OPS_ADMIN (delay 0 for the Safe), so this is the one access break that needs no warp at all.
    function test_verify_principals_holderLostItsRole() public {
        AccessManager mgr = _mgr(d);
        assertEq(_failures(d), 0, "clean first");
        vm.prank(adminSafe);
        mgr.revokeRole(V8Roles.QUOTER, quoterKey);
        // T-436 MEASURED 1 -> 2: the new exact-membership sweep names the SAME break from the other direction,
        // as a role the manifest gives that the principal is MISSING.
        assertEq(_failures(d), 2, "FAIL  holder lost a role: the manifest check and the exact-membership sweep");
    }

    /// @dev CHECK GROUP 2b, PRINCIPALS: the right member, the WRONG execution delay. This is the quiet one -- the
    ///      holder list still looks complete, and only the delay comparison against `delaysS` catches it.
    function test_verify_principals_wrongExecutionDelay() public {
        AccessManager mgr = _mgr(d);
        vm.prank(adminSafe);
        mgr.grantRole(V8Roles.QUOTER, quoterKey, 3600); // manifest says QUOTER is instant
        assertEq(_failures(d), 1, "FAIL  every holder's execution delay is the manifest delay for that role");
    }

    /// @dev CHECK GROUP 2c, PRINCIPALS: a bot key in a DELAYED lane. A key that holds CONFIG_ADMIN can point the
    ///      Clearinghouse at another payout adapter after a 24 h wait; the manifest gives it nothing in 0..6.
    function test_verify_principals_botKeyInADelayedLane() public {
        AccessManager mgr = _mgr(d);
        bytes memory data = abi.encodeCall(AccessManager.grantRole, (V8Roles.CONFIG_ADMIN, guardianKey, 0));
        _adminSchedule(mgr, address(mgr), data);
        uint256 baseline = _failures(d);
        vm.prank(adminSafe);
        mgr.grantRole(V8Roles.CONFIG_ADMIN, guardianKey, 0);
        // T-436 MEASURED 1 -> 2: the delayed-lane sweep and the exact-membership sweep both name it. They are not
        // redundant -- the first would still catch a bot key in a delayed lane if the manifest ever GAVE it one,
        // and the second catches a surplus in the instant lanes 7..10 that the first cannot see at all.
        assertEq(_failures(d) - baseline, 2, "FAIL  a bot key in a delayed lane, named by both sweeps");
    }

    /// @dev CHECK GROUP 3a, MANIFEST: a listed selector re-roled. Moving the book's pause out of GUARDIAN and into
    ///      LISTING is exactly the kind of edit that leaves every contract wired and every role held, and quietly
    ///      makes the brake wait an hour.
    function test_verify_manifest_selectorMappedToTheWrongRole() public {
        AccessManager mgr = _mgr(d);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = OrderBook.setTradingPaused.selector;
        bytes memory data = abi.encodeCall(AccessManager.setTargetFunctionRole, (d.orderBook, sels, V8Roles.LISTING));
        _adminSchedule(mgr, address(mgr), data);
        uint256 baseline = _failures(d);
        vm.prank(adminSafe);
        mgr.setTargetFunctionRole(d.orderBook, sels, V8Roles.LISTING);
        // Two lines see it: the manifest comparison and the ABI walk, which now finds a selector answering to a role
        // the manifest does not give it. Both are supposed to fire; that is the redundancy, not a double count.
        assertEq(
            _failures(d) - baseline, 2, "FAIL  every roles.v8.json selector is mapped to its manifest role on chain"
        );
    }

    /// @dev CHECK GROUP 3b, MANIFEST: the role TREE. Re-parenting GUARDIAN to ADMIN is the change that would make a
    ///      guardian rotation wait 48 h, and nothing else in the run would notice.
    function test_verify_manifest_roleAdminReparented() public {
        AccessManager mgr = _mgr(d);
        bytes memory data = abi.encodeCall(AccessManager.setRoleAdmin, (V8Roles.GUARDIAN, mgr.ADMIN_ROLE()));
        _adminSchedule(mgr, address(mgr), data);
        uint256 baseline = _failures(d);
        // Hoisted for the same reason as in {test_verify_handover_deployerStillHoldsAdmin}: an inline external
        // getter eats the single-use prank.
        uint64 adminRole = mgr.ADMIN_ROLE();
        vm.prank(adminSafe);
        mgr.setRoleAdmin(V8Roles.GUARDIAN, adminRole);
        assertEq(_failures(d) - baseline, 1, "FAIL  every role's admin and guardian match roles.v8.json");
    }

    /// @dev CHECK GROUP 4, NO UNLISTED RESTRICTED SELECTOR. 06-QUIRKS §A.8 on chain: a selector the manifest never
    ///      named, mapped to a real role. The manifest comparison cannot see this one -- it only walks what the
    ///      manifest lists -- so the ABI walk is the only thing between this and a silent capability.
    function test_verify_manifest_unlistedSelectorMapped() public {
        AccessManager mgr = _mgr(d);
        bytes4[] memory sels = new bytes4[](1);
        // setOperator is a USER function: it is in the ABI and deliberately not in the manifest, so mapping it
        // to a role is exactly the silent capability grant this group exists to catch.
        sels[0] = Clearinghouse.setOperator.selector;
        bytes memory data =
            abi.encodeCall(AccessManager.setTargetFunctionRole, (d.clearinghouse, sels, V8Roles.LISTING));
        _adminSchedule(mgr, address(mgr), data);
        uint256 baseline = _failures(d);
        vm.prank(adminSafe);
        mgr.setTargetFunctionRole(d.clearinghouse, sels, V8Roles.LISTING);
        assertEq(_failures(d) - baseline, 1, "FAIL  no selector outside roles.v8.json is mapped to a role");
    }

    /// @dev CHECK GROUP 5, THE FOUR TREASURIES. Value leaves the protocol to exactly one address; a vault pointed at
    ///      anything else is the whole exit invariant gone, and every other check in the run still passes.
    function test_verify_money_vaultTreasuryMoved() public {
        AccessManager mgr = _mgr(d);
        bytes memory data = abi.encodeCall(MakerVault.setTreasury, (address(0xBAD)));
        uint32 delay = _adminSchedule(mgr, d.makerVault, data);
        assertGt(uint256(delay), 0, "TREASURY_ADMIN is a delayed lane");
        uint256 baseline = _failures(d);
        vm.prank(adminSafe);
        MakerVault(d.makerVault).setTreasury(address(0xBAD));
        assertEq(
            _failures(d) - baseline,
            1,
            "FAIL  feeSplitter, keeperRewards, makerVault, rewardsDistributor: all four treasuries are V2_TREASURY_SAFE"
        );
    }

    /// @dev CHECK GROUP 6, FEE RECIPIENTS. The book paying someone other than the splitter does not break a single
    ///      trade; it silently diverts the protocol's whole fee stream out of the flywheel.
    function test_verify_money_bookFeeRecipientDiverted() public {
        AccessManager mgr = _mgr(d);
        bytes memory data = abi.encodeCall(OrderBook.setFeeRecipient, (treasurySafe));
        _adminSchedule(mgr, d.orderBook, data);
        uint256 baseline = _failures(d);
        vm.prank(adminSafe);
        OrderBook(d.orderBook).setFeeRecipient(treasurySafe);
        assertEq(_failures(d) - baseline, 1, "FAIL  clearinghouse and orderBook pay fees to the feeSplitter");
    }

    /// @dev CHECK GROUP 7, MINTER. A second minter can create collateralised positions without the book's fee and cap
    ///      path. V2Errors.NotMinter's own NatSpec says the book is the only minter at launch.
    function test_verify_money_secondMinter() public {
        AccessManager mgr = _mgr(d);
        bytes memory data = abi.encodeCall(Clearinghouse.setMinter, (d.makerVault, true));
        _adminSchedule(mgr, d.clearinghouse, data);
        uint256 baseline = _failures(d);
        vm.prank(adminSafe);
        Clearinghouse(d.clearinghouse).setMinter(d.makerVault, true);
        assertEq(
            _failures(d) - baseline, 1, "FAIL  clearinghouse: no other contract of the set and no principal is a minter"
        );
    }

    /// @dev CHECK GROUP 9, LAUNCH CLEANLINESS. The discount seam is shipped OFF; a module set at launch can take up
    ///      to half of every taker fee (MAX_DISCOUNT_BPS 5000) and nothing else in the run would report it.
    function test_verify_money_discountModuleSetAtLaunch() public {
        AccessManager mgr = _mgr(d);
        bytes memory data = abi.encodeCall(OrderBook.setDiscountModule, (IFeeDiscount(d.makerRegistry)));
        _adminSchedule(mgr, d.orderBook, data);
        uint256 baseline = _failures(d);
        vm.prank(adminSafe);
        OrderBook(d.orderBook).setDiscountModule(IFeeDiscount(d.makerRegistry));
        assertEq(_failures(d) - baseline, 1, "FAIL  orderBook: no discount module at launch");
    }

    /*//////////////////////////////////////////////////////////////
                      CHECK GROUP 10, FLYWHEEL WIRING
    //////////////////////////////////////////////////////////////*/

    /// @dev WHY THESE BREAK STORAGE DIRECTLY INSTEAD OF GOING THROUGH THE ACCESSMANAGER LIKE EVERY TEST ABOVE.
    ///      The `_adminSchedule` route does not fit in the gas limit here and DID NOT BEFORE THIS ROW: at the base
    ///      commit, with this file and `VerifyV8.s.sol` reverted, all four existing `test_verify_money_*` tests
    ///      already die `EvmError: Revert` at ~1.0675e9 gas against forge's default 2^30 limit. Two full `check()`
    ///      runs plus the delayed lane's warp is simply over budget. A break that cannot execute proves nothing, so
    ///      these poke the slot and keep the two `check()` runs that `test_verify_cleanOnTheDeployedSet` already
    ///      shows fit in ~6.8e8.
    ///
    ///      THE SLOTS ARE DERIVED, NOT GUESSED: `forge inspect FeeSplitter storageLayout` gives router 3,
    ///      executor 4, `stonkhouse` 6 offset 0 with `burnBps` packed at offset 20, and `buybackCap` 7. AND NO
    ///      TEST BELOW TRUSTS THAT: each one asserts the PUBLIC GETTER actually changed before it looks at a
    ///      failure count. A wrong slot therefore fails loudly on its own line instead of quietly writing nothing
    ///      and leaving the check green -- which is the exact defect class this whole row is about.
    uint256 private constant SPLITTER_SLOT_ROUTER = 3;
    uint256 private constant SPLITTER_SLOT_EXECUTOR = 4;
    uint256 private constant SPLITTER_SLOT_TOKEN_AND_BURNBPS = 6;
    uint256 private constant SPLITTER_SLOT_BUYBACK_CAP = 7;

    /// @dev Overwrite the low 160 bits of a packed slot, leaving everything above them untouched.
    function _pokeAddress(address target, uint256 slot, address value) internal {
        bytes32 word = vm.load(target, bytes32(slot));
        bytes32 kept = word & ~bytes32(uint256(type(uint160).max));
        vm.store(target, bytes32(slot), kept | bytes32(uint256(uint160(value))));
    }

    /// @dev FINDING D21, AND THE IMPORTANT ONE. The decision says the splitter uses the SAME router as the
    ///      Clearinghouse payout path. `_pointers` checked the Clearinghouse's side and NOTHING checked the
    ///      splitter's, so a TREASURY_ADMIN operation that repointed the splitter alone left every other line in
    ///      the run passing. `FeeSplitter.router` is mutable storage and `setRouter` checks only that the new
    ///      address has code -- not that it is the Clearinghouse's adapter.
    function test_verify_flywheel_splitterRouterRepointed() public {
        FeeSplitter s = FeeSplitter(payable(d.feeSplitter));
        assertEq(s.router(), d.payoutRouter, "the splitter and the payout path share one router before the break");
        uint256 baseline = _failures(d);
        _pokeAddress(d.feeSplitter, SPLITTER_SLOT_ROUTER, d.makerRegistry);
        assertEq(s.router(), d.makerRegistry, "the break landed: the splitter's router really moved");
        assertEq(_failures(d) - baseline, 1, "FAIL  all 5 flywheel pointers are wired");
        // The Clearinghouse side is untouched, which is precisely why its own check cannot see this.
        assertEq(
            Clearinghouse(d.clearinghouse).payoutAdapter(),
            d.payoutRouter,
            "the Clearinghouse still points at the router, so only the splitter-side check can catch this"
        );
    }

    /// @dev A splitter pointed at a DIFFERENT executor. `buyback` would approve and call whatever answers there;
    ///      nothing burns, no call reverts, and before this group nothing in the run reported it.
    function test_verify_flywheel_executorRepointed() public {
        FeeSplitter s = FeeSplitter(payable(d.feeSplitter));
        assertEq(s.executor(), d.buybackExecutor, "the splitter points at the deployed executor before the break");
        uint256 baseline = _failures(d);
        _pokeAddress(d.feeSplitter, SPLITTER_SLOT_EXECUTOR, d.makerRegistry);
        assertEq(s.executor(), d.makerRegistry, "the break landed: the splitter's executor really moved");
        assertEq(_failures(d) - baseline, 1, "FAIL  all 5 flywheel pointers are wired");
    }

    /// @dev The token the splitter burns moved away from the token the executor buys. This is the pointer whose
    ///      expectation is NOT a field of `Contracts` -- it is read from the executor's `token` immutable -- so
    ///      this test is also what proves that derivation bites rather than comparing an address to itself.
    function test_verify_flywheel_tokenDivergesFromTheExecutorsToken() public {
        FeeSplitter s = FeeSplitter(payable(d.feeSplitter));
        assertEq(s.stonkhouse(), V4BuybackExecutor(payable(d.buybackExecutor)).token(), "one token before the break");
        uint256 baseline = _failures(d);
        _pokeAddress(d.feeSplitter, SPLITTER_SLOT_TOKEN_AND_BURNBPS, d.makerRegistry);
        assertEq(s.stonkhouse(), d.makerRegistry, "the break landed: the splitter's token really moved");
        // The packed neighbour must be untouched, or this test would be breaking two facts and crediting one.
        assertGt(uint256(s.burnBps()), 0, "burnBps shares slot 6 and must survive the poke");
        assertEq(_failures(d) - baseline, 1, "FAIL  all 5 flywheel pointers are wired");
    }

    /// @dev DIAL ONE. `_split` adds `amount * burnBps / BPS` to `buybackBalance`, so a zero share means the balance
    ///      never grows and every future buyback is a silent EMPTY skip. Fees keep flowing, the treasury keeps
    ///      receiving, and the flywheel is switched off with no failing call anywhere to show for it.
    function test_verify_flywheel_burnBpsZeroed() public {
        FeeSplitter s = FeeSplitter(payable(d.feeSplitter));
        assertGt(uint256(s.burnBps()), 0, "the launch split is non-zero before the break");
        address tokenBefore = s.stonkhouse();
        uint256 baseline = _failures(d);
        bytes32 slot = bytes32(SPLITTER_SLOT_TOKEN_AND_BURNBPS);
        vm.store(d.feeSplitter, slot, vm.load(d.feeSplitter, slot) & ~bytes32(uint256(0xffff) << 160));
        assertEq(uint256(s.burnBps()), 0, "the break landed: burnBps really is zero");
        assertEq(s.stonkhouse(), tokenBefore, "the token shares slot 6 and must survive the poke");
        assertEq(_failures(d) - baseline, 1, "FAIL  feeSplitter.burnBps is the configured launch split");
    }

    /// @dev THE HALF A FLOOR COULD NOT SEE, and the reason T-222 listed this as launch-phase work: a splitter
    ///      re-dialled to a LEGAL but WRONG split. One basis point is non-zero and inside BPS, so the old floor
    ///      passed it; the flywheel would then burn 0.01 % of every distribution and hand the rest to the treasury,
    ///      which is a 5,000-fold change to the token's sink reported by nothing. The check now reads the deploy's
    ///      own input (`V2_BURN_BPS` over `V2DeployBase.LAUNCH_BURN_BPS`) and compares, so this poke is a failure.
    ///
    ///      The poke is the same slot-6 read-modify-write as the zeroing case above, and asserts the packed
    ///      neighbour survived for the same reason: if a mask error clobbered `stonkhouse`, a second check would
    ///      fail and the delta would be 2, so the assertion below would not be measuring what it claims.
    function test_verify_flywheel_burnBpsReDialledToALegalButWrongSplit() public {
        FeeSplitter s = FeeSplitter(payable(d.feeSplitter));
        uint256 launchSplit = uint256(s.burnBps());
        assertEq(launchSplit, 5_000, "the fixture is deployed at the documented 50/50 launch split");
        address tokenBefore = s.stonkhouse();
        uint256 baseline = _failures(d);

        bytes32 slot = bytes32(SPLITTER_SLOT_TOKEN_AND_BURNBPS);
        bytes32 kept = vm.load(d.feeSplitter, slot) & ~bytes32(uint256(0xffff) << 160);
        vm.store(d.feeSplitter, slot, kept | bytes32(uint256(1) << 160));

        assertEq(uint256(s.burnBps()), 1, "the break landed: the split really is 1 bp");
        assertEq(s.stonkhouse(), tokenBefore, "the token shares slot 6 and must survive the poke");
        assertEq(_failures(d) - baseline, 1, "FAIL  feeSplitter.burnBps is the configured launch split: 1 != 5000");
    }

    /// @dev DIAL TWO. `buyback` short-circuits to `BuybackSkipped(EMPTY)` and returns (0, 0) when the cap is zero --
    ///      a SUCCESSFUL transaction that buys and burns nothing. This is the exact false-green the group exists
    ///      for: the operator's buyback confirms and the launch verifier prints VERIFY PASSED.
    function test_verify_flywheel_buybackCapZeroed() public {
        FeeSplitter s = FeeSplitter(payable(d.feeSplitter));
        assertGt(s.buybackCap(), 0, "the launch cap is non-zero before the break");
        uint256 baseline = _failures(d);
        vm.store(d.feeSplitter, bytes32(SPLITTER_SLOT_BUYBACK_CAP), bytes32(0));
        assertEq(s.buybackCap(), 0, "the break landed: the cap really is zero");
        assertEq(_failures(d) - baseline, 1, "FAIL  feeSplitter.buybackCap is non-zero and within BUYBACK_CAP_CEIL");
    }

    /// @dev T-222 SUSPICION 3, CLOSED. `VerifyV8._flywheelSubjects` is a list of five that mirrors
    ///      `DeployV8._splitterCalls` BY HAND. Nothing made the two grow together, so a sixth splitter pointer added
    ///      to the deploy batch would have shipped UNVERIFIED while this run still printed "all 5 flywheel pointers
    ///      are wired" -- the check reporting success about a set that no longer contains its subject, which is the
    ///      exact shape T-182 above records for check group 3d.
    ///
    ///      HOW THE PAIR IS LOAD-BEARING, because an equality between two constants proves nothing by itself.
    ///      `DeployV8._splitterCalls` now writes its pointers into a FIXED-SIZE array of
    ///      `DEPLOY_V8_SPLITTER_POINTERS`, so adding a sixth pointer there does not compile until that constant
    ///      grows; growing it turns this assertion red; and the only way back to green is to add the pointer to
    ///      `_flywheelSubjects` and grow `VERIFY_V8_FLYWHEEL_POINTERS` with it. The compiler catches the first step
    ///      and this test catches the second.
    ///
    ///      It is `pure` and holds no fixture on purpose: every delta test in this file needs ~1.354e9 gas against
    ///      foundry's default 2^30 limit (see the T-222 ledger entry), and a pin that cannot run under the repo's
    ///      own config would be one more test nobody executes.
    function test_flywheelPointerCountsAgree() public pure {
        assertEq(
            VERIFY_V8_FLYWHEEL_POINTERS,
            DEPLOY_V8_SPLITTER_POINTERS,
            "VerifyV8 reads a different number of splitter pointers than DeployV8 wires: the new one ships unverified"
        );
    }

    /*//////////////////////////////////////////////////////////////
              T-182 / F-DCON-07: THE SUBJECT OF GROUP 3's LAST PASS
    //////////////////////////////////////////////////////////////*/

    /// @dev CHECK GROUP 3d, MANIFEST: a CLOSED manifest target that `_set(c)` cannot see.
    ///
    ///      THE DEFECT THIS PROVES. Until T-182 the closed-target / target-admin-delay pass walked `_set(c)` --
    ///      the SIXTEEN contracts `DeployV8` creates, ending at `flywheel.buybackExecutor` -- while printing "no
    ///      managed target is closed and none carries a target admin delay". `roles.v8.json` names TWENTY-ONE
    ///      targets. HouseVault, HouseVaultFactory, Hedger and RewardsDistributorLender resolve for every other
    ///      group and were absent from that list, so closing any of the four printed a PASS. Three of them hold
    ///      money. The check reported success because its subject was not in the list it walked.
    ///
    ///      WHY THE LENDER INSTANCE CARRIES THE PROOF AND NOT HouseVault. `DeployV2Fixture` deploys the sixteen
    ///      only, so `d.houseVault` is `address(0)` here and {_targetsOpen} skips a zero address deliberately --
    ///      {_authorities} already FAILS it by name, and reading target state off `address(0)` would only
    ///      duplicate that failure with worse wording. `RewardsDistributorLender` is the same contract and the
    ///      same artifact as the core distributor, so a real second instance resolves everywhere the manifest
    ///      walks and the break is a REAL closed target on a REAL address.
    ///
    ///      IT BREAKS THE PROTECTED FACT, NOT THE CHECKER. `setTargetClosed` is the thing group 3 exists to
    ///      forbid: a closed target makes EVERY restricted selector on that contract answer to nobody, including
    ///      the manager's own, so the recovery is itself gated. It is sent from the Admin Safe through ADMIN's
    ///      real 48 h schedule, not forged with `vm.store`.
    ///
    ///      THE POSITIVE CONTROL, which is the only reason this assertion is worth anything: run this test
    ///      against the PRE-T-182 pass (walking `_set(c)`) and the delta is ZERO, because the lender instance is
    ///      not in that list at all. A test that only shows the new code passing would reproduce the bug inside
    ///      its own proof.
    function test_verify_manifest_closedLenderDistributorIsSeen() public {
        (V2DeployBase.Contracts memory set, AccessManager mgr, address lender) = _withLenderInstance();
        _closeLender(mgr, lender, true);
        assertTrue(mgr.isTargetClosed(lender), "the break landed: the target really is closed");
        uint256 broken = _accessFailures(set);
        console2.log("T-182 access failures, lender CLOSED:", broken);
        assertEq(broken, ACCESS_FAILURES_CLEAN + 1, "one more failure, and it is group 3's");
    }

    function test_verify_manifest_openLenderDistributorIsTheBaseline() public {
        (V2DeployBase.Contracts memory set, AccessManager mgr, address lender) = _withLenderInstance();
        assertFalse(mgr.isTargetClosed(lender), "the lender target is open");
        uint256 clean = _accessFailures(set);
        console2.log("T-182 access failures, lender OPEN:", clean);
        assertEq(clean, ACCESS_FAILURES_CLEAN, "the open baseline");
    }

    function test_verify_manifest_reopenedLenderDistributorRestoresTheBaseline() public {
        (V2DeployBase.Contracts memory set, AccessManager mgr, address lender) = _withLenderInstance();
        _closeLender(mgr, lender, true);
        assertTrue(mgr.isTargetClosed(lender), "the break landed");
        _closeLender(mgr, lender, false);
        assertFalse(mgr.isTargetClosed(lender), "the restore landed");
        uint256 restored = _accessFailures(set);
        console2.log("T-182 access failures, lender REOPENED:", restored);
        assertEq(restored, ACCESS_FAILURES_CLEAN, "restoring the target restores the baseline exactly");
    }

    /// @dev A REAL second RewardsDistributor wired in as the manifest's `RewardsDistributorLender`: same contract,
    ///      same artifact, a different reward token, which is exactly what P8-05 deploys and what `roles.v8.json`
    ///      keys under that name.
    function _withLenderInstance()
        internal
        returns (V2DeployBase.Contracts memory set, AccessManager mgr, address lender)
    {
        lender = address(new RewardsDistributor(IERC20(address(stonk)), d.accessManager, treasurySafe));
        set = d;
        set.rewardsDistributorLender = lender;
        mgr = _mgr(d);
    }

    /// @dev `setTargetClosed` is ADMIN-restricted on the manager itself, and the Admin Safe holds ADMIN at the
    ///      manifest's 48 h execution delay, so each flip is a real schedule → wait → call. {_adminSchedule}
    ///      refreshes the feeds across every wait, so two flips cannot age the baseline under this test.
    function _closeLender(AccessManager mgr, address lender, bool closed) internal {
        _adminSchedule(mgr, address(mgr), abi.encodeCall(AccessManager.setTargetClosed, (lender, closed)));
        vm.prank(adminSafe);
        mgr.setTargetClosed(lender, closed);
    }
}
