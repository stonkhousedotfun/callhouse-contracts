// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Prints the address of the private key in the environment variable named by KEY_ENV, and
///         nothing else. Read-only, no RPC, no broadcast.
/// @dev `cast wallet address` only accepts a key on argv (`--private-key`), which puts DEPLOYER_PK /
///      ADMIN_PK in the process table on a mainnet run. DeploySoloBatch.sh runs this instead so the
///      keys stay in the environment of the forge process, exactly as they do for the deploy itself.
contract KeyAddress is Script {
    function run() public view {
        console2.log(vm.addr(vm.envUint(vm.envString("KEY_ENV"))));
    }
}
