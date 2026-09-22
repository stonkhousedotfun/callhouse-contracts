// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {MakerRegistry} from "../../../src/v2/mm/MakerRegistry.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";

/// @notice C8-01 fixture: one AccessManager, roles and selector maps loaded from `script/v2/roles.v8.json`.
/// @dev The JSON is the source of truth. `V8Roles` is the compiled mirror; {_assertManifestMatchesLibrary}
///      fails if they drift. `_grantAll(holder, delay)` is the two-mode helper later C8 tasks copy:
///      delay 0 keeps `vm.prank(admin)` working; the real delay is for schedule/execute tests.
abstract contract V8AccessTest is Test {
    using stdJson for string;

    AccessManager internal manager;
    /// @dev Path from the contracts repo root. Tests run with that as cwd.
    string internal constant ROLES_JSON = "script/v2/roles.v8.json";

    function _rolesJson() internal view returns (string memory) {
        return vm.readFile(ROLES_JSON);
    }

    /// @dev Deploys the unmodified OZ AccessManager with this test contract as initial ADMIN (delay 0).
    function _deployManager() internal {
        if (address(manager) != address(0)) return;
        manager = new AccessManager(address(this));
        vm.label(address(manager), "AccessManager");
        _assertManifestMatchesLibrary();
        _setRoleAdminsAndGuardians();
    }

    /// @dev JSON role ids and delays must equal `V8Roles`. A silent drift would make VerifyV8 and the
    ///      access-matrix green on the wrong table.
    function _assertManifestMatchesLibrary() internal view {
        string memory json = _rolesJson();
        string[11] memory names = [
            "ADMIN",
            "FEE_MANAGER",
            "MARKET_FEE_MANAGER",
            "CONFIG_ADMIN",
            "TREASURY_ADMIN",
            "LISTING",
            "OPS_ADMIN",
            "GUARDIAN",
            "PRICER",
            "QUOTER",
            "BUYBACK"
        ];
        for (uint64 i; i < V8Roles.COUNT; ++i) {
            uint256 id = json.readUint(string.concat(".roles.", names[i]));
            require(id == i, "roles.v8.json id != V8Roles");
            require(keccak256(bytes(V8Roles.nameOf(i))) == keccak256(bytes(names[i])), "V8Roles.nameOf drift");
            uint256 delay = json.readUint(string.concat(".delaysS.", names[i]));
            require(delay == uint256(V8Roles.delayOf(i)), "roles.v8.json delay != V8Roles");
        }
    }

    function _setRoleAdminsAndGuardians() internal {
        manager.setRoleAdmin(V8Roles.GUARDIAN, V8Roles.OPS_ADMIN);
        manager.setRoleAdmin(V8Roles.PRICER, V8Roles.OPS_ADMIN);
        manager.setRoleAdmin(V8Roles.QUOTER, V8Roles.OPS_ADMIN);
        manager.setRoleAdmin(V8Roles.BUYBACK, V8Roles.OPS_ADMIN);
        manager.setRoleGuardian(V8Roles.FEE_MANAGER, V8Roles.GUARDIAN);
        manager.setRoleGuardian(V8Roles.MARKET_FEE_MANAGER, V8Roles.GUARDIAN);
        manager.setRoleGuardian(V8Roles.CONFIG_ADMIN, V8Roles.GUARDIAN);
        manager.setRoleGuardian(V8Roles.TREASURY_ADMIN, V8Roles.GUARDIAN);
        manager.setRoleGuardian(V8Roles.LISTING, V8Roles.GUARDIAN);
    }

    /// @dev Grant `role` to `account` with `delay` seconds of execution delay.
    ///      ADMIN can grant any role whose `roleAdmin` is still ADMIN. GUARDIAN / PRICER / QUOTER /
    ///      BUYBACK are parented to OPS_ADMIN in `roles.v8.json`, so a bare `grantRole(GUARDIAN, …)`
    ///      from the test contract reverts `AccessManagerUnauthorizedAccount(this, OPS_ADMIN)`. This
    ///      helper acquires the role-admin first; it does not change what the granted role is allowed
    ///      to do on a target.
    function _grant(uint64 role, address account, uint32 delay) internal {
        _deployManager();
        uint64 adminRole = manager.getRoleAdmin(role);
        (bool callerIsAdmin,) = manager.hasRole(adminRole, address(this));
        if (!callerIsAdmin) {
            uint64 adminOfAdmin = manager.getRoleAdmin(adminRole);
            (bool canGrantAdmin,) = manager.hasRole(adminOfAdmin, address(this));
            require(canGrantAdmin, "cannot acquire role-admin to grant");
            manager.grantRole(adminRole, address(this), 0);
        }
        manager.grantRole(role, account, delay);
    }

    /// @dev Map every selector listed for `targetName` in the JSON onto `target`. GRANTS NOTHING: use it when a
    ///      target's roles belong to different holders, as {MakerVault}'s TREASURY_ADMIN and QUOTER lanes do, and
    ///      grant each one with {_grant} afterwards.
    function _map(address target, string memory targetName) internal {
        _deployManager();
        string memory json = _rolesJson();
        string memory path = string.concat(".targets.", targetName);
        string[] memory sigs = vm.parseJsonKeys(json, path);
        require(sigs.length > 0, "no selectors in manifest for target");
        for (uint256 i; i < sigs.length; ++i) {
            // A manifest key is a full signature -- `setTier(address,uint16)` -- and the parens and commas are
            // not valid in dotted JSON-path notation, so the key must be quoted in bracket form. Dotted form
            // fails with "must return exactly one JSON value", which reads like a missing key rather than a
            // syntax problem; that is why this is spelled out here.
            string memory roleName = json.readString(string.concat(path, '["', sigs[i], '"]'));
            uint64 role = uint64(json.readUint(string.concat(".roles.", roleName)));
            bytes4[] memory one = new bytes4[](1);
            one[0] = bytes4(keccak256(bytes(sigs[i])));
            manager.setTargetFunctionRole(target, one, role);
        }
    }

    /// @dev Map every selector listed for `targetName` in the JSON onto `target`, then grant those roles
    ///      to `holder` at `delay`.
    function _wire(address target, string memory targetName, address holder, uint32 delay) internal {
        _map(target, targetName);
        string memory json = _rolesJson();
        string memory path = string.concat(".targets.", targetName);
        string[] memory sigs = vm.parseJsonKeys(json, path);
        for (uint256 i; i < sigs.length; ++i) {
            string memory roleName = json.readString(string.concat(path, '["', sigs[i], '"]'));
            uint64 role = uint64(json.readUint(string.concat(".roles.", roleName)));
            (bool isMember,) = manager.hasRole(role, holder);
            // A role parented to OPS_ADMIN (GUARDIAN, PRICER, QUOTER, BUYBACK) needs its role-admin acquired
            // first: the bare grantRole would revert AccessManagerUnauthorizedAccount(this, OPS_ADMIN).
            // _grant does that acquisition; it also deploys the manager, which is already deployed here.
            if (!isMember) _grant(role, holder, delay);
        }
    }

    function _newCalendar(uint32[] memory holidays, address listingHolder) internal returns (ExpiryCalendar cal) {
        _deployManager();
        cal = new ExpiryCalendar(address(manager), holidays);
        _wire(address(cal), "ExpiryCalendar", listingHolder, 0);
    }

    function _newRegistry(address feeHolder) internal returns (MakerRegistry registry) {
        _deployManager();
        registry = new MakerRegistry(address(manager));
        _wire(address(registry), "MakerRegistry", feeHolder, 0);
    }

    /// @dev C8-02 copy-me: one manager, Clearinghouse constructed with `authority`, selectors wired, `holder`
    ///      gets every Clearinghouse role at `delay`. New storage on the target sits AFTER `_series`.
    function _newClearinghouse(
        address usdg_,
        address calendar_,
        address feeRecipient_,
        string memory baseUri_,
        address holder
    ) internal returns (Clearinghouse house) {
        _deployManager();
        house = new Clearinghouse(address(manager), usdg_, calendar_, feeRecipient_, baseUri_);
        _wire(address(house), "Clearinghouse", holder, 0);
    }

    /// @dev C8-05 copy-me: the vault's two role lanes are DISJOINT, so the manifest is mapped once and each lane is
    ///      granted to its own holder. `treasuryAdmin` can move money to {MakerVault.treasury} and set the limits but
    ///      cannot quote; `quoter` can quote but cannot reach the money. `deposit` is permissionless and therefore
    ///      not in the manifest at all, so nobody has to be granted anything to fund the vault.
    function _newVault(
        IOrderBook book,
        address treasury_,
        MakerVault.Limits memory limits_,
        address treasuryAdmin,
        address quoterHolder
    ) internal returns (MakerVault v) {
        _deployManager();
        v = new MakerVault(book, address(manager), treasury_, limits_);
        _map(address(v), "MakerVault");
        _grant(V8Roles.TREASURY_ADMIN, treasuryAdmin, 0);
        if (quoterHolder != address(0)) _grant(V8Roles.QUOTER, quoterHolder, 0);
    }

    /// @dev The roller's three lanes: LISTING (`setMinRollUnits`), CONFIG_ADMIN (`setKeeperRewards`) and PRICER
    ///      (`reprice`). `roll`, `cancelStale`, `setStrategy` and `stop` carry no role and are not mapped.
    function _newRoller(IOrderBook book, address configAdmin, address pricer) internal returns (AutoRoller roller) {
        _deployManager();
        roller = new AutoRoller(book, address(manager));
        _map(address(roller), "AutoRoller");
        _grant(V8Roles.LISTING, configAdmin, 0);
        _grant(V8Roles.CONFIG_ADMIN, configAdmin, 0);
        if (pricer != address(0)) _grant(V8Roles.PRICER, pricer, 0);
    }

    function _newDistributor(IERC20 usdg_, address treasury_, address treasuryAdmin)
        internal
        returns (RewardsDistributor rd)
    {
        _deployManager();
        rd = new RewardsDistributor(usdg_, address(manager), treasury_);
        _map(address(rd), "RewardsDistributor");
        _grant(V8Roles.TREASURY_ADMIN, treasuryAdmin, 0);
    }

    function _newSettlementOracle(address holder) internal returns (SettlementOracle o) {
        _deployManager();
        o = new SettlementOracle(address(manager));
        _wire(address(o), "SettlementOracle", holder, 0);
    }

    function _newChainlinkFeedSource(address holder) internal returns (ChainlinkFeedSource s) {
        _deployManager();
        s = new ChainlinkFeedSource(address(manager));
        _wire(address(s), "ChainlinkFeedSource", holder, 0);
    }

    function _newUniV3TwapSource(address usdg_, address holder) internal returns (UniV3TwapSource s) {
        _deployManager();
        s = new UniV3TwapSource(address(manager), usdg_);
        _wire(address(s), "UniV3TwapSource", holder, 0);
    }

    function _newDataStreamsSource(address verifierProxy, address holder) internal returns (DataStreamsSource s) {
        _deployManager();
        s = new DataStreamsSource(address(manager), verifierProxy);
        _wire(address(s), "DataStreamsSource", holder, 0);
    }

    function _newKeeperRewards(IERC20 usdg_, address treasury_, address holder) internal returns (KeeperRewards k) {
        _deployManager();
        k = new KeeperRewards(usdg_, address(manager), treasury_);
        _wire(address(k), "KeeperRewards", holder, 0);
    }

    /// @dev Split replacement for the deleted `setMarketConfig`. Does not touch `mintPaused`.
    ///      Three restricted calls. A one-shot `vm.prank` around this helper only covers listing;
    ///      replay it for fees and oracle. Do not `startPrank` over a pending one-shot (Foundry
    ///      rejects that overwrite).
    function _reconfigure(IClearinghouse house, address underlying, V2Types.MarketConfig memory cfg) internal {
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        house.setMarketListing(underlying, cfg.enabled, cfg.strikeTick);
        if (mode == VmSafe.CallerMode.Prank) vm.prank(sender);
        house.setMarketFees(underlying, cfg.exerciseFeeBps, cfg.mintFeePpm);
        if (mode == VmSafe.CallerMode.Prank) vm.prank(sender);
        house.setMarketOracle(underlying, cfg.oracle);
    }

    /// @dev Calldata that ABI-decodes for `sig` using zero/empty args. Solidity decodes arguments
    ///      BEFORE modifiers, so `abi.encodePacked(selector)` reverts on decode (empty/Error) rather
    ///      than `NotAuthorized` for every mapped function that takes arguments. The access-matrix
    ///      probe must reach `restricted`.
    function _dummyCalldata(string memory sig) internal pure returns (bytes memory) {
        bytes memory raw = bytes(sig);
        bytes4 sel = bytes4(keccak256(raw));
        uint256 open = type(uint256).max;
        uint256 close;
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == "(" && open == type(uint256).max) open = i;
            if (raw[i] == ")") close = i;
        }
        if (open == type(uint256).max || close <= open + 1) return abi.encodePacked(sel);
        return bytes.concat(sel, _encodeArgs(_splitTypes(_slice(raw, open + 1, close))));
    }

    function _encodeArgs(string[] memory types) internal pure returns (bytes memory) {
        uint256 headLen;
        for (uint256 i; i < types.length; ++i) {
            headLen += _isStatic(types[i]) ? _staticLen(types[i]) : 32;
        }
        bytes memory head;
        bytes memory tail;
        for (uint256 i; i < types.length; ++i) {
            if (_isStatic(types[i])) {
                head = bytes.concat(head, _zeros(_staticLen(types[i])));
            } else {
                head = bytes.concat(head, abi.encodePacked(bytes32(headLen + tail.length)));
                tail = bytes.concat(tail, _encodeDynamic(types[i]));
            }
        }
        return bytes.concat(head, tail);
    }

    function _isStatic(string memory t) internal pure returns (bool) {
        bytes memory b = bytes(t);
        if (b.length == 0) return true;
        if (b[0] == "(") {
            string[] memory inner = _splitTypes(_slice(b, 1, b.length - 1));
            for (uint256 i; i < inner.length; ++i) {
                if (!_isStatic(inner[i])) return false;
            }
            return true;
        }
        if (b.length >= 2 && b[b.length - 2] == "[" && b[b.length - 1] == "]") return false;
        if (keccak256(b) == keccak256("string") || keccak256(b) == keccak256("bytes")) return false;
        return true;
    }

    function _staticLen(string memory t) internal pure returns (uint256) {
        bytes memory b = bytes(t);
        if (b.length != 0 && b[0] == "(") {
            string[] memory inner = _splitTypes(_slice(b, 1, b.length - 1));
            uint256 n;
            for (uint256 i; i < inner.length; ++i) {
                n += _staticLen(inner[i]);
            }
            return n;
        }
        return 32;
    }

    function _encodeDynamic(string memory t) internal pure returns (bytes memory) {
        bytes memory b = bytes(t);
        if (b.length != 0 && b[0] == "(") {
            return _encodeArgs(_splitTypes(_slice(b, 1, b.length - 1)));
        }
        // string, bytes, T[]: length 0
        return abi.encodePacked(bytes32(0));
    }

    function _splitTypes(bytes memory inner) internal pure returns (string[] memory) {
        if (inner.length == 0) return new string[](0);
        uint256 n = 1;
        uint256 depth;
        for (uint256 i; i < inner.length; ++i) {
            if (inner[i] == "(") ++depth;
            else if (inner[i] == ")") --depth;
            else if (inner[i] == "," && depth == 0) ++n;
        }
        string[] memory out = new string[](n);
        uint256 start;
        uint256 idx;
        depth = 0;
        for (uint256 i; i < inner.length; ++i) {
            if (inner[i] == "(") {
                ++depth;
            } else if (inner[i] == ")") {
                --depth;
            } else if (inner[i] == "," && depth == 0) {
                out[idx++] = string(_slice(inner, start, i));
                start = i + 1;
            }
        }
        out[idx] = string(_slice(inner, start, inner.length));
        return out;
    }

    function _slice(bytes memory b, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        require(end >= start, "slice");
        out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[start + i];
        }
    }

    function _zeros(uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
    }
}
