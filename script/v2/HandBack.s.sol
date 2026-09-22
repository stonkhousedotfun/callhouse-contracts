// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {DeployV8} from "./DeployV8.s.sol";

/// @notice T-OP-153. The deferred steps 8 and 9 of `DeployV8`: the deployer renounces whatever `roles.v8.json` roles
///         it still holds -- the delay-0 working roles of step 4, then ADMIN, last -- on a set that was deployed
///         with `V2_DEFER_HANDBACK=true`.
/// @dev THE LAUNCH SEQUENCE THIS SCRIPT ENDS (owner decisions 2026-09-22 05:35Z and 05:50Z / amendment #1: no 48 h
///      Safe gap at launch, and the deferred window also covers market registration):
///        1. `DeployV8.s.sol` with V2_DEFER_HANDBACK=true  -- steps 1-7; the deployer keeps ADMIN and every
///                                                             `.targets` role at delay 0.
///        2. the externals' own deploy scripts (T-OP-116's driver).
///        3. `MapExternals.s.sol`                           -- maps every supplied external at delay 0.
///        4. `RegisterMarkets.s.sol` AS THE DEPLOYER        -- direct, no schedule: it holds LISTING and
///                                                             CONFIG_ADMIN at delay 0 (`createVault` likewise, T-OP-141).
///        5. THIS SCRIPT                                    -- drops the working roles, renounces ADMIN. The LAST
///                                                             call before VerifyV8.
///        6. `VerifyV8.s.sol`                               -- unchanged; `_handover` (SEC-38-R) is red until 5.
///      ACCEPTED COST (coordinator stated, owner accepted): the deployer hot key holds ADMIN and the delay-0 working
///      roles between 1 and 5.
///
///      IT RENOUNCES EXACTLY WHAT THE PLANNER FINDS. The calls are `DeployV8._pendingHandBack` -- the same function
///      the atomic deploy sends as its last batch -- for whatever the deployer actually holds: every manifest role
///      but ADMIN first (step 8), then ADMIN, last (step 9). Nothing here decides what to renounce; the chain does.
///
///      `_assertAdminSafeCanTakeOver` RUNS FIRST. It is inside the planner, before the ADMIN renounce is even
///      appended: the Admin Safe must already hold ADMIN at the manifest delay, with no pending delay change, and
///      must be a genuine 2-of-3 Safe (T-426). `AccessManager._revokeRole` has no last-admin guard, so this is the
///      one check standing between this script and sixteen permanently unmanageable contracts.
///
///      IT REFUSES TO RENOUNCE ON AN UNFINISHED SET. Any pending selector map (a supplied external that
///      `MapExternals.s.sol` has not mapped), wiring, holder grant or role-tree call is a reason to stop: after the
///      renounce those can only be sent by the Safe through its delayed lane, which is the gap this whole sequence
///      exists to avoid. The set must be complete; then, and only then, the deployer lets go.
///
///      IDEMPOTENT. A second run finds the deployer holding nothing, says so, and exits 0.
///
///      Driven by T-OP-116's driver with the registry's V2_* environment loaded:
///        forge script script/v2/HandBack.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching \
///          --non-interactive
contract HandBack is DeployV8 {
    /// @dev Entry point: the same environment and signer rules as `DeployV8.run`, then {handBackWith}.
    function run() external override returns (Contracts memory d) {
        Inputs memory in_ = inputsFromEnv();
        Signer memory deployer = _deployerFromEnv(in_);
        require(deployer.addr != address(0), "V2_DEPLOYER (or DEPLOYER_PK) is required: it is who renounces");
        require(
            block.chainid == in_.expectChainId,
            string.concat("chain id ", vm.toString(block.chainid), ", expected ", vm.toString(in_.expectChainId))
        );
        d = in_.existing;
        uint256 sent = handBackWith(in_, deployer);
        console2.log("");
        console2.log(string.concat("HAND BACK DONE: ", vm.toString(sent), " renounce call(s) sent"));
    }

    /// @notice Renounces what `_pendingHandBack` finds, after refusing an unfinished set. Returns the calls sent.
    function handBackWith(Inputs memory in_, Signer memory deployer) public returns (uint256 sent) {
        Contracts memory c = in_.existing;
        require(c.accessManager != address(0), "HandBack: V2_ACCESS_MANAGER is zero: this script finishes a deployed set");
        _wholeSet(c);
        _linkage(in_, c);
        _refuseUnfinishedSet(in_, c);

        // The planner asserts the Safe can take over BEFORE it appends the ADMIN renounce; nothing is sent until it
        // has returned.
        Call[] memory calls = _pendingHandBack(in_, c, deployer.addr);
        if (calls.length == 0) {
            _skip("hand-back already complete: the deployer holds no roles.v8.json role; nothing to renounce");
            return 0;
        }
        sent = _send(deployer, calls, "hand back (deferred steps 8 and 9)");
        // The atomic deploy's own post-check: the set is whole and the deployer holds NOTHING.
        _postCheck(in_, c, deployer.addr);
    }

    /// @dev Every hand-over call a pass would still send, other than the hand-back itself. One pending call is one
    ///      reason not to renounce: after the renounce it can only be sent through the Safe's delayed lane.
    function _refuseUnfinishedSet(Inputs memory in_, Contracts memory c) internal view {
        Call[] memory maps = _pendingMapping(c);
        if (maps.length != 0) {
            revert(
                string.concat(
                    "HandBack: refusing to renounce ADMIN: ",
                    vm.toString(maps.length),
                    " roles.v8.json selector(s) are still unmapped (first: ",
                    maps[0].what,
                    "). Run MapExternals.s.sol for the supplied externals first; an unsupplied one belongs in"
                    " V2_SKIP_EXTERNALS. Renouncing now would leave those selectors ADMIN-only behind a 48 h lane."
                )
            );
        }
        (Call[] memory wiring,) = _pendingWiring(in_, c);
        Call[] memory holders = _pendingHolders(in_, c);
        Call[] memory tree = _pendingRoleTree(c);
        require(
            wiring.length + holders.length + tree.length == 0,
            string.concat(
                "HandBack: refusing to renounce ADMIN: the set is not complete (",
                vm.toString(wiring.length),
                " wiring, ",
                vm.toString(holders.length),
                " holder grant(s), ",
                vm.toString(tree.length),
                " role-tree call(s) pending). Re-run DeployV8.s.sol (V2_DEFER_HANDBACK=true, --resume) first."
            )
        );
        _ok("the set is complete: nothing but the hand-back is pending");
    }

}
