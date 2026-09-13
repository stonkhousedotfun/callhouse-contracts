// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";

interface ISafeHandover {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}

/// @notice Moves DEFAULT_ADMIN_ROLE from the bootstrap key to the admin Safe, in two separate runs.
/// @dev The launch plan for now deploys with the deployer key as admin (docs/DEPLOY.md, "bootstrap").
///      Handing over is deliberately two steps with a Safe transaction in between, so the key is only
///      ever renounced after the Safe has PROVEN it can execute:
///
///        STEP=grant     ADMIN_PK grants DEFAULT_ADMIN_ROLE to SAFE_ADMIN. Refuses unless SAFE_ADMIN is
///                       a contract with threshold >= 2, at least as many owners, and no modules.
///                       Writes `broadcast/handover-safe-smoke-batch.json`: one harmless admin call
///                       (`setMaxPriceAge` to its current value) for the Safe to sign and execute.
///        (the Safe)     Import the smoke batch in Safe{Wallet}, sign with the threshold, execute.
///        STEP=renounce  ADMIN_PK renounces DEFAULT_ADMIN_ROLE. Refuses unless the Safe holds the
///                       role AND the Safe's nonce has moved past the value recorded at grant time
///                       (GRANT_NONCE, printed by the grant step), i.e. it executed a transaction
///                       after it became admin.
///
///      Both steps: ADMIN_PK, VAULT, SAFE_ADMIN; renounce also GRANT_NONCE.
///      After renounce, run Verify.s.sol with ADMIN_PHASE=safe.
contract HandoverAdmin is Script {
    address internal constant SAFE_SENTINEL = address(0x1);

    function run() external {
        Vault vault = Vault(vm.envAddress("VAULT"));
        ISafeHandover safe = ISafeHandover(vm.envAddress("SAFE_ADMIN"));
        uint256 pk = vm.envUint("ADMIN_PK");
        address key = vm.addr(pk);
        bytes32 admin = vault.DEFAULT_ADMIN_ROLE();
        string memory step = vm.envString("STEP");

        require(vault.hasRole(admin, key), "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE");
        require(address(safe).code.length > 0, "SAFE_ADMIN has no code: it must be a Safe, not a key");
        uint256 threshold = safe.getThreshold();
        require(threshold >= 2, "SAFE_ADMIN threshold is below 2");
        require(safe.getOwners().length >= threshold, "SAFE_ADMIN has fewer owners than its threshold");
        (address[] memory modules,) = safe.getModulesPaginated(SAFE_SENTINEL, 10);
        require(modules.length == 0, "SAFE_ADMIN has a module enabled: a module can act without signatures");

        if (keccak256(bytes(step)) == keccak256("grant")) {
            require(!vault.hasRole(admin, address(safe)), "SAFE_ADMIN already holds DEFAULT_ADMIN_ROLE");
            uint256 nonceAtGrant = safe.nonce();

            vm.startBroadcast(pk);
            vault.grantRole(admin, address(safe));
            vm.stopBroadcast();

            _writeSmokeBatch(vault, address(safe));
            console2.log("granted DEFAULT_ADMIN_ROLE to", address(safe));
            console2.log("GRANT_NONCE (pass to STEP=renounce):", nonceAtGrant);
            console2.log("NEXT: execute broadcast/handover-safe-smoke-batch.json through the Safe, then renounce.");
        } else if (keccak256(bytes(step)) == keccak256("renounce")) {
            require(vault.hasRole(admin, address(safe)), "SAFE_ADMIN does not hold DEFAULT_ADMIN_ROLE yet");
            uint256 grantNonce = vm.envUint("GRANT_NONCE");
            require(
                safe.nonce() > grantNonce,
                "the Safe has not executed a transaction since the grant: run the smoke batch"
            );

            vm.startBroadcast(pk);
            vault.renounceRole(admin, key);
            vm.stopBroadcast();

            require(!vault.hasRole(admin, key), "renounce did not take");
            console2.log("renounced DEFAULT_ADMIN_ROLE from", key);
            console2.log("NEXT: forge script script/Verify.s.sol with ADMIN_PHASE=safe");
        } else {
            revert("STEP must be grant or renounce");
        }
    }

    /// @dev One no-op admin call the Safe can execute to prove it works: re-set maxPriceAge to the value
    ///      it already has. Emits MaxPriceAgeUpdated, changes nothing.
    function _writeSmokeBatch(Vault vault, address safe) internal {
        bytes memory data = abi.encodeCall(vault.setMaxPriceAge, (vault.maxPriceAge()));
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Callhouse: admin handover smoke test","description":"setMaxPriceAge to its current value on vault ',
            vm.toString(address(vault)),
            '","createdFromSafeAddress":"',
            vm.toString(safe),
            '"},"transactions":[{"to":"',
            vm.toString(address(vault)),
            '","value":"0","data":"',
            vm.toString(data),
            '","contractMethod":null,"contractInputsValues":null}]}'
        );
        vm.createDir("broadcast", true);
        vm.writeFile("broadcast/handover-safe-smoke-batch.json", json);
        console2.log("smoke batch written: broadcast/handover-safe-smoke-batch.json");
    }
}
