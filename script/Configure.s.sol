// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {PolicyParams} from "../src/Policy.sol";

/// @dev The slice of Safe 1.3.0 / 1.4.1 this script needs. Both versions are deployed on chain 4663
///      at their canonical addresses (SafeProxyFactory 1.4.1 `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`,
///      SafeL2 1.4.1 `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`), and Safe{Wallet} lists Robinhood Chain.
interface ISafeMinimal {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
}

/// @notice Grants the operating roles (and, if asked, re-applies a policy) on a deployed vault.
/// @dev WHY THIS SCRIPT HAS THREE MODES. `Deploy.s.sol` installs `DEFAULT_ADMIN_ROLE` on the admin
///      Safe from the constructor and on nobody else — the deployer never holds a role, so there is
///      nothing to renounce. The grants below therefore have to come FROM the Safe, and a Safe has no
///      private key for `forge script --broadcast` to sign with. An earlier version of this script
///      broadcast with `ADMIN_PK` while its NatSpec said "run as the admin Safe"; in production that
///      could never have worked. The 2026-09-13 fork rehearsal (docs/DEPLOY.md) is where it surfaced.
///
///      Mode is chosen by which variables are set:
///
///        1. SAFE BATCH (production). Only VAULT, KEEPER, GUARDIAN. Writes a Safe{Wallet} Transaction
///           Builder batch to SAFE_BATCH_OUT (default `broadcast/configure-safe-batch.json`). Import it
///           in the Transaction Builder app on the admin Safe, check every call against the printout,
///           collect the second signature, execute. Nothing is broadcast by this script.
///        2. EOA ADMIN (testnet). ADMIN_PK set: the vault's admin is a plain key, so the calls are
///           broadcast directly from it. Refuses if ADMIN_PK does not hold DEFAULT_ADMIN_ROLE.
///        3. SAFE REHEARSAL (fork only). REHEARSAL=true and SAFE_OWNER_PKS set (comma-separated owner
///           keys, at least the threshold): signs each call as a Safe transaction with those owners and
///           executes it through the real Safe contract, so a fork proves the exact calldata the
///           production batch carries. Never point this at mainnet with real owner keys: production
///           owners sign on hardware through Safe{Wallet}, which is mode 1.
///
///      The batch file is written in every mode, so what was rehearsed and what gets imported are the
///      same bytes.
contract ConfigureVault is Script {
    /// @dev Safe `Enum.Operation.Call`.
    uint8 internal constant CALL = 0;

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
        bool rehearsal = vm.envOr("REHEARSAL", false);

        if (adminPk != 0) {
            _executeAsEoaAdmin(vault, adminPk, calls);
        } else if (rehearsal) {
            _executeThroughSafe(vault, calls);
        } else {
            console2.log("");
            console2.log("NOTHING BROADCAST. Import the batch above into Safe{Wallet} Transaction Builder on the");
            console2.log("admin Safe, compare every call with the list printed here, sign, execute. Then run");
            console2.log("script/Verify.s.sol against the vault.");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 CALLS
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                              SAFE BATCH FILE
    //////////////////////////////////////////////////////////////*/

    /// @dev Safe{Wallet} Transaction Builder batch format (version 1.0). No `checksum` field: the app
    ///      accepts a batch without one and shows a warning, which is the honest state for a file a
    ///      script generated. Every call is a zero-value call to the vault.
    function _writeSafeBatch(Vault vault, Call[] memory calls) internal {
        address safe = _admin(vault);
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
        console2.log("admin (from env SAFE_ADMIN, else unchecked):", safe);
    }

    /// @dev The vault exposes no admin enumeration (AccessControl, not AccessControlEnumerable), so the
    ///      Safe address comes from SAFE_ADMIN and is CHECKED against `hasRole` before anything uses it.
    function _admin(Vault vault) internal view returns (address safe) {
        safe = vm.envOr("SAFE_ADMIN", address(0));
        if (safe != address(0)) {
            require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), safe), "SAFE_ADMIN does not hold DEFAULT_ADMIN_ROLE");
        }
    }

    /*//////////////////////////////////////////////////////////////
                               EXECUTION
    //////////////////////////////////////////////////////////////*/

    function _executeAsEoaAdmin(Vault vault, uint256 pk, Call[] memory calls) internal {
        address admin = vm.addr(pk);
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE");
        vm.startBroadcast(pk);
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = calls[i].to.call(calls[i].data);
            require(ok, string.concat("admin call reverted: ", calls[i].what));
        }
        vm.stopBroadcast();
        console2.log("EOA admin executed", calls.length, "calls from", admin);
    }

    function _executeThroughSafe(Vault vault, Call[] memory calls) internal {
        ISafeMinimal safe = ISafeMinimal(vm.envAddress("SAFE_ADMIN"));
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(safe)), "SAFE_ADMIN does not hold DEFAULT_ADMIN_ROLE");

        uint256[] memory pks = vm.envUint("SAFE_OWNER_PKS", ",");
        uint256 threshold = safe.getThreshold();
        require(pks.length >= threshold, "fewer SAFE_OWNER_PKS than the Safe threshold");
        uint256[] memory signers = _sortedByAddress(pks, threshold);

        vm.startBroadcast(signers[0]);
        for (uint256 i; i < calls.length; i++) {
            bytes32 h = safe.getTransactionHash(
                calls[i].to, 0, calls[i].data, CALL, 0, 0, 0, address(0), address(0), safe.nonce()
            );
            bytes memory sigs;
            for (uint256 j; j < signers.length; j++) {
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(signers[j], h);
                sigs = abi.encodePacked(sigs, r, s, v);
            }
            require(
                safe.execTransaction(calls[i].to, 0, calls[i].data, CALL, 0, 0, 0, address(0), payable(0), sigs),
                string.concat("Safe execTransaction failed: ", calls[i].what)
            );
        }
        vm.stopBroadcast();
        console2.log("REHEARSAL: executed", calls.length, "calls through Safe", address(safe));
        console2.log("signers (threshold):", threshold);
    }

    /// @dev Safe requires signatures ordered by strictly increasing owner address. Takes the first
    ///      `n` keys, checks each is an owner, and sorts them.
    function _sortedByAddress(uint256[] memory pks, uint256 n) internal view returns (uint256[] memory out) {
        ISafeMinimal safe = ISafeMinimal(vm.envAddress("SAFE_ADMIN"));
        address[] memory owners = safe.getOwners();
        out = new uint256[](n);
        for (uint256 i; i < n; i++) {
            bool isOwner;
            for (uint256 k; k < owners.length; k++) {
                if (owners[k] == vm.addr(pks[i])) isOwner = true;
            }
            require(isOwner, "a SAFE_OWNER_PKS key is not an owner of SAFE_ADMIN");
            out[i] = pks[i];
        }
        for (uint256 i = 1; i < n; i++) {
            uint256 key = out[i];
            uint256 j = i;
            while (j > 0 && vm.addr(out[j - 1]) > vm.addr(key)) {
                out[j] = out[j - 1];
                j--;
            }
            out[j] = key;
        }
    }
}
