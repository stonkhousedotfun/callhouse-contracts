// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

interface ISafeExec {
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

/// @notice REHEARSAL ONLY. Executes a Safe{Wallet} Transaction Builder batch file through a real Safe,
///         signing with owner private keys. It exists so a fork rehearsal proves the exact file a Safe
///         would import, byte for byte.
/// @dev Refuses to run unless the node answers `web3_clientVersion` with an anvil version string, so it
///      cannot be pointed at a public network even by mistake. Production Safe owners never hand keys
///      to a script; they sign in Safe{Wallet} on hardware.
///
///      BATCH (path to the JSON), SAFE (the Safe), SAFE_OWNER_PKS (comma-separated, at least threshold).
contract ExecuteSafeBatch is Script {
    uint8 internal constant CALL = 0;

    function run() external {
        _requireAnvil();

        ISafeExec safe = ISafeExec(vm.envAddress("SAFE"));
        string memory json = vm.readFile(vm.envString("BATCH"));
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "batch chainId != this chain");

        uint256 threshold = safe.getThreshold();
        uint256[] memory signers = _signers(safe, vm.envUint("SAFE_OWNER_PKS", ","), threshold);

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(n), "]"))) {
            n++;
        }
        require(n > 0, "batch has no transactions");

        vm.startBroadcast(signers[0]);
        for (uint256 i; i < n; i++) {
            string memory base = string.concat(".transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(json, string.concat(base, ".to"));
            uint256 value = vm.parseUint(vm.parseJsonString(json, string.concat(base, ".value")));
            bytes memory data = vm.parseJsonBytes(json, string.concat(base, ".data"));

            bytes32 h = safe.getTransactionHash(to, value, data, CALL, 0, 0, 0, address(0), address(0), safe.nonce());
            bytes memory sigs;
            for (uint256 j; j < signers.length; j++) {
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(signers[j], h);
                sigs = abi.encodePacked(sigs, r, s, v);
            }
            require(
                safe.execTransaction(to, value, data, CALL, 0, 0, 0, address(0), payable(0), sigs),
                "Safe execTransaction failed"
            );
        }
        vm.stopBroadcast();
        console2.log("REHEARSAL: executed", n, "batch transaction(s) through Safe", address(safe));
        console2.log("signers (threshold):", threshold);
    }

    /// @dev The node must identify itself as anvil. `vm.rpc` returns a string result as its raw bytes.
    function _requireAnvil() internal {
        bytes memory version = vm.rpc("web3_clientVersion", "[]");
        bytes memory prefix = bytes("anvil/");
        bool isAnvil = version.length >= prefix.length;
        for (uint256 i; isAnvil && i < prefix.length; i++) {
            if (version[i] != prefix[i]) isAnvil = false;
        }
        require(isAnvil, "ExecuteSafeBatch runs on an anvil node only");
    }

    /// @dev Safe requires signatures ordered by strictly increasing owner address.
    function _signers(ISafeExec safe, uint256[] memory pks, uint256 n) internal view returns (uint256[] memory out) {
        require(pks.length >= n, "fewer SAFE_OWNER_PKS than the Safe threshold");
        address[] memory owners = safe.getOwners();
        out = new uint256[](n);
        for (uint256 i; i < n; i++) {
            bool isOwner;
            for (uint256 k; k < owners.length; k++) {
                if (owners[k] == vm.addr(pks[i])) isOwner = true;
            }
            require(isOwner, "a SAFE_OWNER_PKS key is not an owner of SAFE");
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
