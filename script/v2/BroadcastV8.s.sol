// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

/// @title  BroadcastV8 -- the deployment fingerprint the launch driver binds VerifyV8's pass to.
/// @notice OWN8-03. `broadcast-v8.sh` must refuse to register markets unless `VerifyV8` passed IN THIS RUN
///         AGAINST THIS DEPLOYMENT. "This deployment" has to be a value the driver can compare, not a claim it
///         makes about itself, or the gate is a check that cannot see its subject.
///
/// @dev    THIS SCRIPT NEVER SENDS A TRANSACTION. There is no `vm.startBroadcast` in this file and no state-
///         changing call; `grep -n startBroadcast script/v2/BroadcastV8.s.sol` returning nothing is part of the
///         contract this file offers, and `broadcast-v8.sh` asserts exactly that before it runs it.
///
///         THE FINGERPRINT IS OVER CODE, NOT OVER ADDRESSES. `keccak256(abi.encode(chainid, addrs, codehashes))`.
///         Addresses alone would still match after a `selfdestruct`-and-redeploy or an upgrade behind a proxy, and
///         the whole point is to notice that the thing VerifyV8 passed against is the thing being registered into.
///
///         EVERY FAILURE MODE HERE IS A REVERT, INCLUDING ABSENCE. An empty address list, an address with no code,
///         a list shorter than `V8_MIN_CONTRACTS`, and a missing `V8_EXPECT_FINGERPRINT` in {assertFingerprint}
///         all revert. That is deliberate: the dominant defect in this build is a check that passes because its
///         subject is not there, and a fingerprint over zero addresses is the purest example of one -- it would
///         hash happily and match itself for ever.
contract BroadcastV8 is Script {
    /// @dev A FLOOR, not the set size. The authoritative count is `CONTRACT_KEYS` in `broadcast-v8.sh`, which
    ///      DERIVES it from the list the way `DeployV2Batch.sh:130` does, and passes it in `V8_MIN_CONTRACTS`;
    ///      that list holds 16 today. This constant only catches the case where nothing was passed at all.
    ///      It is deliberately NOT the real number: a literal here would be a second copy of the set size that
    ///      can drift from the list, and it drifts silently DOWNWARD -- a digest over fewer contracts than the
    ///      deployment has still hashes, still matches itself, and promises less than it appears to.
    uint256 internal constant DEFAULT_MIN_CONTRACTS = 2;

    /// @notice Print the fingerprint of the addresses in `V8_FINGERPRINT_ADDRS` at the current block.
    function run() external view {
        (bytes32 fp, address[] memory addrs) = fingerprint();
        console2.log("BROADCASTV8 CHAIN", block.chainid);
        for (uint256 i = 0; i < addrs.length; i++) {
            console2.log(string.concat("  ", vm.toString(addrs[i]), "  ", vm.toString(addrs[i].codehash)));
        }
        console2.log(string.concat("BROADCASTV8 FINGERPRINT ", vm.toString(fp)));
    }

    /// @notice Revert unless the chain still matches `V8_EXPECT_FINGERPRINT`.
    /// @dev    THE ABSENT CASE REVERTS. `vm.envBytes32` throws when the variable is unset, and that is the
    ///         behaviour this gate needs: a driver that forgot to pass the expected value must fail, not pass.
    ///         Do not "improve" this to `envOr(..., bytes32(0))` -- a zero default turns the gate into a
    ///         formality that agrees with anything a caller neglected to supply.
    ///
    ///         T-565 CHECKED THE DOUBT ABOVE AND THE ANSWER IS: THE GATE HOLDS EITHER WAY. The T-192
    ///         ledger suspicion worried that `vm.envBytes32` was assumed rather than verified, and that
    ///         if it RETURNED ZERO instead of throwing, the `require` below would be "the only thing
    ///         standing between this gate and a formality". It is that thing, and it is enough: the
    ///         require is unconditional and sits immediately after the call, so an absent
    ///         `V8_EXPECT_FINGERPRINT` cannot produce a passing gate whichever way the cheatcode
    ///         behaves. The fail-closed property therefore does NOT rest on the cheatcode, which is why
    ///         no run was spent measuring it. What is still unmeasured: whether `vm.envBytes32` actually
    ///         throws on this forge version. It does not matter here; it would matter to any NEW caller
    ///         that omits a backstop like the one below.
    function assertFingerprint() external view {
        bytes32 want = vm.envBytes32("V8_EXPECT_FINGERPRINT");
        require(want != bytes32(0), "BroadcastV8: V8_EXPECT_FINGERPRINT is zero, which is not a fingerprint");
        (bytes32 got,) = fingerprint();
        if (got != want) {
            console2.log(string.concat("BROADCASTV8 EXPECTED ", vm.toString(want)));
            console2.log(string.concat("BROADCASTV8 ACTUAL   ", vm.toString(got)));
            revert("BroadcastV8: the deployment changed since it was verified");
        }
        console2.log(string.concat("BROADCASTV8 FINGERPRINT MATCHES ", vm.toString(got)));
    }

    /// @notice `keccak256(abi.encode(chainid, addrs, codehashes))` over `V8_FINGERPRINT_ADDRS`.
    /// @dev    Reverts rather than returning a weak digest: no addresses, too few addresses, or any address
    ///         without code. An EOA or an undeployed address in this list is the failure the fingerprint exists
    ///         to catch, so it can never be folded into one.
    function fingerprint() public view returns (bytes32, address[] memory) {
        address[] memory addrs = vm.envAddress("V8_FINGERPRINT_ADDRS", ",");
        uint256 min = vm.envOr("V8_MIN_CONTRACTS", DEFAULT_MIN_CONTRACTS);
        if (addrs.length < min) {
            revert(
                string.concat(
                    "BroadcastV8: V8_FINGERPRINT_ADDRS has ",
                    vm.toString(addrs.length),
                    " address(es), fewer than the ",
                    vm.toString(min),
                    " this deployment must have: a fingerprint over a partial set is not a fingerprint"
                )
            );
        }
        bytes32[] memory hashes = new bytes32[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i].code.length == 0) {
                revert(
                    string.concat(
                        "BroadcastV8: ", vm.toString(addrs[i]), " holds no code on chain ", vm.toString(block.chainid)
                    )
                );
            }
            hashes[i] = addrs[i].codehash;
        }
        return (keccak256(abi.encode(block.chainid, addrs, hashes)), addrs);
    }
}
