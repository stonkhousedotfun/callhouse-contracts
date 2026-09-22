// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {Managed} from "../../../src/v2/access/Managed.sol";

/// @dev A minimal v8 target: one `restricted` setter, so the only thing under test is the manager's answer about
///      (caller, target, selector). Deliberately NOT one of the real contracts -- a real one drags its own
///      constructor wiring in and the assertion stops being about the partition.
contract DelayProbeTarget is Managed {
    uint256 public value;

    constructor(address authority_) Managed(authority_) {}

    function setValue(uint256 v) external restricted {
        value = v;
    }
}

/// @dev `_executeScheduled` is internal, and it is the unit under test: it is where the script decides "send this
///      now" versus "schedule it". Exposing it is the whole harness; nothing else is overridden, so the code that
///      runs here is the code that runs on a deployment.
contract RegisterMarketsHarness is RegisterMarkets {
    bool internal _enabled;
    uint8 internal _phase;

    /// @dev The run mode, injected instead of exported. `vm.setEnv` writes the environment of the WHOLE
    ///      `forge test` process and forge runs cases concurrently, so an env-driven fixture races every other
    ///      case in the run -- which is not a hypothetical: the first version of this suite set `V2_SCHEDULE`
    ///      with `vm.setEnv` and three of its six cases failed, each reading the `false` a sibling had just
    ///      written. Overriding the seams keeps every case's mode its own.
    function setMode(bool enabled, uint8 phase) external {
        _enabled = enabled;
        _phase = phase;
    }

    function _scheduleEnabled() internal view override returns (bool) {
        return _enabled;
    }

    function _schedulePhase() internal view override returns (uint8) {
        return _phase;
    }

    function executeScheduled(Inputs memory in_, Signer memory s, Call[] memory calls) external returns (bool) {
        return _executeScheduled(in_, s, calls);
    }

    function phaseBoth() external pure returns (uint8) {
        return PHASE_BOTH;
    }

    function phaseSchedule() external pure returns (uint8) {
        return PHASE_SCHEDULE;
    }

    function phaseExecute() external pure returns (uint8) {
        return PHASE_EXECUTE;
    }
}

/// @notice The delayed/immediate partition in `RegisterMarkets._executeScheduled`, asserted in BOTH directions.
/// @dev WHY THIS FILE EXISTS (T-217). `script/v2/RegisterMarkets.s.sol` used to reach {V2DeployBase._execute}
///      directly whenever `V2_SCHEDULE` was unset, which sends every call raw. On that path `canCall` was never
///      asked, so immediacy was ASSUMED. Against the v8 manager -- where `roles.v8.json` gives the admin Safe
///      CONFIG_ADMIN at 24 h and LISTING at 1 h -- the first call reverted inside the target's own `restricted`
///      with `AccessManagerNotScheduled`, and the script surfaced it as the generic
///      "admin call reverted: <what>" with the delay nowhere in the message.
///
///      A TEST THAT ONLY EXERCISES THE ZERO-DELAY PATH IS THE FALSE GREEN THIS CLASS IS MADE OF: it passes both
///      before and after the fix, because the zero-delay path was never broken. Every fact below is therefore
///      asserted twice, once with a delay on the grant and once without, and the two assertions must disagree.
///
///      NOTHING HERE TOUCHES THE ENVIRONMENT, AND THAT IS A FINDING RATHER THAN A STYLE CHOICE. The first version
///      of this suite drove `V2_SCHEDULE` with `vm.setEnv`; three of its six cases failed, each one reading the
///      `false` a sibling case had just written, because `vm.setEnv` writes the environment of the whole
///      `forge test` process while forge runs cases concurrently. The script now exposes
///      {RegisterMarkets._scheduleEnabled} and {RegisterMarkets._schedulePhase} as `virtual` seams and the harness
///      overrides them, so each case carries its own mode and no suite in the same process is disturbed.
contract AccessManagerDelaysTest is Test {
    AccessManager internal mgr;
    DelayProbeTarget internal target;
    RegisterMarketsHarness internal script;

    address internal constant SIGNER = address(0xA11CE);
    uint64 internal constant PROBE_ROLE = 42;
    /// @dev The CONFIG_ADMIN delay of `script/v2/roles.v8.json` `.delaysS`, stated here as a SHAPE not a pin: this
    ///      suite asserts "non-zero delay changes the branch", not "the delay is 86400". Nothing else consumes it.
    uint32 internal constant PROBE_DELAY = 86_400;
    uint256 internal constant NEW_VALUE = 7;
    /// @dev The ADMIN delay of `script/v2/roles.v8.json` `.delaysS`, stated as a SHAPE not a pin, exactly as
    ///      {PROBE_DELAY} above: the T-223 cases assert "the role admin's own execution delay is what makes the
    ///      rotation wait", not "the number is 172800". Nothing else consumes it.
    uint32 internal constant ADMIN_DELAY = 172_800;

    function setUp() public {
        mgr = new AccessManager(address(this));
        target = new DelayProbeTarget(address(mgr));
        script = new RegisterMarketsHarness();

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = DelayProbeTarget.setValue.selector;
        mgr.setTargetFunctionRole(address(target), sels, PROBE_ROLE);
        _singleRunMode();
    }

    /*//////////////////////////////////////////////////////////////
                              THE PARTITION
    //////////////////////////////////////////////////////////////*/

    /// @dev DIRECTION 1: a NON-ZERO execution delay must stop the single-run path before it broadcasts anything.
    ///      The assertion is not merely "it reverts" -- against the unfixed script it also reverted, just later,
    ///      from inside the target. It is that the refusal comes from the SCRIPT, names the delay, and leaves the
    ///      target untouched.
    function test_singleRun_refusesADelayedCall() public {
        mgr.grantRole(PROBE_ROLE, SIGNER, PROBE_DELAY);
        _singleRunMode();

        vm.expectRevert(
            bytes(
                string.concat(
                    "a delayed admin call cannot be sent by a single run: probe.setValue waits 86400s.",
                    " Re-run with V2_SCHEDULE=true V2_SCHEDULE_PHASE=schedule, move the node clock past the delay,",
                    " then run again with V2_SCHEDULE_PHASE=execute."
                )
            )
        );
        script.executeScheduled(_inputs(), _signer(), _calls());

        assertEq(target.value(), 0, "the delayed call must not have been sent");
    }

    /// @dev DIRECTION 2: the SAME call, the same signer, the same selector, at delay 0 -- and it must go straight
    ///      through. This is the half that keeps the fix from being "refuse everything", which would pass
    ///      direction 1 and break every deployment.
    function test_singleRun_sendsAnImmediateCall() public {
        mgr.grantRole(PROBE_ROLE, SIGNER, 0);
        _singleRunMode();

        bool executed = script.executeScheduled(_inputs(), _signer(), _calls());

        assertTrue(executed, "an immediate call is executed by the single run");
        assertEq(target.value(), NEW_VALUE, "the immediate call reached the target");
    }

    /// @dev The signer holds no role at all: `canCall` answers neither immediate nor delayed, and waiting cannot
    ///      fix that. It must NOT be reported as a delay, or an operator will schedule an operation that can never
    ///      be consumed.
    function test_singleRun_refusesACallTheSignerCannotMake() public {
        _singleRunMode();

        vm.expectRevert(
            bytes(
                string.concat(
                    "the signer cannot make this call at all: probe.setValue -- canCall answers neither immediate",
                    " nor delayed, so the (target, selector) is unmapped or ",
                    vm.toString(SIGNER),
                    " does not hold its role"
                )
            )
        );
        script.executeScheduled(_inputs(), _signer(), _calls());
    }

    /*//////////////////////////////////////////////////////////////
                        THE TWO-PHASE DELAYED PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev With `V2_SCHEDULE` on, the delayed call SCHEDULES and sends nothing: `executed` is false, the target is
    ///      untouched, and the manager holds an operation ready at `now + delay` -- read back from `getSchedule`
    ///      rather than computed, because the manager's clock is the one that decides.
    function test_schedulePhase_schedulesTheDelayedCallAndSendsNothing() public {
        mgr.grantRole(PROBE_ROLE, SIGNER, PROBE_DELAY);
        script.setMode(true, script.phaseSchedule());

        bool executed = script.executeScheduled(_inputs(), _signer(), _calls());

        assertFalse(executed, "the schedule phase sends no target call");
        assertEq(target.value(), 0, "nothing reached the target");
        bytes32 opId = mgr.hashOperation(SIGNER, address(target), _data());
        assertEq(uint256(mgr.getSchedule(opId)), block.timestamp + PROBE_DELAY, "ready at now + the delay");
        _singleRunMode();
    }

    /// @dev And the other end of it: after the delay has actually passed, the execute phase sends the call from the
    ///      SIGNER (not through `manager.execute`, which would make the target see the manager as `msg.sender`) and
    ///      the manager consumes the scheduled operation.
    function test_executePhase_sendsTheCallOnceTheDelayHasPassed() public {
        mgr.grantRole(PROBE_ROLE, SIGNER, PROBE_DELAY);
        script.setMode(true, script.phaseSchedule());
        script.executeScheduled(_inputs(), _signer(), _calls());

        vm.warp(block.timestamp + PROBE_DELAY + 1);
        script.setMode(true, script.phaseExecute());
        bool executed = script.executeScheduled(_inputs(), _signer(), _calls());

        assertTrue(executed, "the execute phase sends the target call");
        assertEq(target.value(), NEW_VALUE, "the delayed call reached the target after the wait");
        bytes32 opId = mgr.hashOperation(SIGNER, address(target), _data());
        assertEq(uint256(mgr.getSchedule(opId)), 0, "the scheduled operation was consumed");
        _singleRunMode();
    }

    /// @dev The delayed call, scheduled but sent BEFORE its ready time, must still be refused by the manager. This
    ///      is the fact the whole two-phase dance exists to respect, and it is asserted here so that a future
    ///      "simplification" that drops the wait fails loudly rather than only on a real deployment.
    function test_executePhase_beforeTheDelayIsStillRefused() public {
        mgr.grantRole(PROBE_ROLE, SIGNER, PROBE_DELAY);
        script.setMode(true, script.phaseSchedule());
        script.executeScheduled(_inputs(), _signer(), _calls());

        script.setMode(true, script.phaseExecute());
        vm.expectRevert(bytes("delayed admin call reverted: probe.setValue"));
        script.executeScheduled(_inputs(), _signer(), _calls());

        assertEq(target.value(), 0, "nothing reached the target before the delay expired");
        _singleRunMode();
    }

    /*//////////////////////////////////////////////////////////////
                    THE LOWERING PATH (T-223 / D13)
    //////////////////////////////////////////////////////////////*/

    /// @dev D13 SAYS "lowering a delay is itself delayed". IT IS TRUE ON ONE PATH AND FALSE ON THE OTHER, and a
    ///      reader who takes it as a blanket per-delay setback will size the hot-key risk wrongly. Both halves are
    ///      asserted in ONE case, against two accounts that start identical and end identical, because either half
    ///      alone is a false green: "the direct lowering waits" passes on a manager that delays everything, and
    ///      "revoke-then-grant is instant" passes on a manager that delays nothing. Only the DISAGREEMENT at one
    ///      timestamp is evidence, and the last assertion is that disagreement.
    ///
    ///      Re-derived at this base rather than taken from the decision text:
    ///      `AccessManager._grantRole` on an EXISTING member calls `Time.withUpdate(executionDelay, 0)`, and
    ///      `withUpdate` takes `setback = max(minSetback, value > newValue ? value - newValue : 0)` -- the 0
    ///      `minSetback` contributes nothing and the whole setback is the size of the decrease.
    ///      `AccessManager._revokeRole` deletes `members[account]`, so `since` is 0 and the next grant takes the
    ///      NEW MEMBER branch, which assigns `executionDelay` outright and never reaches `withUpdate`.
    function test_loweringADelay_isSelfDelayedOnlyOnTheDirectPath() public {
        address direct = address(0xD1);
        address rotated = address(0xD2);

        mgr.grantRole(PROBE_ROLE, direct, PROBE_DELAY);
        mgr.grantRole(PROBE_ROLE, rotated, PROBE_DELAY);

        // (a) DIRECT: a second grantRole on an existing member. Self-delayed by the decrease.
        mgr.grantRole(PROBE_ROLE, direct, 0);
        (, uint32 curDirect, uint32 pendDirect, uint48 effDirect) = mgr.getAccess(PROBE_ROLE, direct);
        assertEq(curDirect, PROBE_DELAY, "the direct lowering must NOT bite yet");
        assertEq(pendDirect, 0, "0 is the PENDING value here, not the current one");
        assertEq(effDirect, uint48(block.timestamp) + PROBE_DELAY, "held for exactly the size of the decrease");

        // (b) ROTATED: revoke, then grant. Same destination, no setback at all.
        mgr.revokeRole(PROBE_ROLE, rotated);
        mgr.grantRole(PROBE_ROLE, rotated, 0);
        (, uint32 curRotated, uint32 pendRotated, uint48 effRotated) = mgr.getAccess(PROBE_ROLE, rotated);
        assertEq(curRotated, 0, "revoke-then-grant lands the new delay with no setback at all");
        assertEq(pendRotated, 0, "nothing pending, because nothing was scheduled");
        assertEq(effRotated, 0, "and no effect timepoint either");

        // THE DISAGREEMENT IS THE FINDING. Delete either branch above and this line stops meaning anything.
        assertTrue(curDirect != curRotated, "two routes to delay 0 that must not agree at this instant");
    }

    /// @dev THE OTHER HALF OF THE DIRECT PATH, so the case above cannot be satisfied by a manager that simply never
    ///      applies a lowering. One second early it is still the old delay; at the effect timepoint it is the new
    ///      one. A `withUpdate` that was changed to hold the decrease FOREVER would pass the case above and fail
    ///      this one.
    function test_theDirectLowering_landsExactlyWhenTheDecreaseHasElapsed() public {
        mgr.grantRole(PROBE_ROLE, SIGNER, PROBE_DELAY);
        mgr.grantRole(PROBE_ROLE, SIGNER, 0);
        (,,, uint48 effect) = mgr.getAccess(PROBE_ROLE, SIGNER);
        assertEq(effect, uint48(block.timestamp) + PROBE_DELAY, "the transition is scheduled, not immediate");

        vm.warp(effect - 1);
        (, uint32 oneSecondEarly,,) = mgr.getAccess(PROBE_ROLE, SIGNER);
        assertEq(oneSecondEarly, PROBE_DELAY, "one second early is still the OLD delay");

        vm.warp(effect);
        (, uint32 atEffect,,) = mgr.getAccess(PROBE_ROLE, SIGNER);
        assertEq(atEffect, 0, "and at the effect timepoint it is the new one");
    }

    /// @dev THE POSITIVE CONTROL FOR THE SETBACK: it comes from the DECREASE, not from `withUpdate` always waiting.
    ///      Raising the same delay on the same account takes `value > newValue == false`, so the setback is 0 and
    ///      the new value is current in the same block. Without this case, "lowering is delayed" would be
    ///      indistinguishable from "every change is delayed", which is a different contract and a different risk.
    function test_raisingADelay_isImmediate_soTheSetbackIsTheDecreaseItself() public {
        mgr.grantRole(PROBE_ROLE, SIGNER, 0);
        mgr.grantRole(PROBE_ROLE, SIGNER, PROBE_DELAY);

        (, uint32 current, uint32 pending, uint48 effect) = mgr.getAccess(PROBE_ROLE, SIGNER);
        assertEq(current, PROBE_DELAY, "raising bites in the same block");
        assertEq(pending, 0, "nothing pending");
        assertEq(effect, 0, "and nothing scheduled: the setback was 0");
    }

    /// @dev WHAT ACTUALLY BUYS THE 48 h, AND THEREFORE WHAT CLOSES THE REVOKE-THEN-GRANT HOLE. Nothing in
    ///      `withUpdate` does it. `AccessManager._getAdminRestrictions` routes BOTH `grantRole` and `revokeRole` to
    ///      the role's admin "with no delay beside any execution delay the caller may have", so each leg of the
    ///      rotation is an ADMIN call that waits out ADMIN's OWN execution delay -- which `roles.v8.json` sets to
    ///      48 h for every role whose delay is non-zero. The hole is real in the manager and closed by this file's
    ///      lane assignment, not by the setback.
    ///
    ///      Asserted in both directions: the SAME safe, the SAME call, refused while its ADMIN delay is non-zero
    ///      and sent once the schedule has matured. A one-directional version would pass against a manager that
    ///      refuses the safe outright, which is the opposite of the intended design.
    function test_bothLegsOfTheRotation_waitOutTheAdminsOwnExecutionDelay() public {
        address safe = address(0x5AFE);
        mgr.grantRole(mgr.ADMIN_ROLE(), safe, ADMIN_DELAY);
        mgr.grantRole(PROBE_ROLE, SIGNER, PROBE_DELAY);

        // BOTH operation ids are computed HERE, before any prank is armed. `hashOperation` is an external call,
        // and an external call written inside a `vm.expectRevert` argument is evaluated BEFORE the cheatcode runs
        // -- so it would eat the `vm.prank` and the case would assert against the wrong caller.
        bytes memory revokeData = abi.encodeCall(AccessManager.revokeRole, (PROBE_ROLE, SIGNER));
        bytes memory grantData = abi.encodeCall(AccessManager.grantRole, (PROBE_ROLE, SIGNER, 0));
        bytes32 revokeOpId = mgr.hashOperation(safe, address(mgr), revokeData);
        bytes32 grantOpId = mgr.hashOperation(safe, address(mgr), grantData);

        // DIRECTION 1: the revoke leg is refused outright while the delay stands.
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, revokeOpId));
        mgr.revokeRole(PROBE_ROLE, SIGNER);

        // The grant leg of the same rotation is refused on the same terms.
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, grantOpId));
        mgr.grantRole(PROBE_ROLE, SIGNER, 0);

        // DIRECTION 2: schedule it, wait out ADMIN's execution delay, and the very same call goes through.
        vm.prank(safe);
        mgr.schedule(address(mgr), revokeData, 0);
        vm.warp(block.timestamp + ADMIN_DELAY);
        vm.prank(safe);
        mgr.revokeRole(PROBE_ROLE, SIGNER);

        (uint48 since,,,) = mgr.getAccess(PROBE_ROLE, SIGNER);
        assertEq(since, 0, "the revoke leg landed, but only after the ADMIN execution delay");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev `V2_SCHEDULE` off and no phase: the single-run mode a plain `forge test` or an un-wrapped script run
    ///      sees. Written out rather than left unset so that no test in this file depends on the environment a
    ///      previous test happened to leave behind.
    function _singleRunMode() internal {
        script.setMode(false, script.phaseBoth());
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encodeCall(DelayProbeTarget.setValue, (NEW_VALUE));
    }

    function _calls() internal view returns (V2DeployBase.Call[] memory calls) {
        calls = new V2DeployBase.Call[](1);
        calls[0] = V2DeployBase.Call({to: address(target), data: _data(), what: "probe.setValue"});
    }

    function _signer() internal pure returns (V2DeployBase.Signer memory) {
        return V2DeployBase.Signer({pk: 0, addr: SIGNER});
    }

    /// @dev Only `c.accessManager` matters: {RegisterMarkets._manager} prefers the explicit manager and never
    ///      touches the Clearinghouse when one is given, so this fixture needs no deployment set.
    function _inputs() internal view returns (RegisterMarkets.Inputs memory in_) {
        in_.admin = SIGNER;
        in_.c.accessManager = address(mgr);
    }
}
