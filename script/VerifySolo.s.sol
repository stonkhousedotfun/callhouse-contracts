// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Policy, PolicyParams} from "../src/Policy.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../src/interfaces/IChainlinkFeed.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {AccountFactory} from "../src/solo/AccountFactory.sol";
import {WriterAccount} from "../src/solo/Account.sol";
import {BytecodeCheck} from "./lib/BytecodeCheck.sol";

/// @notice Read-only post-deploy check of one src/solo/ market: the AccountFactory, its WriterAccount
///         implementation and the linked ValoremLib. Broadcasts nothing. Prints every check and reverts
///         at the end if any failed.
/// @dev Run from a checkout of the EXACT commit that was deployed, after `forge build`: the bytecode
///      checks compare the chain against `out/`.
///        FACTORY=0x... KEEPER=0x... GUARDIAN=0x... ADMIN=0x... FEE_RECIPIENT=0x... \
///          forge script script/VerifySolo.s.sol --rpc-url $RH_RPC --no-storage-caching
///
///      WHAT IS CHECKED
///        1. Chain id.
///        2. Runtime bytecode: the factory against `out/AccountFactory.sol/AccountFactory.json` with its
///           immutable slots masked; the implementation against `out/Account.sol/WriterAccount.json` with
///           its immutable slots and its ValoremLib link sites masked (every site checked to hold
///           VALOREM_LIB, the count read from the artifact); ValoremLib itself against its artifact with
///           its deploy-address word checked. A match proves the logic and every compiled-in hard cap
///           ({Policy}) are this commit's.
///        3. Every immutable by value on both contracts (asset, USDG, Clear, Seaport, feed, zero conduit
///           key, `implementation.factory == FACTORY`), and the implementation locked: `initialized()`
///           true with no owner, so nobody can initialise the template itself.
///        4. The dependencies, probed as the contracts use them: the asset's symbol is EXPECTED_TICKER
///           with 18 decimals, `uiMultiplier()` > 0 and `oraclePaused()` false; USDG has 6 decimals; the
///           feed's description contains EXPECTED_TICKER, 8 decimals, a positive answer no older than
///           `maxPriceAge()`; Seaport reports 1.6; Clear `feeBps == 15` with the switch off (or accepted)
///           and ERC-1155.
///        5. Parameters: policy field by field against `Policy.launchDefaults()` (or the MIN_OTM_BPS..
///           overrides when SET_POLICY=true was used at configure time), `depositCap == DEPOSIT_CAP`,
///           `maxPriceAge == 4 days`, `feeRecipient == FEE_RECIPIENT`, writes not halted, Valorem fee
///           not accepted.
///        6. Roles: ADMIN holds DEFAULT_ADMIN_ROLE; the keeper holds exactly KEEPER_ROLE and the guardian
///           exactly GUARDIAN_ROLE (or neither, before configure: EXPECT_KEEPER_CONFIGURED=false); the
///           three addresses distinct; every role administered by DEFAULT_ADMIN_ROLE.
///        7. Fresh state (unless EXPECT_FRESH=false): no week set, no account created, nothing pending
///           or live.
///
///      ENVIRONMENT
///        FACTORY                   required. The AccountFactory.
///        KEEPER, GUARDIAN, ADMIN   required. ADMIN is the DEFAULT_ADMIN_ROLE holder (bootstrap: the deployer).
///        FEE_RECIPIENT             required. Expected `feeRecipient()`.
///        EXPECTED_TICKER           default NVDA.        DEPOSIT_CAP  default 20e18 (asset base units).
///        ASSET, PRICE_FEED, USDG, CLEARINGHOUSE, SEAPORT   the DeploySolo.s.sol defaults (the live NVDA market).
///        VALOREM_LIB               optional. When unset it is read from the implementation's first link
///                                  site, then pinned by bytecode against out/ValoremLib.sol/ValoremLib.json.
///        EXPECT_KEEPER_CONFIGURED  default true.   EXPECT_FRESH  default true.   EXPECT_CHAIN_ID  default 4663.
///        SET_POLICY + MIN_OTM_BPS, MAX_OTM_BPS, MIN_PREMIUM_BPS, MAX_UTILIZATION_BPS, PROTOCOL_FEE_BPS,
///        MAX_CONTRACTS_CAP         the policy to expect instead of launchDefaults (same names as ConfigureSolo).
contract VerifySolo is BytecodeCheck {
    address internal constant CLEARINGHOUSE = 0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6;
    address internal constant SEAPORT_16 = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    uint256 internal constant LAUNCH_DEPOSIT_CAP = 20e18;

    string internal constant FACTORY_ARTIFACT = "out/AccountFactory.sol/AccountFactory.json";
    string internal constant ACCOUNT_ARTIFACT = "out/Account.sol/WriterAccount.json";
    string internal constant VALOREM_LIB_ARTIFACT = "out/ValoremLib.sol/ValoremLib.json";
    string internal constant VALOREM_LIB_FILE = "src/lib/ValoremLib.sol";
    string internal constant VALOREM_LIB_NAME = "ValoremLib";

    uint256 internal failures;
    uint256 internal passes;

    function run() external {
        AccountFactory factory = AccountFactory(vm.envAddress("FACTORY"));

        console2.log("chain");
        _check(block.chainid == vm.envOr("EXPECT_CHAIN_ID", uint256(4663)), "chain id");
        require(address(factory).code.length > 0, "FACTORY has no code");
        WriterAccount impl = factory.implementation();

        _bytecode(factory, impl);
        _immutables(factory, impl);
        _dependencies(factory);
        _parameters(factory);
        _roles(factory);
        if (vm.envOr("EXPECT_FRESH", true)) _freshState(factory);

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

    function _bytecode(AccountFactory factory, WriterAccount impl) internal {
        console2.log("bytecode (against out/ of this checkout)");

        // The factory links nothing; only its immutables are masked (checked by value in _immutables).
        string memory factoryJson = vm.readFile(FACTORY_ARTIFACT);
        bytes memory want = _artifactRuntime(factoryJson);
        bool[] memory mask = new bool[](want.length);
        _maskImmutables(factoryJson, mask);
        _check(
            _equalMasked(address(factory).code, want, mask),
            "factory: runtime == compiled AccountFactory, outside immutable slots"
        );

        // The implementation links ValoremLib. Which library: VALOREM_LIB, or the address the deployed
        // code itself links, pinned below by its runtime, so a derived address cannot smuggle other code in.
        bytes memory code = address(impl).code;
        if (code.length == 0) {
            _check(false, "implementation: has code");
            return;
        }
        _check(true, "implementation: has code");
        string memory implJson = vm.readFile(ACCOUNT_ARTIFACT);
        address vl = vm.envOr("VALOREM_LIB", address(0));
        if (vl == address(0)) {
            vl = address(bytes20(_word(code, _firstLinkSite(implJson, VALOREM_LIB_FILE, VALOREM_LIB_NAME))));
            console2.log("  info  VALOREM_LIB read from the implementation's first link site:", vl);
        } else {
            console2.log("  info  VALOREM_LIB", vl);
        }
        (bytes memory implWant, bool[] memory implMask, uint256 linksOk, uint256 linksSeen) =
            _expectedWithLinks(implJson, code, string.concat(VALOREM_LIB_FILE, ":", VALOREM_LIB_NAME), vl);
        _maskImmutables(implJson, implMask);
        uint256 sites = _linkSites(implJson, VALOREM_LIB_FILE, VALOREM_LIB_NAME);
        _check(
            sites != 0 && linksSeen == sites && linksOk == sites,
            string.concat("implementation: all ", vm.toString(sites), " ValoremLib link sites hold VALOREM_LIB")
        );
        _check(
            _equalMasked(code, implWant, implMask),
            "implementation: runtime == compiled WriterAccount, outside link/immutable slots"
        );

        (bool hasCode, bool selfOk, bool runtimeOk) = _libraryRuntime(VALOREM_LIB_ARTIFACT, vl);
        _check(hasCode, "ValoremLib: has code");
        _check(selfOk, "ValoremLib: deploy-address word == its own address");
        _check(runtimeOk, "ValoremLib: runtime == compiled artifact");
    }

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    function _immutables(AccountFactory factory, WriterAccount impl) internal {
        address asset = vm.envOr("ASSET", NVDA);
        address usdg = vm.envOr("USDG", USDG);
        address clear = vm.envOr("CLEARINGHOUSE", CLEARINGHOUSE);
        address seaport = vm.envOr("SEAPORT", SEAPORT_16);
        address feed = vm.envOr("PRICE_FEED", NVDA_USD_FEED);

        console2.log("immutables (factory)");
        _check(address(factory.asset()) == asset, "factory.asset == ASSET");
        _check(address(factory.usdg()) == usdg, "factory.usdg == USDG");
        _check(address(factory.clear()) == clear, "factory.clear == CLEARINGHOUSE");
        _check(address(factory.seaport()) == seaport, "factory.seaport == SEAPORT");
        _check(address(factory.priceFeed()) == feed, "factory.priceFeed == PRICE_FEED");
        _check(factory.conduitKey() == bytes32(0), "factory.conduitKey is zero (Seaport pulls the ERC-1155 directly)");

        console2.log("immutables (implementation)");
        _check(address(impl.factory()) == address(factory), "implementation.factory == FACTORY");
        _check(address(impl.asset()) == asset, "implementation.asset == ASSET");
        _check(address(impl.usdg()) == usdg, "implementation.usdg == USDG");
        _check(address(impl.clear()) == clear, "implementation.clear == CLEARINGHOUSE");
        _check(address(impl.seaport()) == seaport, "implementation.seaport == SEAPORT");
        _check(address(impl.priceFeed()) == feed, "implementation.priceFeed == PRICE_FEED");
        _check(impl.conduitKey() == bytes32(0), "implementation.conduitKey is zero");
        // The constructor calls `lockImplementation()`: the template is `initialized` with no owner, so
        // `initialize` reverts on it and only clones ever get an owner.
        _check(impl.initialized(), "implementation.initialized() == true (locked)");
        _check(impl.owner() == address(0) && impl.index() == 0, "implementation has no owner and no index");
    }

    /*//////////////////////////////////////////////////////////////
                             DEPENDENCIES
    //////////////////////////////////////////////////////////////*/

    function _dependencies(AccountFactory factory) internal {
        console2.log("dependencies");
        string memory ticker = vm.envOr("EXPECTED_TICKER", string("NVDA"));
        address asset = address(factory.asset());

        string memory symbol = IERC20Metadata(asset).symbol();
        _check(
            keccak256(bytes(symbol)) == keccak256(bytes(ticker)),
            string.concat("asset symbol == EXPECTED_TICKER (\"", symbol, "\" vs \"", ticker, "\")")
        );
        _check(IERC20Metadata(asset).decimals() == 18, "asset has 18 decimals");
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSelector(IStockToken.uiMultiplier.selector));
        _check(ok && data.length == 32 && abi.decode(data, (uint256)) > 0, "asset uiMultiplier() answers, > 0");
        (ok, data) = asset.staticcall(abi.encodeWithSelector(IStockToken.oraclePaused.selector));
        _check(ok && data.length == 32 && !abi.decode(data, (bool)), "asset oraclePaused() answers, false");
        _check(IERC20Metadata(address(factory.usdg())).decimals() == 6, "usdg has 6 decimals");

        IChainlinkFeed feed = factory.priceFeed();
        string memory description = feed.description();
        _check(
            _contains(description, ticker),
            string.concat("feed description contains EXPECTED_TICKER (\"", description, "\")")
        );
        _check(feed.decimals() == 8, "feed decimals == 8");
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        _check(roundId != 0 && answer > 0, string.concat("feed live answer > 0 (", vm.toString(answer), ")"));
        bool fresh =
            updatedAt != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= factory.maxPriceAge();
        _check(
            fresh,
            string.concat(
                "feed updatedAt within maxPriceAge (age ",
                vm.toString(updatedAt <= block.timestamp ? block.timestamp - updatedAt : 0),
                " s)"
            )
        );

        (string memory version,,) = ISeaport(address(factory.seaport())).information();
        _check(keccak256(bytes(version)) == keccak256("1.6"), "seaport.information().version == 1.6");

        IValoremClear c = factory.clear();
        _check(c.feeBps() == 15, "clear feeBps == 15");
        _check(!c.feesEnabled() || factory.valoremFeeAccepted(), "clear fee switch off, or accepted by governance");
        _check(c.supportsInterface(0xd9b67a26), "clear is ERC-1155");
    }

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    function _parameters(AccountFactory factory) internal {
        console2.log("parameters");
        PolicyParams memory want = Policy.launchDefaults();
        if (vm.envOr("SET_POLICY", false)) {
            want = PolicyParams({
                minOtmBps: uint16(vm.envOr("MIN_OTM_BPS", uint256(300))),
                maxOtmBps: uint16(vm.envOr("MAX_OTM_BPS", uint256(1200))),
                minPremiumBps: uint16(vm.envOr("MIN_PREMIUM_BPS", uint256(40))),
                maxUtilizationBps: uint16(vm.envOr("MAX_UTILIZATION_BPS", uint256(9500))),
                protocolFeeBps: uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(500))),
                maxContractsCap: uint64(vm.envOr("MAX_CONTRACTS_CAP", uint256(50)))
            });
            console2.log("  info  policy expected from SET_POLICY overrides, not launchDefaults");
        }
        (uint16 minOtm, uint16 maxOtm, uint16 minPrem, uint16 maxUtil, uint16 feeBps, uint64 cap) = factory.policy();
        _check(minOtm == want.minOtmBps, string.concat("policy.minOtmBps == ", vm.toString(want.minOtmBps)));
        _check(maxOtm == want.maxOtmBps, string.concat("policy.maxOtmBps == ", vm.toString(want.maxOtmBps)));
        _check(
            minPrem == want.minPremiumBps, string.concat("policy.minPremiumBps == ", vm.toString(want.minPremiumBps))
        );
        _check(
            maxUtil == want.maxUtilizationBps,
            string.concat("policy.maxUtilizationBps == ", vm.toString(want.maxUtilizationBps))
        );
        _check(
            feeBps == want.protocolFeeBps, string.concat("policy.protocolFeeBps == ", vm.toString(want.protocolFeeBps))
        );
        _check(
            cap == want.maxContractsCap, string.concat("policy.maxContractsCap == ", vm.toString(want.maxContractsCap))
        );

        uint256 wantCap = vm.envOr("DEPOSIT_CAP", LAUNCH_DEPOSIT_CAP);
        _check(factory.depositCap() == wantCap, string.concat("depositCap == DEPOSIT_CAP (", vm.toString(wantCap), ")"));
        _check(factory.maxPriceAge() == 4 days, "maxPriceAge == 4 days");
        _check(factory.feeRecipient() == vm.envAddress("FEE_RECIPIENT"), "feeRecipient == FEE_RECIPIENT");
        _check(!factory.writesHalted(), "writes not halted");
        _check(!factory.valoremFeeAccepted(), "Valorem engine fee not accepted");
    }

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    function _roles(AccountFactory factory) internal {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes32 keeperRole = factory.KEEPER_ROLE();
        bytes32 guardianRole = factory.GUARDIAN_ROLE();
        address admin = vm.envAddress("ADMIN");
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");
        bool configured = vm.envOr("EXPECT_KEEPER_CONFIGURED", true);

        console2.log(configured ? "roles (configured)" : "roles (unconfigured: before ConfigureSolo)");
        _check(factory.hasRole(adminRole, admin), "ADMIN holds DEFAULT_ADMIN_ROLE");
        if (admin.code.length == 0) console2.log("  info  ADMIN is a plain key, not a Safe");
        _check(
            factory.hasRole(keeperRole, keeper) == configured,
            configured ? "KEEPER holds KEEPER_ROLE" : "KEEPER does not hold KEEPER_ROLE yet (unconfigured)"
        );
        _check(
            factory.hasRole(guardianRole, guardian) == configured,
            configured ? "GUARDIAN holds GUARDIAN_ROLE" : "GUARDIAN does not hold GUARDIAN_ROLE yet (unconfigured)"
        );
        _check(
            !factory.hasRole(adminRole, keeper) && !factory.hasRole(guardianRole, keeper), "keeper holds nothing else"
        );
        _check(
            !factory.hasRole(adminRole, guardian) && !factory.hasRole(keeperRole, guardian),
            "guardian holds nothing else"
        );
        _check(
            !factory.hasRole(keeperRole, admin) && !factory.hasRole(guardianRole, admin),
            "ADMIN holds neither KEEPER_ROLE nor GUARDIAN_ROLE"
        );
        _check(keeper != guardian && keeper != admin && guardian != admin, "keeper, guardian, admin distinct");
        _check(
            factory.getRoleAdmin(keeperRole) == adminRole && factory.getRoleAdmin(guardianRole) == adminRole
                && factory.getRoleAdmin(adminRole) == adminRole,
            "every role is administered by DEFAULT_ADMIN_ROLE"
        );
        _check(factory.supportsInterface(type(IAccessControl).interfaceId), "supports IAccessControl");
    }

    /*//////////////////////////////////////////////////////////////
                              FRESH STATE
    //////////////////////////////////////////////////////////////*/

    function _freshState(AccountFactory factory) internal {
        console2.log("fresh state");
        (uint32 id, uint256 strike, uint40 exerciseTs, uint40 baseExpiryTs, uint256 ask) = factory.week();
        _check(id == 0 && strike == 0 && exerciseTs == 0 && baseExpiryTs == 0 && ask == 0, "no week set (week.id == 0)");
        _check(factory.accountCount() == 0 && factory.nextIndex() == 0, "no account created (accountCount == 0)");
        _check(factory.pendingCount() == 0, "nothing pending (pendingCount == 0)");
        _check(factory.liveCount() == 0, "nothing live (liveCount == 0)");
    }

    /// @dev Plain substring test; both strings are short (a feed description and a ticker).
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; i++) {
            bool same = true;
            for (uint256 k; same && k < n.length; k++) {
                if (h[i + k] != n[k]) same = false;
            }
            if (same) return true;
        }
        return false;
    }
}
