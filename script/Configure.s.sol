// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {PolicyParams} from "../src/Policy.sol";

/// @notice Grants the operating roles and applies the launch policy.
/// @dev Run as the admin Safe. The deployer holds DEFAULT_ADMIN_ROLE only if it deployed with
///      itself as `admin`; in production the Safe is the admin from block one, so this script is
///      executed by the Safe.
contract ConfigureVault is Script {
    function run() external {
        uint256 pk = vm.envUint("ADMIN_PK");
        Vault vault = Vault(vm.envAddress("VAULT"));
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");

        vm.startBroadcast(pk);

        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);

        // The constructor already installs Policy.launchDefaults(); set it again only if an
        // override is supplied, so a routine configure run does not silently change policy.
        if (vm.envOr("SET_POLICY", false)) {
            vault.setPolicy(
                PolicyParams({
                    minOtmBps: uint16(vm.envOr("MIN_OTM_BPS", uint256(300))),
                    maxOtmBps: uint16(vm.envOr("MAX_OTM_BPS", uint256(1200))),
                    minPremiumBps: uint16(vm.envOr("MIN_PREMIUM_BPS", uint256(40))),
                    maxUtilizationBps: uint16(vm.envOr("MAX_UTILIZATION_BPS", uint256(9500))),
                    protocolFeeBps: uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(500))),
                    maxContractsCap: uint64(vm.envOr("MAX_CONTRACTS_CAP", uint256(50)))
                })
            );
        }

        vm.stopBroadcast();

        console2.log("keeper   ", keeper);
        console2.log("guardian ", guardian);
        console2.log("");
        console2.log("REMAINING MANUAL STEP: the deployer must renounce DEFAULT_ADMIN_ROLE once the");
        console2.log("Safe is confirmed to hold it. Verify with hasRole before renouncing, and never");
        console2.log("renounce from the only account that holds it.");
    }
}
