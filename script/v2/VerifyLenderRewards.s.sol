// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RewardsDistributor} from "../../src/v2/mm/RewardsDistributor.sol";
import {BytecodeCheck} from "../lib/BytecodeCheck.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @notice Read-only post-deploy check of the LENDER `RewardsDistributor` (P8-05): the token it pays, its
///         decimals, its treasury, its authority, who holds power over it, its selector map, that the epoch about
///         to be posted is still empty, and its runtime bytecode. No RPC writes, no broadcast.
///
///           V2_LENDER_REWARDS=0x... V2_STONKHOUSE_TOKEN=0x... V2_ACCESS_MANAGER=0x... V2_TREASURY_SAFE=0x... \
///             V2_ADMIN_SAFE=0x... V2_LENDER_EPOCH=2960 \
///             forge script script/v2/VerifyLenderRewards.s.sol --rpc-url "$RH_RPC"
///
/// @dev IT VERIFIES ONE INSTANCE AND NOTHING ELSE. `VerifyV8.s.sol` covers the core sixteen and is untouched by
///      P8-05. The two do not share state; this one is pointed at an address the core deploy never produced.
///
///      EVERY EXPECTATION IS READ, NEVER TYPED. The three selectors and their role come from
///      `script/v2/roles.v8.json` `.targets.RewardsDistributorLender`; the role id and its execution delay come
///      from the same file's `.roles` and `.delaysS` (mirrored in `src/v2/access/V8Roles.sol:57` and `:95`); the
///      runtime comes from this checkout's `out/` artifact. Nothing below hard-codes a selector, a role id or a
///      delay, so a manifest change moves this verifier with it rather than past it.
///
///      WHAT A SCRIPT CANNOT ANSWER, stated rather than faked -- the same bound `VerifyV8.s.sol:757-764` records.
///      `AccessManager` does not enumerate role members: there is no `getRoleMembers`, only
///      `hasRole(uint64,address)`. So "no EOA holds power over the lender instance" is checked in the form a script
///      CAN answer: the manifest's TREASURY_ADMIN holder holds it, at the manifest delay, and is a CONTRACT; and
///      none of the deployer or the four bot keys holds any role in 0..6. An address nobody named could still hold
///      the role, and only the indexer reading `RoleGranted` logs can rule that out.
///
///      {check} IS PUBLIC AND RETURNS ITS COUNTS so the suite can drive it against a deliberately broken world --
///      a 6-decimal token, an EOA holding TREASURY_ADMIN -- and assert the exact FAIL line, which is the only way
///      a fail-closed check is ever shown to close.
contract VerifyLenderRewards is BytecodeCheck, V2DeployBase {
    /// @dev The manifest target the lender instance's rows live under.
    string internal constant TARGET = "RewardsDistributorLender";

    /// @dev Roles 0..6 carry an execution delay; a plain key must hold none of them. Mirrors
    ///      `VerifyV8.s.sol:1040`.
    uint64 internal constant DELAYED_ROLE_MAX = 6;

    uint8 internal constant WANT_DECIMALS = 18;

    uint256 internal failures;
    uint256 internal passes;

    /// @param lender The deployed lender `RewardsDistributor`.
    /// @param token The $STONKHOUSE token it must pay.
    /// @param manager The v8 `AccessManager`.
    /// @param treasury The Treasury Safe, the only address `defund` can pay.
    /// @param epoch The epoch about to be posted: it must still have no root.
    /// @param adminSafe The manifest's TREASURY_ADMIN holder.
    /// @param keys The deployer and the bot keys, none of which may hold a delayed role. Zeros are skipped.
    struct Inputs {
        address lender;
        IERC20 token;
        address manager;
        address treasury;
        uint256 epoch;
        address adminSafe;
        address[] keys;
    }

    function run() external {
        (uint256 passed, uint256 failed) = check(inputsFromEnv());
        console2.log("");
        if (failed != 0) {
            console2.log(
                string.concat(
                    "VERIFY FAILED: ", vm.toString(failed), " check(s) failed of ", vm.toString(passed + failed)
                )
            );
            revert("verify failed");
        }
        console2.log(string.concat("VERIFY PASSED: ", vm.toString(passed), " checks"));
    }

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.lender = vm.envAddress("V2_LENDER_REWARDS");
        in_.token = IERC20(vm.envAddress("V2_STONKHOUSE_TOKEN"));
        in_.manager = vm.envAddress("V2_ACCESS_MANAGER");
        in_.treasury = vm.envAddress("V2_TREASURY_SAFE");
        in_.epoch = vm.envUint("V2_LENDER_EPOCH");
        in_.adminSafe = vm.envAddress("V2_ADMIN_SAFE");

        address[5] memory raw = [
            vm.envOr("V2_DEPLOYER", address(0)),
            vm.envOr("V2_GUARDIAN", address(0)),
            vm.envOr("V2_PRICER", address(0)),
            vm.envOr("V2_MM_QUOTER", address(0)),
            vm.envOr("V2_CRANKER", address(0))
        ];
        in_.keys = new address[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            in_.keys[i] = raw[i];
        }
    }

    /*//////////////////////////////////////////////////////////////
                                CHECKS
    //////////////////////////////////////////////////////////////*/

    function check(Inputs memory in_) public returns (uint256, uint256) {
        failures = 0;
        passes = 0;

        console2.log("lender RewardsDistributor", in_.lender);
        // Nothing below can be read off an address with no code, so the run stops here rather than printing a
        // column of failures that all have the same one cause.
        if (!_check(in_.lender != address(0) && in_.lender.code.length != 0, "the lender instance has code")) {
            return (passes, failures);
        }

        _token(in_);
        _wiring(in_);
        _power(in_);
        _map(in_);
        _epoch(in_);
        _bytecode(in_);
        return (passes, failures);
    }

    /// @dev 1. THE TOKEN. An 18-decimal token, and the one the instance actually holds.
    function _token(Inputs memory in_) internal {
        RewardsDistributor lender = RewardsDistributor(in_.lender);
        _check(address(lender.usdg()) == address(in_.token), "usdg() is the STONKHOUSE token this run was given");

        // Read off the token, not off the environment: this is the check that catches a lender instance pointed at
        // 6-decimal USDG, which would pay a millionth of every reward and revert nothing while doing it.
        uint8 d = IERC20Metadata(address(in_.token)).decimals();
        _check(
            d == WANT_DECIMALS,
            string.concat("the reward token reports 18 decimals (it reports ", vm.toString(uint256(d)), ")")
        );
    }

    /// @dev 2. WIRING. Treasury and authority.
    function _wiring(Inputs memory in_) internal {
        RewardsDistributor lender = RewardsDistributor(in_.lender);
        _check(lender.treasury() == in_.treasury, "treasury() is the Treasury Safe");
        _check(in_.treasury.code.length != 0, "the treasury is a contract, not a plain key");
        _check(lender.authority() == in_.manager, "authority() is the v8 AccessManager");
    }

    /// @dev 3. POWER. Who may call the three restricted selectors, in the form a script can answer.
    function _power(Inputs memory in_) internal {
        string memory json = rolesJson();
        AccessManager mgr = AccessManager(in_.manager);
        uint64 id = roleIdOf(json, "TREASURY_ADMIN");
        uint32 wantDelay = roleDelayOf(json, "TREASURY_ADMIN");

        (bool isMember, uint32 delay) = mgr.hasRole(id, in_.adminSafe);
        _check(isMember, "the manifest's TREASURY_ADMIN holder holds TREASURY_ADMIN");
        _check(
            delay == wantDelay,
            string.concat("TREASURY_ADMIN is held at the manifest delay of ", vm.toString(uint256(wantDelay)), " s")
        );
        _check(in_.adminSafe.code.length != 0, "the TREASURY_ADMIN holder is a contract, not a plain key");

        bool clean = true;
        for (uint256 k; k < in_.keys.length; ++k) {
            if (in_.keys[k] == address(0)) continue;
            for (uint64 r; r <= DELAYED_ROLE_MAX; ++r) {
                (bool holds,) = mgr.hasRole(r, in_.keys[k]);
                if (holds) {
                    clean = false;
                    _info(
                        string.concat(
                            vm.toString(in_.keys[k]), " holds role ", vm.toString(uint256(r)), ", a delayed lane"
                        )
                    );
                }
            }
        }
        _check(clean, "no deployer or bot key holds a role in 0..6");
    }

    /// @dev 4. THE SELECTOR MAP, on THIS address. A row mapped on the core instance and not on the lender one is
    ///      the whole failure mode: the call would fall through to ADMIN by AccessManager's default.
    function _map(Inputs memory in_) internal {
        string memory json = rolesJson();
        AccessManager mgr = AccessManager(in_.manager);
        string[] memory sigs = targetSigs(json, TARGET);
        _check(sigs.length != 0, string.concat("roles.v8.json lists selectors under .targets.", TARGET));

        bool mapped = true;
        for (uint256 i; i < sigs.length; ++i) {
            uint64 want = roleIdOf(json, roleNameOfSig(json, TARGET, sigs[i]));
            uint64 got = mgr.getTargetFunctionRole(in_.lender, selectorOf(sigs[i]));
            if (got != want) {
                mapped = false;
                _info(
                    string.concat(
                        sigs[i],
                        " is mapped to role ",
                        vm.toString(uint256(got)),
                        " on the lender instance, manifest says ",
                        vm.toString(uint256(want))
                    )
                );
            }
        }
        _check(mapped, "every lender selector is mapped to its manifest role on this address");
        _check(!mgr.isTargetClosed(in_.lender), "the lender instance is not a closed target");
        _check(mgr.getTargetAdminDelay(in_.lender) == 0, "the lender instance carries no target admin delay");
    }

    /// @dev 5. THE EPOCH ABOUT TO BE POSTED IS EMPTY. A root can never be replaced
    ///      (`RewardsDistributor.sol:96`, `AlreadyFinal`), so posting into an epoch that already has one is
    ///      unrecoverable: the values would have to be republished under a new epoch id.
    function _epoch(Inputs memory in_) internal {
        _check(
            RewardsDistributor(in_.lender).root(in_.epoch) == bytes32(0),
            string.concat("epoch ", vm.toString(in_.epoch), " has no root yet")
        );
    }

    /// @dev 6. BYTECODE. The lender instance is the SAME contract as the core one, so it is checked against the
    ///      same artifact; only its immutables (the reward token) differ, and those are masked here and proven
    ///      through `usdg()` above.
    function _bytecode(Inputs memory in_) internal {
        _check(
            runtimeMatches(in_.lender, ART_REWARDS_DISTRIBUTOR),
            "the lender runtime equals this checkout's RewardsDistributor artifact outside its immutables"
        );
    }

    /// @notice `target`'s runtime equals the artifact at `path` byte for byte outside the immutable slots the
    ///         artifact records. Mirrors `VerifyV8.s.sol:315-321`; it is repeated rather than shared because
    ///         P8-05 may not edit that file.
    function runtimeMatches(address target, string memory path) public view returns (bool) {
        string memory json = vm.readFile(path);
        bytes memory want = _artifactRuntime(json);
        bool[] memory mask = new bool[](want.length);
        if (vm.keyExistsJson(json, ".deployedBytecode.immutableReferences")) _maskImmutables(json, mask);
        return _equalMasked(target.code, want, mask);
    }

    /*//////////////////////////////////////////////////////////////
                                OUTPUT
    //////////////////////////////////////////////////////////////*/

    /// @dev Two spaces after `FAIL`, as `VerifyV8.s.sol` prints it, so one grep finds a failure in either log.
    function _check(bool ok, string memory what) internal returns (bool) {
        if (ok) {
            ++passes;
            console2.log(string.concat("  ok    ", what));
        } else {
            ++failures;
            console2.log(string.concat("  FAIL  ", what));
        }
        return ok;
    }

    function _info(string memory what) internal pure {
        console2.log(string.concat("  info  ", what));
    }
}
