// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {Policy, PolicyParams} from "../src/Policy.sol";

interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

/// @notice Read-only post-deploy check of a Callhouse vault. Broadcasts nothing; reverts on the first
///         thing that is not what launch requires.
/// @dev Run after `Deploy.s.sol` and after the admin Safe has executed the `Configure.s.sol` batch:
///        forge script script/Verify.s.sol --rpc-url $RH_RPC
///      Every expectation is an environment variable so the same script checks a fork rehearsal, a
///      testnet deploy and mainnet. Mainnet defaults are the constants `Deploy.s.sol` uses.
///
///      Required: VAULT, SAFE_ADMIN, SAFE_FEE, KEEPER, GUARDIAN, DEPLOYER (the address that sent the
///      deploy transaction; it must hold no role at all).
///      Optional: SEAPORT_ORDER_LIB, VALOREM_LIB (checked to have code and to be linked into the vault
///      runtime), EXPECT_SAFE_THRESHOLD (default 2), EXPECT_SAFE_OWNERS (default 3),
///      EXPECT_KEEPER_CONFIGURED (default true; set false to check a vault before the Safe batch ran),
///      plus the same address overrides `Deploy.s.sol` accepts (ASSET, USDG, CLEARINGHOUSE, SEAPORT,
///      REGISTRY, PRICE_FEED, DEPOSIT_CAP).
contract VerifyVault is Script {
    uint256 internal failures;

    function run() external {
        Vault vault = Vault(vm.envAddress("VAULT"));
        require(address(vault).code.length > 0, "VAULT has no code");

        _immutables(vault);
        _parameters(vault);
        _roles(vault);
        _safe(vm.envAddress("SAFE_ADMIN"));
        _libraries(vault);
        _freshState(vault);

        console2.log("");
        if (failures != 0) {
            console2.log("VERIFY FAILED:", failures, "check(s)");
            revert("verify failed");
        }
        console2.log("VERIFY PASSED");
    }

    function _check(bool ok, string memory what) internal {
        if (ok) {
            console2.log(string.concat("  ok    ", what));
        } else {
            failures++;
            console2.log(string.concat("  FAIL  ", what));
        }
    }

    function _immutables(Vault vault) internal {
        console2.log("immutables");
        _check(address(vault.asset()) == vm.envOr("ASSET", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), "asset");
        _check(address(vault.usdg()) == vm.envOr("USDG", 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168), "usdg");
        _check(
            address(vault.clear()) == vm.envOr("CLEARINGHOUSE", 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0),
            "clearinghouse"
        );
        _check(address(vault.seaport()) == vm.envOr("SEAPORT", 0x0000000000000068F116a894984e2DB1123eB395), "seaport");
        _check(
            address(vault.registry()) == vm.envOr("REGISTRY", 0x8E973cE1A6884E28Ad3E377d5f670Bc0b463f4EA),
            "registry is the NVDA market, not JUGGERNAUT"
        );
        _check(
            address(vault.priceFeed()) == vm.envOr("PRICE_FEED", 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15),
            "price feed"
        );
    }

    function _parameters(Vault vault) internal {
        console2.log("parameters");
        (uint16 minOtm, uint16 maxOtm, uint16 minPrem, uint16 maxUtil, uint16 feeBps, uint64 cap) = vault.policy();
        PolicyParams memory want = Policy.launchDefaults();
        _check(
            minOtm == want.minOtmBps && maxOtm == want.maxOtmBps && minPrem == want.minPremiumBps
                && maxUtil == want.maxUtilizationBps && cap == want.maxContractsCap,
            "policy bands, utilisation and contract cap == launchDefaults"
        );
        _check(feeBps == 500, "protocolFeeBps == 500 (5% of premium)");
        _check(vault.depositCap() == vm.envOr("DEPOSIT_CAP", uint256(20e18)), "depositCap == 20 NVDA");
        _check(vault.maxPriceAge() == 4 days, "maxPriceAge == 4 days");
        _check(vault.feeRecipient() == vm.envAddress("SAFE_FEE"), "feeRecipient == SAFE_FEE");
    }

    function _roles(Vault vault) internal {
        console2.log("roles");
        bytes32 admin = vault.DEFAULT_ADMIN_ROLE();
        bytes32 keeperRole = vault.KEEPER_ROLE();
        bytes32 guardianRole = vault.GUARDIAN_ROLE();
        address safe = vm.envAddress("SAFE_ADMIN");
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");
        address deployer = vm.envAddress("DEPLOYER");
        bool configured = vm.envOr("EXPECT_KEEPER_CONFIGURED", true);

        _check(vault.hasRole(admin, safe), "SAFE_ADMIN holds DEFAULT_ADMIN_ROLE");
        _check(safe.code.length > 0, "SAFE_ADMIN is a contract, not a key");
        _check(
            !vault.hasRole(admin, deployer) && !vault.hasRole(keeperRole, deployer)
                && !vault.hasRole(guardianRole, deployer),
            "DEPLOYER holds no role"
        );
        _check(
            vault.hasRole(keeperRole, keeper) == configured,
            configured ? "KEEPER holds KEEPER_ROLE" : "KEEPER does not hold KEEPER_ROLE yet (unconfigured)"
        );
        _check(
            vault.hasRole(guardianRole, guardian) == configured,
            configured ? "GUARDIAN holds GUARDIAN_ROLE" : "GUARDIAN does not hold GUARDIAN_ROLE yet (unconfigured)"
        );
        _check(!vault.hasRole(admin, keeper) && !vault.hasRole(guardianRole, keeper), "keeper holds nothing else");
        _check(!vault.hasRole(admin, guardian) && !vault.hasRole(keeperRole, guardian), "guardian holds nothing else");
        _check(vault.getRoleAdmin(keeperRole) == admin && vault.getRoleAdmin(guardianRole) == admin, "role admins");
    }

    function _safe(address safe) internal {
        console2.log("admin safe");
        if (safe.code.length == 0) return;
        _check(ISafeView(safe).getThreshold() == vm.envOr("EXPECT_SAFE_THRESHOLD", uint256(2)), "Safe threshold");
        _check(ISafeView(safe).getOwners().length == vm.envOr("EXPECT_SAFE_OWNERS", uint256(3)), "Safe owner count");
    }

    /// @dev A public library is reached by DELEGATECALL to an address PUSH20'd into the caller's
    ///      runtime, so a linked vault contains each library address verbatim.
    function _libraries(Vault vault) internal {
        console2.log("linked libraries");
        address sol = vm.envOr("SEAPORT_ORDER_LIB", address(0));
        address vl = vm.envOr("VALOREM_LIB", address(0));
        if (sol == address(0) && vl == address(0)) {
            console2.log("  skip  SEAPORT_ORDER_LIB / VALOREM_LIB not given");
            return;
        }
        bytes memory code = address(vault).code;
        _check(sol.code.length > 0 && _contains(code, sol), "SeaportOrderLib has code and is linked into the vault");
        _check(vl.code.length > 0 && _contains(code, vl), "ValoremLib has code and is linked into the vault");
    }

    function _freshState(Vault vault) internal {
        console2.log("fresh state");
        _check(uint8(vault.phase()) == 0, "phase Idle");
        _check(!vault.writesHalted(), "writes not halted");
        _check(!vault.valoremFeeAccepted(), "Valorem engine fee not accepted");
        _check(vault.cycleNumber() == 0 && vault.contractsWritten() == 0, "no cycle opened");
    }

    function _contains(bytes memory hay, address needle) internal pure returns (bool) {
        bytes20 n = bytes20(needle);
        if (hay.length < 20) return false;
        for (uint256 i; i <= hay.length - 20; i++) {
            bytes20 w;
            assembly {
                w := mload(add(add(hay, 32), i))
            }
            if (w == n) return true;
        }
        return false;
    }
}
