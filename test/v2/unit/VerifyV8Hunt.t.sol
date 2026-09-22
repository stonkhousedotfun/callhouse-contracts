// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {DeployV2Fixture, MockExternalTarget} from "./DeployV2Fixture.t.sol";

/// @dev The production walk, observed by name. `_check` and `_notChecked` are `virtual` for exactly this (VerifyV8's
///      own NatSpec says so); the overrides record and delegate, so what is measured is VerifyV8 itself.
contract VerifyV8Recorder is VerifyV8 {
    string[] public failedNames;
    string[] public passedNames;
    string[] public notCheckedNames;

    function _check(bool ok, string memory what) internal override {
        if (ok) passedNames.push(what);
        else failedNames.push(what);
        super._check(ok, what);
    }

    function _notChecked(string memory what) internal override {
        notCheckedNames.push(what);
        super._notChecked(what);
    }

    function failedCount() external view returns (uint256) {
        return failedNames.length;
    }

    function passedCount() external view returns (uint256) {
        return passedNames.length;
    }

    function notCheckedCount() external view returns (uint256) {
        return notCheckedNames.length;
    }
}

/// @notice T-OP-166. Targeted tests for the pass-without-looking findings of the VerifyV8 / DeployV8 read
///         (docs/examinations/VERIFYV8-DEPLOYV8-HUNT-2026-09-22.md). EACH `test_hunt_*` CASE WAS WRITTEN TO FAIL AT
///         THE BASE IT WAS AUTHORED AGAINST (`bc23cc0c`): the assertion states the behaviour the verifier should
///         have, and the red run was the demonstration that it did not. T-OP-171 fixed the three findings, so from
///         that landing the three hunt cases are GREEN and stay as the pins; the `test_control_*` cases are the
///         positive controls -- the same instrument pointed at a case the verifier caught all along -- and pass in
///         both states, so a red hunt case is a finding and not a broken harness.
/// @dev The fixture deploys the whole v8 set through DeployV8; markets are NOT registered here (the registration
///      harness lives in VerifyV8.t.sol), so a full `check()` on `_verifyInputs(d, ...)` carries the two markets'
///      "registered on the Clearinghouse" failures. Every assertion below is BY NAME for that reason: a count would
///      confuse those expected reds with the finding under test.
contract VerifyV8HuntTest is DeployV2Fixture {
    VerifyV8Recorder internal rec;
    V2DeployBase.Contracts internal d;

    function setUp() public override {
        super.setUp();
        d = _deploy();
        rec = new VerifyV8Recorder();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Whether any recorded name of `kind` ("failed" | "passed" | "notChecked") contains `needle`.
    function _has(string memory needle, string memory kind) internal view returns (bool) {
        bytes32 k = keccak256(bytes(kind));
        uint256 n = k == keccak256("failed")
            ? rec.failedCount()
            : k == keccak256("passed") ? rec.passedCount() : rec.notCheckedCount();
        for (uint256 i; i < n; ++i) {
            string memory s = k == keccak256("failed")
                ? rec.failedNames(i)
                : k == keccak256("passed") ? rec.passedNames(i) : rec.notCheckedNames(i);
            if (vm.indexOf(s, needle) != type(uint256).max) return true;
        }
        return false;
    }

    function _failed(string memory needle) internal view returns (bool) {
        return _has(needle, "failed");
    }

    function _passed(string memory needle) internal view returns (bool) {
        return _has(needle, "passed");
    }

    function _notChecked(string memory needle) internal view returns (bool) {
        return _has(needle, "notChecked");
    }

    /*//////////////////////////////////////////////////////////////
              FINDING 1: a live-set parameter mismatch is never a FAIL
    //////////////////////////////////////////////////////////////*/

    /// @notice VerifyV8.s.sol:910-914 `_param`: with `expectFresh == false` an unequal parameter is an `info` line,
    ///         never a failure, and an equal one is counted as a PASS -- so a post-launch verify (`--verify
    ///         --expect-fresh false`) cannot red on any of the ~17 `_param` subjects (fees, slippage, bounties,
    ///         dailyCap, minRollUnits, maker-vault limits, per-market mintFeePpm). The desired behaviour asserted
    ///         here: a parameter the caller EXPLICITLY handed the verifier that the chain contradicts is a failure
    ///         in every mode. RED AT bc23cc0c; GREEN since T-OP-171 (a FAIL unless the subject is listed in
    ///         V2_EXPECT_CHANGED, which this case does not do).
    function test_hunt_liveSetParameterMismatchIsAFailure() public {
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        uint16 live = Clearinghouse(d.clearinghouse).maxPayoutSlippageBps();
        in_.params.payoutSlippageBps = live + 1; // the registry says one thing, the chain another
        rec.check(in_);
        assertTrue(
            _failed("clearinghouse maxPayoutSlippageBps =="),
            "a live-set verify was handed payoutSlippageBps that the chain contradicts and did not fail on it"
        );
    }

    /// @notice CONTROL: the same mismatch on a FRESH verify is a named failure, so the instrument works.
    function test_control_freshParameterMismatchIsAFailure() public {
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        uint16 live = Clearinghouse(d.clearinghouse).maxPayoutSlippageBps();
        in_.params.payoutSlippageBps = live + 1;
        rec.check(in_);
        assertTrue(_failed("clearinghouse maxPayoutSlippageBps =="), "fresh: the mismatch is a failure");
    }

    /// @notice CONTROL: on a live set an EQUAL parameter is counted as a pass (`_check(true, what)`), which is what
    ///         inflates the PASSED count with tautologies while a mismatch can never lower it.
    function test_control_liveSetEqualParameterCountsAsAPass() public {
        VerifyV8.Inputs memory in_ = _verifyInputs(d, false);
        rec.check(in_);
        assertTrue(_passed("clearinghouse maxPayoutSlippageBps =="), "live: an equal parameter is a counted pass");
    }

    /*//////////////////////////////////////////////////////////////
         FINDING 2: an absent market list is silence, not NOT CHECKED
    //////////////////////////////////////////////////////////////*/

    /// @notice VerifyV8.s.sol:308-310 and :344-347 (`check`): with `V2_TICKERS` unset the market group does not
    ///         run and nothing says so -- no `_notChecked`, no line under the verdict -- while the SAME situation for
    ///         `V2_DEPLOYER` (:1141-1143) is reported NOT CHECKED. `_unregistered` (:2512-2513) returns silently the
    ///         same way. A `VERIFY PASSED` from a run that verified no market is indistinguishable from one that
    ///         verified all of them. Desired: an empty market list is NOT CHECKED by name. RED AT bc23cc0c; GREEN
    ///         since T-OP-171.
    function test_hunt_noMarketsIsReportedNotChecked() public {
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.markets = new V2DeployBase.MarketIn[](0);
        in_.mintFeePpm = new uint32[](0);
        rec.check(in_);
        assertTrue(
            _notChecked("market") || _notChecked("V2_TICKERS"),
            "no market was verified and the run did not say NOT CHECKED"
        );
    }

    /// @notice CONTROL: the deployer's absence IS reported NOT CHECKED by name, so `_notChecked` is observable.
    function test_control_noDeployerIsReportedNotChecked() public {
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        in_.deployer = address(0);
        rec.check(in_);
        assertTrue(_notChecked("V2_DEPLOYER is unset"), "the deployer group says NOT CHECKED by name");
    }

    /*//////////////////////////////////////////////////////////////
       FINDING 3: a target that enforces nothing is `info`, and clean
    //////////////////////////////////////////////////////////////*/

    /// @notice VerifyV8.s.sol:1795-1808 (`_noUnlistedRestrictedTarget`): the stranger probe has a positive control
    ///         -- every manifest selector of the target must refuse a stranger -- and when NONE does the code's own
    ///         words are "it is not the contract the manifest names here"; that conclusion is then printed as an
    ///         `info` line, the stranger probe is skipped, and the target is counted CLEAN (`clean` stays true, no
    ///         `_notChecked`). Every other identity guard passes such a contract too: `_authorities` (it answers
    ///         `authority()`), `_manifest` (the manager's map is keyed by address, not by what lives there),
    ///         `_identity` (any non-empty return), `_bytecode` (externals are not in `_set`). This fixture's six
    ///         external stand-ins refuse nobody, so the suite's "clean" baseline is measured against six targets
    ///         that enforce nothing -- which was the demonstration. Desired: a target whose manifest selectors all
    ///         admit a stranger is a named failure, never silently clean. RED AT bc23cc0c; GREEN since T-OP-171,
    ///         which also gated the fixture's six doubles on their manifest rows (DeployV2Fixture `_gate`) -- so
    ///         this case now UN-GATES the HouseVault double first, to keep pointing the instrument at a target that
    ///         refuses nobody.
    function test_hunt_targetThatRefusesNobodyIsNotClean() public {
        MockExternalTarget(houseVault).gate(new bytes4[](0)); // enforce nothing, as the fixture did before T-OP-171
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        rec.check(in_);
        bool caught = _failed("no selector outside roles.v8.json is mapped to a role or refuses a stranger");
        assertTrue(caught, "HouseVault refuses a stranger on none of its manifest selectors and was counted clean");
    }

    /// @notice CONTROL: the same walk over a REAL core target is not skipped -- the OrderBook refuses a stranger on
    ///         its manifest selectors, so its group line is a counted pass with the probe actually run.
    function test_control_coreTargetIsProbed() public {
        VerifyV8.Inputs memory in_ = _verifyInputs(d, true);
        rec.check(in_);
        assertTrue(
            _passed("no selector outside roles.v8.json is mapped to a role or refuses a stranger"),
            "the unlisted-restricted group runs and passes on the real core set"
        );
    }
}
