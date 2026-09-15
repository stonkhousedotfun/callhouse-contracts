// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {Policy, PolicyParams} from "../src/Policy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1155Minimal} from "../src/interfaces/IERC1155Minimal.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";
import {ISeaport, IZone} from "../src/interfaces/ISeaport.sol";

interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}

/// @notice Read-only post-deploy check of a Callhouse vault. Broadcasts nothing. Prints every check
///         and reverts at the end if any failed.
/// @dev Run from a checkout of the EXACT commit that was deployed, after `forge build`: the bytecode
///      check compares the chain against `out/`.
///        forge script script/Verify.s.sol --rpc-url $RH_RPC
///
///      WHAT IS CHECKED
///        1. Chain id.
///        2. Runtime bytecode of the vault and both libraries, byte for byte against this commit's
///           compiled artifacts. Only three kinds of byte are masked: the library link sites (each
///           checked separately to hold the expected library address), the immutable slots (each
///           checked separately through its getter), and a library's own deploy-address word
///           (checked to equal that library's address). A match proves the logic and every
///           compiled-in hard cap are this commit's — nothing a getter can show covers that.
///        3. Every immutable through its getter, the conduit key, the zone (which must be the vault
///           itself: write on fill), the ERC-1155 transfer-approval target, the approval itself on
///           Valorem, and the interfaces advertised (the 1.6 zone interface, no EIP-1271). Then the
///           dependencies the zone hooks rest on: `seaport.information()` reports version 1.6 and the
///           canonical ConduitController, the Seaport runtime extcodehash equals the vendored 4663
///           runtime, Clear's `feeBps` is 15 with the switch off (or accepted), and both tokens have
///           the decimals {Policy} assumes. When the vault is on a clearinghouse OTHER than Overcall's
///           (i.e. ours, from `DeployClear.s.sol`), who holds its fee switch: EXPECTED_CLEAR_FEE_TO is
///           required, Clear's runtime must be the vendored artifact byte for byte (which pins the
///           storage layout read next), `feeTo` must equal EXPECTED_CLEAR_FEE_TO and no `setFeeTo`
///           nomination may be pending. The owner's decision (2026-09-14) is that the admin Safe holds
///           it from deploy; `HandoverAdmin.s.sol` moves only the vault's role, never `feeTo`.
///        4. Policy, field by field, against `Policy.launchDefaults()`; deposit cap; price age;
///           fee recipient; share token name, symbol and decimals.
///        5. Roles, for the admin phase in ADMIN_PHASE:
///             bootstrap — the deployer key holds DEFAULT_ADMIN_ROLE (the launch plan for now);
///             safe      — the admin Safe holds it and the deployer holds no role at all.
///           In both: keeper and guardian hold exactly their one role, or none if unconfigured.
///        6. The admin Safe, when one is named: its singleton is a canonical Safe 1.3.0/1.4.1 build,
///           threshold and owner count, optionally the exact owner set, no modules (a module
///           bypasses signatures), no transaction guard, canonical fallback handler. The fee Safe
///           gets the same checks when it is a contract.
///        7. Fresh state (unless EXPECT_FRESH=false): Idle, not halted, Valorem fee not accepted, no
///           cycle, no listing, no claim, no shares, nothing reserved, owed, pending or accounted,
///           epoch 1, and no asset or USDG held.
///
///      ENVIRONMENT
///        Required: VAULT, SEAPORT_ORDER_LIB, VALOREM_LIB, SAFE_FEE, KEEPER, GUARDIAN, DEPLOYER.
///        ADMIN_PHASE   bootstrap | safe (default safe). SAFE_ADMIN is required for `safe`.
///        EXPECT_KEEPER_CONFIGURED  default true.  EXPECT_FRESH  default true.
///        EXPECT_SAFE_THRESHOLD     default 2.     EXPECT_SAFE_OWNERS default 3.
///        EXPECT_SAFE_OWNER_SET     optional comma-separated owner addresses, order free.
///        Address overrides as in Deploy.s.sol: ASSET, USDG, CLEARINGHOUSE, SEAPORT, PRICE_FEED,
///        DEPOSIT_CAP, VAULT_NAME, VAULT_SYMBOL, EXPECT_CHAIN_ID, EXPECT_SEAPORT_CODEHASH.
///        EXPECTED_CLEAR_FEE_TO     required when CLEARINGHOUSE is not Overcall's instance: the address
///                                  that must hold our Clear's fee switch (the admin Safe).
contract VerifyVault is Script {
    /// @dev Safe storage: slot 0 is the singleton; guard and fallback handler live at these hashed slots.
    bytes32 internal constant SAFE_GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant SAFE_FALLBACK_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    address internal constant SAFE_SENTINEL = address(0x1);

    /// @dev Canonical Safe singletons and the 1.4.1 fallback handler, all deployed on chain 4663.
    address internal constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_L2_130 = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;
    address internal constant FALLBACK_141 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    /// @dev keccak256 of the Seaport 1.6 runtime on chain 4663 (23,981 B; differs from Ethereum's only in
    ///      the immutable chainId and domain separator). Same constant as test/helpers/RealSeaportBase.sol,
    ///      which asserts it against the vendored fixture. Override with EXPECT_SEAPORT_CODEHASH on a chain
    ///      whose Seaport was compiled for another chain id.
    bytes32 internal constant SEAPORT_16_RUNTIME_HASH =
        0x95809b70c9659c30188db5fdd87103e24b1a55379af8c851fca393aba0224a00;

    /// @dev Overcall's Valorem Clear, Deploy.s.sol's default. Its `feeTo` is Overcall's key, not ours, so the
    ///      fee-switch-holder checks below apply only to any OTHER instance (ours, from DeployClear.s.sol).
    address internal constant OVERCALL_CLEAR = 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0;

    /// @dev The artifact DeployClear.s.sol deploys. It has no immutables, so a deployed instance's runtime
    ///      equals `deployedBytecode` byte for byte, and that equality is what makes the storage read below
    ///      a read of `pendingFeeTo` and not of something else.
    string internal constant CLEAR_ARTIFACT = "script/artifacts/ValoremOptionsClearinghouse.json";

    /// @dev Upstream `ValoremOptionsClearinghouse.sol` @ 6436c823 keeps `pendingFeeTo` private with no
    ///      getter. Layout after solmate ERC1155 (`balanceOf` slot 0, `isApprovedForAll` slot 1) and
    ///      `optionTypeStates` (slot 2): `pendingFeeTo` is the next address (slot 3). `setFeeTo(x)`
    ///      writes x alone there; `acceptFeeTo()` zeroes it. `feeTo` and `feesEnabled` pack into slot 5.
    uint256 internal constant CLEAR_PENDING_FEE_TO_SLOT = 3;

    struct Ref {
        uint256 length;
        uint256 start;
    }

    uint256 internal failures;
    uint256 internal passes;

    function run() external {
        Vault vault = Vault(vm.envAddress("VAULT"));
        address sol = vm.envAddress("SEAPORT_ORDER_LIB");
        address vl = vm.envAddress("VALOREM_LIB");

        console2.log("chain");
        _check(block.chainid == vm.envOr("EXPECT_CHAIN_ID", uint256(4663)), "chain id");
        require(address(vault).code.length > 0, "VAULT has no code");

        _bytecode(vault, sol, vl);
        _immutables(vault);
        _parameters(vault);
        _roles(vault);
        _safes();
        if (vm.envOr("EXPECT_FRESH", true)) _freshState(vault);

        console2.log("");
        if (failures != 0) {
            console2.log("VERIFY FAILED:", failures, "check(s) failed of", failures + passes);
            revert("verify failed");
        }
        console2.log("VERIFY PASSED:", passes, "checks");
    }

    function _check(bool ok, string memory what) internal {
        if (ok) {
            passes++;
            console2.log(string.concat("  ok    ", what));
        } else {
            failures++;
            console2.log(string.concat("  FAIL  ", what));
        }
    }

    /*//////////////////////////////////////////////////////////////
                               BYTECODE
    //////////////////////////////////////////////////////////////*/

    function _bytecode(Vault vault, address sol, address vl) internal {
        console2.log("bytecode (against out/ of this checkout)");
        string memory solName = "src/lib/SeaportOrderLib.sol:SeaportOrderLib";
        string memory vlName = "src/lib/ValoremLib.sol:ValoremLib";

        // Vault: link sites must hold the library addresses; immutables are masked here and checked
        // by value in _immutables.
        string memory vaultJson = vm.readFile("out/Vault.sol/Vault.json");
        (bytes memory want, bool[] memory mask, uint256 linksOk, uint256 linksSeen) =
            _expectedWithLinks(vaultJson, address(vault).code, solName, sol, vlName, vl);
        _maskImmutables(vaultJson, mask);
        // The expected count comes from the artifact's own linkReferences, never a hard-coded
        // number: every new library call site in Vault adds one, and a stale constant would make
        // a byte-perfect deployment FAIL (and train operators to ignore this line). Requiring at
        // least one site per library keeps a swapped or missing library a FAIL.
        uint256 solSites = _linkSites(vaultJson, "src/lib/SeaportOrderLib.sol", "SeaportOrderLib");
        uint256 vlSites = _linkSites(vaultJson, "src/lib/ValoremLib.sol", "ValoremLib");
        uint256 wantLinks = solSites + vlSites;
        _check(
            solSites != 0 && vlSites != 0 && linksSeen == wantLinks && linksOk == wantLinks,
            string.concat("vault: all ", vm.toString(wantLinks), " library link sites hold the expected addresses")
        );
        _check(
            _equalMasked(address(vault).code, want, mask),
            "vault: runtime == compiled Vault, outside link/immutable slots"
        );

        _library("out/SeaportOrderLib.sol/SeaportOrderLib.json", sol, "SeaportOrderLib");
        _library("out/ValoremLib.sol/ValoremLib.json", vl, "ValoremLib");
    }

    /// @dev A via-IR public library stores its own address in an immutable for call protection; that
    ///      word must equal the library's address and everything else must match the artifact.
    function _library(string memory path, address lib, string memory name) internal {
        bytes memory code = lib.code;
        if (code.length == 0) {
            _check(false, string.concat(name, ": has code"));
            return;
        }
        string memory json = vm.readFile(path);
        bytes memory want = vm.parseBytes(vm.parseJsonString(json, ".deployedBytecode.object"));
        bool[] memory mask = new bool[](want.length);
        Ref[] memory refs =
            abi.decode(vm.parseJson(json, ".deployedBytecode.immutableReferences.library_deploy_address"), (Ref[]));
        bool selfOk = refs.length > 0;
        for (uint256 r; r < refs.length; r++) {
            for (uint256 k; k < refs[r].length; k++) {
                mask[refs[r].start + k] = true;
            }
            if (code.length >= refs[r].start + 32) {
                selfOk = selfOk && uint256(_word(code, refs[r].start)) == uint256(uint160(lib));
            }
        }
        _check(selfOk, string.concat(name, ": deploy-address word == its own address"));
        _check(_equalMasked(code, want, mask), string.concat(name, ": runtime == compiled artifact"));
    }

    /// @dev Replaces every `__$<34 hex>$__` link placeholder in the artifact's hex with zeros so it
    ///      parses, masks those 20 bytes, and checks the deployed bytes there are the library the
    ///      placeholder names.
    function _expectedWithLinks(
        string memory json,
        bytes memory deployed,
        string memory solName,
        address sol,
        string memory vlName,
        address vl
    ) internal pure returns (bytes memory want, bool[] memory mask, uint256 ok, uint256 seen) {
        bytes memory hex_ = bytes(vm.parseJsonString(json, ".deployedBytecode.object"));
        bytes memory solTag = _placeholderTag(solName);
        bytes memory vlTag = _placeholderTag(vlName);
        uint256 offsetCount;
        uint256[] memory offsets = new uint256[](16);
        address[] memory expect = new address[](16);

        for (uint256 i = 2; i + 40 <= hex_.length; i++) {
            if (hex_[i] != "_" || hex_[i + 1] != "_" || hex_[i + 2] != "$") continue;
            bytes memory tag = new bytes(34);
            for (uint256 t; t < 34; t++) {
                tag[t] = hex_[i + 3 + t];
            }
            expect[offsetCount] =
                keccak256(tag) == keccak256(solTag) ? sol : (keccak256(tag) == keccak256(vlTag) ? vl : address(0));
            offsets[offsetCount++] = (i - 2) / 2;
            for (uint256 c; c < 40; c++) {
                hex_[i + c] = "0";
            }
            i += 39;
        }

        want = vm.parseBytes(string(hex_));
        mask = new bool[](want.length);
        for (uint256 n; n < offsetCount; n++) {
            seen++;
            for (uint256 k; k < 20; k++) {
                mask[offsets[n] + k] = true;
            }
            if (expect[n] != address(0) && deployed.length >= offsets[n] + 20) {
                if (address(bytes20(_word(deployed, offsets[n]))) == expect[n]) ok++;
            }
        }
    }

    /// @dev Number of link sites the artifact records for one library in the Vault runtime.
    function _linkSites(string memory json, string memory file, string memory lib) internal view returns (uint256) {
        string memory key = string.concat(".deployedBytecode.linkReferences['", file, "'].", lib);
        if (!vm.keyExistsJson(json, key)) return 0;
        return abi.decode(vm.parseJson(json, key), (Ref[])).length;
    }

    function _placeholderTag(string memory fullyQualified) internal pure returns (bytes memory tag) {
        bytes memory h = bytes(vm.toString(keccak256(bytes(fullyQualified))));
        tag = new bytes(34);
        for (uint256 i; i < 34; i++) {
            tag[i] = h[2 + i];
        }
    }

    function _maskImmutables(string memory json, bool[] memory mask) internal pure {
        string[] memory ids = vm.parseJsonKeys(json, ".deployedBytecode.immutableReferences");
        for (uint256 i; i < ids.length; i++) {
            Ref[] memory refs = abi.decode(
                vm.parseJson(json, string.concat(".deployedBytecode.immutableReferences.", ids[i])), (Ref[])
            );
            for (uint256 r; r < refs.length; r++) {
                for (uint256 k; k < refs[r].length; k++) {
                    mask[refs[r].start + k] = true;
                }
            }
        }
    }

    function _equalMasked(bytes memory got, bytes memory want, bool[] memory mask) internal pure returns (bool) {
        if (got.length != want.length) return false;
        for (uint256 i; i < got.length; i++) {
            if (!mask[i] && got[i] != want[i]) return false;
        }
        return true;
    }

    function _word(bytes memory b, uint256 offset) internal pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(b, 32), offset))
        }
    }

    /*//////////////////////////////////////////////////////////////
                         IMMUTABLES AND PARAMETERS
    //////////////////////////////////////////////////////////////*/

    function _immutables(Vault vault) internal {
        console2.log("immutables");
        address clear = vm.envOr("CLEARINGHOUSE", 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0);
        address seaport = vm.envOr("SEAPORT", 0x0000000000000068F116a894984e2DB1123eB395);
        _check(address(vault.asset()) == vm.envOr("ASSET", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), "asset");
        _check(address(vault.usdg()) == vm.envOr("USDG", 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168), "usdg");
        _check(address(vault.clear()) == clear, "clearinghouse");
        _check(address(vault.seaport()) == seaport, "seaport");
        _check(
            address(vault.priceFeed()) == vm.envOr("PRICE_FEED", 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15),
            "price feed"
        );
        _check(vault.conduitKey() == bytes32(0), "conduit key is zero (Seaport pulls the ERC-1155 directly)");
        // Write on fill: the vault is its own Seaport zone, so `authorizeOrder` writes on every fill.
        _check(vault.seaportZone() == address(vault), "Seaport zone is the vault itself");
        _check(vault.transferApprovalTarget() == seaport, "ERC-1155 transfer approval target is Seaport");
        _check(
            IERC1155Minimal(clear).isApprovedForAll(address(vault), seaport),
            "Valorem ERC-1155 approval for Seaport is set"
        );
        _check(vault.supportsInterface(type(IZone).interfaceId), "advertises the Seaport 1.6 zone interface");
        _check(!vault.supportsInterface(0x1626ba7e), "does not advertise EIP-1271 (the vault signs nothing)");

        // The dependencies the zone hooks are built against. `authorizeOrder` running before any
        // transfer and before the status update on every fulfilment path is a Seaport 1.6 fact
        // (integrations/seaport.md §4.4), so the runtime is pinned, not just the address.
        console2.log("dependencies");
        (string memory version,, address controller) = ISeaport(seaport).information();
        _check(keccak256(bytes(version)) == keccak256("1.6"), "seaport.information().version == 1.6");
        _check(
            controller == 0x00000000F9490004C11Cef243f5400493c00Ad63,
            "seaport conduit controller is the canonical 0x00000000F9490004C11Cef243f5400493c00Ad63"
        );
        bytes32 seaportHash = seaport.codehash;
        console2.log("  info  seaport extcodehash", vm.toString(seaportHash));
        _check(
            seaportHash == vm.envOr("EXPECT_SEAPORT_CODEHASH", SEAPORT_16_RUNTIME_HASH),
            "seaport runtime extcodehash matches the 4663 Seaport 1.6 runtime (test/fixtures/seaport)"
        );
        IValoremClear c = IValoremClear(clear);
        _check(c.feeBps() == 15, "clear feeBps == 15");
        _check(!c.feesEnabled() || vault.valoremFeeAccepted(), "clear fee switch off, or accepted by governance");
        _check(c.supportsInterface(0xd9b67a26), "clear is ERC-1155");
        // Key off the vault's actual clearinghouse, not the CLEARINGHOUSE env: the owner decision is
        // about who holds feeTo on the instance the vault settles on.
        if (address(vault.clear()) != OVERCALL_CLEAR) _ownClearFeeSwitch(IValoremClear(address(vault.clear())));
        _check(IERC20Metadata(address(vault.asset())).decimals() == 18, "asset has 18 decimals");
        _check(IERC20Metadata(address(vault.usdg())).decimals() == 6, "usdg has 6 decimals");
    }

    /// @dev Our own clearinghouse: its `feeTo` holds the Valorem fee switch, the fee sweep and `setFeeTo`, and
    ///      nothing in the vault or HandoverAdmin moves or checks it. A deployer-held `feeTo` survives the admin
    ///      handover and can switch the fee on at will (every fill then refuses until the admin accepts).
    function _ownClearFeeSwitch(IValoremClear c) internal {
        console2.log("own clearinghouse fee switch");
        address expected = vm.envOr("EXPECTED_CLEAR_FEE_TO", address(0));
        if (expected == address(0)) {
            _check(false, "EXPECTED_CLEAR_FEE_TO is set (required: the vault is not on Overcall's Clear)");
            return;
        }
        _check(true, "EXPECTED_CLEAR_FEE_TO is set");
        bytes memory want = vm.parseJsonBytes(vm.readFile(CLEAR_ARTIFACT), ".deployedBytecode.object");
        _check(
            keccak256(address(c).code) == keccak256(want),
            "clear runtime == script/artifacts/ValoremOptionsClearinghouse.json (pins the storage layout)"
        );
        address feeTo = c.feeTo();
        console2.log("  info  clear feeTo", feeTo);
        _check(feeTo == expected, "clear feeTo == EXPECTED_CLEAR_FEE_TO (the fee switch holder)");
        address pending = address(uint160(uint256(vm.load(address(c), bytes32(CLEAR_PENDING_FEE_TO_SLOT)))));
        _check(pending == address(0), "clear pendingFeeTo is empty (no feeTo handover in flight)");
    }

    function _parameters(Vault vault) internal {
        console2.log("parameters");
        (uint16 minOtm, uint16 maxOtm, uint16 minPrem, uint16 maxUtil, uint16 feeBps, uint64 cap) = vault.policy();
        PolicyParams memory want = Policy.launchDefaults();
        _check(minOtm == want.minOtmBps, "policy.minOtmBps == 300");
        _check(maxOtm == want.maxOtmBps, "policy.maxOtmBps == 1200");
        _check(minPrem == want.minPremiumBps, "policy.minPremiumBps == 40");
        _check(maxUtil == want.maxUtilizationBps, "policy.maxUtilizationBps == 9500");
        _check(feeBps == want.protocolFeeBps && feeBps == 500, "policy.protocolFeeBps == 500 (5% of premium)");
        _check(cap == want.maxContractsCap, "policy.maxContractsCap == 50");
        _check(vault.depositCap() == vm.envOr("DEPOSIT_CAP", uint256(20e18)), "depositCap == 20 NVDA");
        _check(vault.maxPriceAge() == 4 days, "maxPriceAge == 4 days");
        _check(vault.feeRecipient() == vm.envAddress("SAFE_FEE"), "feeRecipient == SAFE_FEE");
        _check(
            keccak256(bytes(vault.name())) == keccak256(bytes(vm.envOr("VAULT_NAME", string("Callhouse NVDA")))),
            "share name"
        );
        _check(
            keccak256(bytes(vault.symbol())) == keccak256(bytes(vm.envOr("VAULT_SYMBOL", string("cNVDA")))),
            "share symbol"
        );
        _check(vault.decimals() == 18, "share decimals == 18");
    }

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    function _roles(Vault vault) internal {
        bytes32 admin = vault.DEFAULT_ADMIN_ROLE();
        bytes32 keeperRole = vault.KEEPER_ROLE();
        bytes32 guardianRole = vault.GUARDIAN_ROLE();
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");
        address deployer = vm.envAddress("DEPLOYER");
        bool configured = vm.envOr("EXPECT_KEEPER_CONFIGURED", true);
        bool bootstrap = keccak256(bytes(vm.envOr("ADMIN_PHASE", string("safe")))) == keccak256("bootstrap");

        console2.log(bootstrap ? "roles (phase: bootstrap, deployer is admin)" : "roles (phase: safe)");
        if (bootstrap) {
            _check(vault.hasRole(admin, deployer), "DEPLOYER holds DEFAULT_ADMIN_ROLE (bootstrap)");
            address safe = vm.envOr("SAFE_ADMIN", address(0));
            if (safe != address(0)) {
                console2.log(
                    vault.hasRole(admin, safe)
                        ? "  info  SAFE_ADMIN already holds admin too: handover in progress, renounce is next"
                        : "  info  SAFE_ADMIN does not hold admin yet"
                );
            }
        } else {
            address safe = vm.envAddress("SAFE_ADMIN");
            _check(vault.hasRole(admin, safe), "SAFE_ADMIN holds DEFAULT_ADMIN_ROLE");
            _check(safe.code.length > 0, "SAFE_ADMIN is a contract, not a key");
            _check(!vault.hasRole(admin, deployer), "DEPLOYER no longer holds DEFAULT_ADMIN_ROLE");
        }
        _check(
            !vault.hasRole(keeperRole, deployer) && !vault.hasRole(guardianRole, deployer),
            "DEPLOYER holds neither KEEPER_ROLE nor GUARDIAN_ROLE"
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
        _check(keeper != guardian && keeper != deployer && guardian != deployer, "keeper, guardian, deployer distinct");
        _check(
            vault.getRoleAdmin(keeperRole) == admin && vault.getRoleAdmin(guardianRole) == admin
                && vault.getRoleAdmin(admin) == admin,
            "every role is administered by DEFAULT_ADMIN_ROLE"
        );
        _check(vault.supportsInterface(type(IAccessControl).interfaceId), "supports IAccessControl");
    }

    /*//////////////////////////////////////////////////////////////
                                 SAFES
    //////////////////////////////////////////////////////////////*/

    function _safes() internal {
        address adminSafe = vm.envOr("SAFE_ADMIN", address(0));
        if (adminSafe != address(0) && adminSafe.code.length > 0) {
            console2.log("admin safe");
            _safe(
                adminSafe,
                "admin Safe",
                vm.envOr("EXPECT_SAFE_THRESHOLD", uint256(2)),
                vm.envOr("EXPECT_SAFE_OWNERS", uint256(3))
            );
            string memory set = vm.envOr("EXPECT_SAFE_OWNER_SET", string(""));
            if (bytes(set).length != 0) {
                address[] memory want = vm.envAddress("EXPECT_SAFE_OWNER_SET", ",");
                address[] memory got = ISafeView(adminSafe).getOwners();
                bool same = want.length == got.length;
                for (uint256 i; same && i < want.length; i++) {
                    bool found;
                    for (uint256 j; j < got.length; j++) {
                        if (got[j] == want[i]) found = true;
                    }
                    same = found;
                }
                _check(same, "admin Safe owners == EXPECT_SAFE_OWNER_SET");
            }
        }
        address feeSafe = vm.envAddress("SAFE_FEE");
        if (feeSafe.code.length > 0) {
            console2.log("fee safe");
            _safe(feeSafe, "fee Safe", 1, 1);
        } else {
            console2.log("  info  SAFE_FEE is a plain address, not a Safe");
        }
    }

    function _safe(address safe, string memory label, uint256 minThreshold, uint256 minOwners) internal {
        address singleton = address(uint160(uint256(vm.load(safe, bytes32(0)))));
        _check(
            singleton == SAFE_L2_141 || singleton == SAFE_141 || singleton == SAFE_L2_130,
            string.concat(label, ": singleton is a canonical Safe 1.4.1 / 1.3.0 build")
        );
        uint256 threshold = ISafeView(safe).getThreshold();
        uint256 owners = ISafeView(safe).getOwners().length;
        _check(threshold >= minThreshold && threshold <= owners, string.concat(label, ": threshold"));
        _check(owners >= minOwners, string.concat(label, ": owner count"));
        (address[] memory modules,) = ISafeView(safe).getModulesPaginated(SAFE_SENTINEL, 10);
        _check(modules.length == 0, string.concat(label, ": no modules enabled"));
        _check(vm.load(safe, SAFE_GUARD_SLOT) == bytes32(0), string.concat(label, ": no transaction guard"));
        address fallbackHandler = address(uint160(uint256(vm.load(safe, SAFE_FALLBACK_SLOT))));
        _check(
            fallbackHandler == FALLBACK_141 || fallbackHandler == address(0),
            string.concat(label, ": fallback handler is canonical (or none)")
        );
    }

    /*//////////////////////////////////////////////////////////////
                              FRESH STATE
    //////////////////////////////////////////////////////////////*/

    function _freshState(Vault vault) internal {
        console2.log("fresh state");
        _check(uint8(vault.phase()) == 0, "phase Idle");
        _check(!vault.writesHalted(), "writes not halted");
        _check(!vault.valoremFeeAccepted(), "Valorem engine fee not accepted");
        _check(
            vault.cycleNumber() == 0 && vault.cycleExerciseTs() == 0 && vault.cycleExpiryTs() == 0
                && vault.cycleStrikeUsdg() == 0,
            "no cycle opened"
        );
        _check(
            vault.optionId() == 0 && vault.claimKey() == 0 && vault.contractsWritten() == 0,
            "no option written, no claim"
        );
        _check(
            vault.listingHash() == bytes32(0) && vault.listingsThisCycle() == 0 && vault.listingAmount() == 0,
            "no listing"
        );
        _check(vault.totalSupply() == 0 && vault.queuedShares() == 0 && vault.epochId() == 1, "no shares, epoch 1");
        _check(
            vault.reservedAssets() == 0 && vault.usdgReservedForQueue() == 0 && vault.pendingFeeUsdg() == 0,
            "nothing reserved or pending"
        );
        _check(
            vault.usdgAccounted() == 0 && vault.accUsdgPerShare() == 0 && vault.usdgDust() == 0
                && vault.usdgUnallocated() == 0,
            "USDG books empty"
        );
        _check(
            IERC20(address(vault.asset())).balanceOf(address(vault)) == 0
                && vault.usdg().balanceOf(address(vault)) == 0,
            "holds no asset and no USDG"
        );
    }
}
