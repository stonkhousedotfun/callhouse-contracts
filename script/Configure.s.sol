// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {PolicyParams} from "../src/Policy.sol";

/// @notice Grants the operating roles (and, if asked, re-applies a policy) on a deployed vault.
/// @dev Two modes, chosen by whether ADMIN_PK is set:
///
///        1. KEY ADMIN (bootstrap — the launch plan for now). The vault was deployed with `ADMIN` = the
///           deployer's address, so the grants are broadcast from that key:
///             ADMIN_PK=... forge script script/Configure.s.sol --rpc-url $RH_RPC --broadcast
///           Refuses if ADMIN_PK does not hold DEFAULT_ADMIN_ROLE.
///        2. SAFE BATCH. No key: writes a Safe{Wallet} Transaction Builder batch to SAFE_BATCH_OUT
///           (default `broadcast/configure-safe-batch.json`) for the admin Safe to import, decode, sign
///           and execute. Nothing is broadcast. Used once the Safe holds the admin role.
///
///      The batch file is written in both modes, so the calls a key broadcast and the calls a Safe
///      would sign are the same bytes. Executing a batch through a Safe with owner KEYS is a rehearsal
///      concern only and lives in `script/rehearsal/ExecuteSafeBatch.s.sol`, which refuses to run
///      anywhere but an anvil node. Production Safe owners sign in Safe{Wallet} on hardware.
contract ConfigureVault is Script {
    struct Call {
        address to;
        bytes data;
        string what;
    }

    function run() external {
        Vault vault = Vault(vm.envAddress("VAULT"));
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");
        require(keeper != address(0) && guardian != address(0), "KEEPER and GUARDIAN must be set");
        require(keeper != guardian, "keeper and guardian must be different keys");

        Call[] memory calls = _buildCalls(vault, keeper, guardian);
        _writeSafeBatch(vault, calls);

        uint256 adminPk = vm.envOr("ADMIN_PK", uint256(0));
        if (adminPk != 0) {
            _executeAsKeyAdmin(vault, adminPk, calls);
        } else {
            console2.log("");
            console2.log("NOTHING BROADCAST. Import the batch into Safe{Wallet} Transaction Builder on the admin");
            console2.log("Safe, decode and compare every call (docs/DEPLOY.md), sign, execute. Then run Verify.s.sol.");
        }
    }

    function _buildCalls(Vault vault, address keeper, address guardian) internal view returns (Call[] memory calls) {
        bool setPolicy = vm.envOr("SET_POLICY", false);
        calls = new Call[](setPolicy ? 3 : 2);

        calls[0] = Call({
            to: address(vault),
            data: abi.encodeCall(vault.grantRole, (vault.KEEPER_ROLE(), keeper)),
            what: "grantRole(KEEPER_ROLE, keeper)"
        });
        calls[1] = Call({
            to: address(vault),
            data: abi.encodeCall(vault.grantRole, (vault.GUARDIAN_ROLE(), guardian)),
            what: "grantRole(GUARDIAN_ROLE, guardian)"
        });

        // The constructor already installs Policy.launchDefaults(); set it again only if an override
        // is supplied, so a routine configure run does not silently change policy.
        if (setPolicy) {
            PolicyParams memory p = PolicyParams({
                minOtmBps: uint16(vm.envOr("MIN_OTM_BPS", uint256(300))),
                maxOtmBps: uint16(vm.envOr("MAX_OTM_BPS", uint256(1200))),
                minPremiumBps: uint16(vm.envOr("MIN_PREMIUM_BPS", uint256(40))),
                maxUtilizationBps: uint16(vm.envOr("MAX_UTILIZATION_BPS", uint256(9500))),
                protocolFeeBps: uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(500))),
                maxContractsCap: uint64(vm.envOr("MAX_CONTRACTS_CAP", uint256(50)))
            });
            calls[2] = Call({to: address(vault), data: abi.encodeCall(vault.setPolicy, (p)), what: "setPolicy(...)"});
        }

        console2.log("vault    ", address(vault));
        console2.log("keeper   ", keeper);
        console2.log("guardian ", guardian);
        for (uint256 i; i < calls.length; i++) {
            console2.log(string.concat("call ", vm.toString(i), ": ", calls[i].what));
            console2.logBytes(calls[i].data);
        }
    }

    /// @dev Safe{Wallet} Transaction Builder batch format (version 1.0). No `checksum` field: the app
    ///      accepts a batch without one and shows a warning, which is the honest state for a file a
    ///      script generated. Every call is a zero-value call to the vault.
    function _writeSafeBatch(Vault vault, Call[] memory calls) internal {
        address safe = vm.envOr("SAFE_ADMIN", address(0));
        string memory txs = "";
        for (uint256 i; i < calls.length; i++) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Callhouse: configure vault roles","description":"grantRole KEEPER_ROLE and GUARDIAN_ROLE on vault ',
            vm.toString(address(vault)),
            '","createdFromSafeAddress":"',
            vm.toString(safe),
            '"},"transactions":[',
            txs,
            "]}"
        );
        string memory out = vm.envOr("SAFE_BATCH_OUT", string("broadcast/configure-safe-batch.json"));
        vm.createDir("broadcast", true);
        vm.writeFile(out, json);
        console2.log("safe batch written:", out);
    }

    function _executeAsKeyAdmin(Vault vault, uint256 pk, Call[] memory calls) internal {
        address admin = vm.addr(pk);
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE");
        vm.startBroadcast(pk);
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = calls[i].to.call(calls[i].data);
            require(ok, string.concat("admin call reverted: ", calls[i].what));
        }
        vm.stopBroadcast();
        console2.log("key admin executed", calls.length, "calls from", admin);
    }
}
