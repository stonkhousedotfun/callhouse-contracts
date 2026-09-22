// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {DeployHouseVault} from "../../../script/v2/DeployHouseVault.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {HouseVault} from "../../../src/v2/periphery/house/HouseVault.sol";
import {HouseVaultFactory} from "../../../src/v2/periphery/house/HouseVaultFactory.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {DeployV2Fixture} from "./DeployV2Fixture.t.sol";

/// @notice `script/v2/DeployHouseVault.s.sol` driven against the v8 set the shared fixture deploys (T-OP-141).
/// @dev THE SEQUENCE UNDER TEST IS THE REAL ONE, not a shortcut. After `_deploy()` the deployer holds nothing and the
///      Admin Safe holds ADMIN (48 h) and LISTING (1 h) with the manifest's delays, so:
///        1. the factory is a plain deploy (anyone) and its immutables are read back off the contract;
///        2. its `createVault` selector is UNMAPPED on the new factory (the fixture's `HouseVaultFactory` target is a
///           stand-in at another address), so the Safe first schedules `setTargetFunctionRole` for it -- the ADMIN
///           lane, exactly the row the script prints and refuses to send -- and the test plays the Safe;
///        3. the LISTING lane: `V2_SCHEDULE_PHASE=schedule` schedules `createVault`, the clock jumps past
///           `delaysS.LISTING`, `V2_SCHEDULE_PHASE=execute` calls the factory from the Safe, and the vault's Limits
///           equal the inputs.
///      Every delay is read from `roles.v8.json` through the script's own helpers, never typed here.
contract DeployHouseVaultTest is DeployV2Fixture {
    DeployHouseVault internal script;
    V2DeployBase.Contracts internal d;
    MockStockToken internal spcx;

    /// @dev The scratch limits file the env-driven tests write; `./broadcast` is the one read-write, gitignored
    ///      path in `fs_permissions`, so the test needs no grant of its own and leaves nothing in the tree.
    string internal constant LIMITS_PATH = "broadcast/house-limits.DeployHouseVaultTest.json";

    function setUp() public override {
        super.setUp();
        spcx = new MockStockToken("SpaceX Stock Token", "SPCX");
        d = _deploy();
        script = new DeployHouseVault();
    }

    /*//////////////////////////////////////////////////////////////
                                INPUTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Production-shaped limits, one per ticker and DIFFERENT per ticker, so a vault created with its
    ///      neighbour's limits (an index slip) fails the read-back instead of passing by coincidence.
    function _limits(uint256 i) internal pure returns (HouseVault.Limits memory l) {
        l.maxSeriesUnits = uint64(7_500 + i);
        l.maxTotalNotional = uint128(180_000e6 + i * 1e6);
        l.askToleranceBps = uint16(75 + i);
        l.maxBidBpsOfSpot = uint16(900 + i);
        l.maxOrderLifetime = uint32(1_800 + i);
        l.maxDailyOutflow = uint128(1_750e6 + i * 1e6);
    }

    /// @dev The limits file in the shape the script documents: `{ "<TICKER>": { six fields } }`.
    function _writeLimitsFile(string[] memory tickers) internal returns (string memory path) {
        path = LIMITS_PATH;
        vm.createDir("broadcast", true); // a fresh worktree has no broadcast/ yet; gitignored, read-write
        string memory root = "{}";
        for (uint256 i; i < tickers.length; ++i) {
            HouseVault.Limits memory l = _limits(i);
            string memory key = string.concat("lim", tickers[i]);
            vm.serializeUint(key, "maxSeriesUnits", l.maxSeriesUnits);
            vm.serializeUint(key, "maxTotalNotional", l.maxTotalNotional);
            vm.serializeUint(key, "askToleranceBps", l.askToleranceBps);
            vm.serializeUint(key, "maxBidBpsOfSpot", l.maxBidBpsOfSpot);
            vm.serializeUint(key, "maxOrderLifetime", l.maxOrderLifetime);
            string memory obj = vm.serializeUint(key, "maxDailyOutflow", l.maxDailyOutflow);
            root = vm.serializeString("limitsRoot", tickers[i], obj);
        }
        vm.writeJson(root, path);
    }

    function _inputs(address[] memory underlyings, string[] memory tickers)
        internal
        view
        returns (DeployHouseVault.Inputs memory in_)
    {
        in_.manager = d.accessManager;
        in_.orderBook = d.orderBook;
        in_.calendar = d.expiryCalendar;
        in_.oracle = d.settlementOracle;
        in_.splitter = d.feeSplitter;
        in_.adminSafe = adminSafe;
        in_.tickers = tickers;
        in_.underlyings = underlyings;
        in_.limits = new HouseVault.Limits[](tickers.length);
        for (uint256 i; i < tickers.length; ++i) {
            in_.limits[i] = _limits(i);
        }
        in_.limitsFile = "<inputs built in-test>";
    }

    function _one() internal view returns (DeployHouseVault.Inputs memory) {
        address[] memory u = new address[](1);
        u[0] = address(nvda);
        string[] memory t = new string[](1);
        t[0] = "NVDA";
        return _inputs(u, t);
    }

    function _two() internal view returns (DeployHouseVault.Inputs memory) {
        address[] memory u = new address[](2);
        u[0] = address(nvda);
        u[1] = address(spcx);
        string[] memory t = new string[](2);
        t[0] = "NVDA";
        t[1] = "SPCX";
        return _inputs(u, t);
    }

    function _nobody() internal pure returns (DeployHouseVault.SafeAuth memory a) {
        a.safe = V2DeployBase.Signer({pk: 0, addr: address(0)});
    }

    function _safe(bool scheduleOn, string memory phase) internal view returns (DeployHouseVault.SafeAuth memory a) {
        a.safe = _signer(adminSafe);
        a.scheduleOn = scheduleOn;
        a.phase = phase;
    }

    /*//////////////////////////////////////////////////////////////
                         THE ADMIN LANE, PLAYED BY THE TEST
    //////////////////////////////////////////////////////////////*/

    /// @dev The Safe schedules every mapping row the script printed, waits `delaysS.ADMIN`, executes. This is the
    ///      T-OP-116 mapping sub-step; the test plays it so the LISTING lane below has a mapped target to hit.
    function _mapAsSafe(address factory, string[] memory tickers, address[] memory vaults) internal {
        V2DeployBase.Call[] memory rows = script.mappingCalls(d.accessManager, factory, tickers, vaults);
        AccessManager mgr = AccessManager(d.accessManager);
        uint32 delay = script.roleDelayOf(script.rolesJson(), "ADMIN");
        for (uint256 i; i < rows.length; ++i) {
            vm.prank(adminSafe);
            mgr.schedule(rows[i].to, rows[i].data, 0);
        }
        vm.warp(block.timestamp + delay + 1);
        for (uint256 i; i < rows.length; ++i) {
            vm.prank(adminSafe);
            mgr.execute(rows[i].to, rows[i].data);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice AC1: the factory's immutables equal the inputs, read back off the deployed contract.
    function test_factoryImmutablesEqualInputs() public {
        DeployHouseVault.Built memory b = script.runWith(_one(), _signer(deployer), _nobody());
        HouseVaultFactory f = HouseVaultFactory(b.factory);
        assertEq(f.authority(), d.accessManager, "authority");
        assertEq(address(f.orderBook()), d.orderBook, "orderBook");
        assertEq(address(f.calendar()), d.expiryCalendar, "calendar");
        assertEq(address(f.oracle()), d.settlementOracle, "oracle");
        assertEq(f.splitter(), d.feeSplitter, "splitter");
        assertEq(f.vaults().length, 0, "no vault was created without a Safe signer");
    }

    /// @notice AC3: with nobody able to act as the Safe, the script deploys the factory, sends NO vault call, and
    ///         reports the pending LISTING calls with their delay.
    function test_noSafeSigner_printsAndSendsNothing() public {
        DeployHouseVault.Inputs memory in_ = _two();
        DeployHouseVault.Built memory b = script.runWith(in_, _signer(deployer), _nobody());
        assertTrue(b.safeActionRequired, "safeActionRequired");
        assertEq(b.vaults[0], address(0), "NVDA vault not created");
        assertEq(b.vaults[1], address(0), "SPCX vault not created");
        V2DeployBase.Call[] memory calls = script.createVaultCalls(in_, b.factory);
        assertEq(calls.length, 2, "one createVault per launch ticker");
        assertEq(calls[0].to, b.factory, "the call targets the factory, not the manager");
        assertEq(bytes32(bytes4(calls[0].data)), bytes32(HouseVaultFactory.createVault.selector), "selector");
        assertEq(script.roleDelayOf(script.rolesJson(), "LISTING"), 3600, "LISTING delay read from the manifest");
    }

    /// @notice AC3: a delayed LISTING holder cannot create in a single run; the refusal names the phase contract.
    function test_delayedSafe_singleRunRefused() public {
        DeployHouseVault.Inputs memory in_ = _one();
        // deploy + map first so canCall answers "delayed" rather than "unmapped"
        DeployHouseVault.Built memory b = script.runWith(in_, _signer(deployer), _nobody());
        _mapAsSafe(b.factory, in_.tickers, b.vaults);
        in_.factory = b.factory;
        try script.runWith(in_, _signer(deployer), _safe(false, "")) {
            fail("a delayed LISTING holder must not create in a single run");
        } catch Error(string memory reason) {
            _expect(reason, "a delayed LISTING call cannot be sent by a single run");
            _expect(reason, "V2_SCHEDULE_PHASE=schedule");
        }
        assertEq(HouseVaultFactory(b.factory).vaults().length, 0, "nothing was created");
    }

    /// @notice AC3, the fork shape: schedule -> clock past delaysS.LISTING -> execute; the vault's Limits equal
    ///         the inputs and the factory indexes it.
    function test_scheduleThenExecute_createsVaultsWithInputLimits() public {
        DeployHouseVault.Inputs memory in_ = _two();
        DeployHouseVault.Built memory b = script.runWith(in_, _signer(deployer), _nobody());
        _mapAsSafe(b.factory, in_.tickers, b.vaults);
        in_.factory = b.factory;

        DeployHouseVault.Built memory s1 = script.runWith(in_, _signer(deployer), _safe(true, "schedule"));
        assertEq(s1.factory, b.factory, "the factory is reused, not redeployed");
        assertTrue(s1.safeActionRequired, "scheduled is not created");
        assertEq(s1.vaults[0], address(0), "no vault after the schedule phase");

        vm.warp(block.timestamp + script.roleDelayOf(script.rolesJson(), "LISTING") + 1);
        DeployHouseVault.Built memory s2 = script.runWith(in_, _signer(deployer), _safe(true, "execute"));
        assertFalse(s2.safeActionRequired, "executed");
        assertTrue(s2.vaults[0] != address(0) && s2.vaults[1] != address(0), "both vaults created");
        assertEq(HouseVaultFactory(b.factory).vaultOf(address(nvda)), s2.vaults[0], "factory indexes NVDA");
        assertEq(HouseVaultFactory(b.factory).vaultOf(address(spcx)), s2.vaults[1], "factory indexes SPCX");

        HouseVault.Limits memory want = _limits(1);
        HouseVault.Limits memory got = HouseVault(s2.vaults[1]).limits();
        assertEq(got.maxSeriesUnits, want.maxSeriesUnits, "maxSeriesUnits");
        assertEq(got.maxTotalNotional, want.maxTotalNotional, "maxTotalNotional");
        assertEq(got.askToleranceBps, want.askToleranceBps, "askToleranceBps");
        assertEq(got.maxBidBpsOfSpot, want.maxBidBpsOfSpot, "maxBidBpsOfSpot");
        assertEq(got.maxOrderLifetime, want.maxOrderLifetime, "maxOrderLifetime");
        assertEq(got.maxDailyOutflow, want.maxDailyOutflow, "maxDailyOutflow");
        assertEq(HouseVault(s2.vaults[1]).name(), "Stonkhouse House SPCX", "name from the ticker");
        assertEq(HouseVault(s2.vaults[1]).symbol(), "hSPCX", "symbol from the ticker");
        assertEq(address(HouseVault(s2.vaults[0]).underlying()), address(nvda), "NVDA vault holds NVDA");

        // a second execute is a no-op: existing vaults are left alone, nothing reverts
        DeployHouseVault.Built memory s3 = script.runWith(in_, _signer(deployer), _safe(true, "execute"));
        assertEq(s3.vaults[0], s2.vaults[0], "idempotent");
    }

    /// @notice The T-OP-153 window / DevDeploy shape: when the DEPLOYER holds LISTING immediately (granted here by
    ///         the Safe through the ADMIN lane) and the factory is mapped, the script creates directly, no schedule.
    function test_deployerHoldsListingImmediately_createsDirectly() public {
        DeployHouseVault.Inputs memory in_ = _two();
        DeployHouseVault.Built memory b = script.runWith(in_, _signer(deployer), _nobody());
        AccessManager mgr = AccessManager(d.accessManager);
        uint32 adminDelay = script.roleDelayOf(script.rolesJson(), "ADMIN");
        uint64 listing = script.roleIdOf(script.rolesJson(), "LISTING");
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (listing, deployer, 0));
        vm.prank(adminSafe);
        mgr.schedule(d.accessManager, grant, 0);
        V2DeployBase.Call[] memory rows = script.mappingCalls(d.accessManager, b.factory, in_.tickers, b.vaults);
        for (uint256 i; i < rows.length; ++i) {
            vm.prank(adminSafe);
            mgr.schedule(rows[i].to, rows[i].data, 0);
        }
        vm.warp(block.timestamp + adminDelay + 1);
        vm.prank(adminSafe);
        mgr.execute(d.accessManager, grant);
        for (uint256 i; i < rows.length; ++i) {
            vm.prank(adminSafe);
            mgr.execute(rows[i].to, rows[i].data);
        }
        (bool immediate,) = mgr.canCall(deployer, b.factory, HouseVaultFactory.createVault.selector);
        assertTrue(immediate, "precondition: the deployer holds LISTING at delay 0 and the factory is mapped");

        in_.factory = b.factory;
        DeployHouseVault.Built memory s2 = script.runWith(in_, _signer(deployer), _nobody());
        assertFalse(s2.safeActionRequired, "created by the deployer, nothing pending");
        assertTrue(s2.vaults[0] != address(0) && s2.vaults[1] != address(0), "both vaults created");
        assertEq(HouseVault(s2.vaults[0]).limits().maxSeriesUnits, _limits(0).maxSeriesUnits, "NVDA limits");
        assertEq(HouseVault(s2.vaults[1]).limits().maxSeriesUnits, _limits(1).maxSeriesUnits, "SPCX limits");
    }

    /// @notice A partial answer (one ticker immediate, the other not) sends NOTHING: the launch set is created
    ///         whole or not at all by the deployer path.
    function test_deployerPath_partialImmediacySendsNothing() public {
        DeployHouseVault.Inputs memory in_ = _two();
        DeployHouseVault.Built memory b = script.runWith(in_, _signer(deployer), _nobody());
        // grant LISTING to the deployer but leave the factory UNMAPPED: canCall answers (false, 0) for both
        AccessManager mgr = AccessManager(d.accessManager);
        bytes memory grant =
            abi.encodeCall(AccessManager.grantRole, (script.roleIdOf(script.rolesJson(), "LISTING"), deployer, 0));
        vm.prank(adminSafe);
        mgr.schedule(d.accessManager, grant, 0);
        vm.warp(block.timestamp + script.roleDelayOf(script.rolesJson(), "ADMIN") + 1);
        vm.prank(adminSafe);
        mgr.execute(d.accessManager, grant);
        in_.factory = b.factory;
        DeployHouseVault.Built memory s2 = script.runWith(in_, _signer(deployer), _nobody());
        assertTrue(s2.safeActionRequired, "unmapped factory: nothing sent, calls printed");
        assertEq(HouseVaultFactory(b.factory).vaults().length, 0, "no vault");
    }

    /// @notice `V2_HOUSE_REQUIRE_VAULTS`: an uncreated vault becomes a revert naming the ticker (after the report).
    function test_requireVaults_revertsNamingTheTicker() public {
        DeployHouseVault.Inputs memory in_ = _two();
        DeployHouseVault.SafeAuth memory auth = _nobody();
        DeployHouseVault.Built memory b = script.runWith(in_, _signer(deployer), auth);
        auth.requireVaults = true;
        try script.requireCreated(in_, b, auth) {
            fail("must revert when a vault is missing and the flag is on");
        } catch Error(string memory reason) {
            _expect(reason, "V2_HOUSE_REQUIRE_VAULTS: HouseVault NVDA was not created");
        }
        auth.requireVaults = false;
        script.requireCreated(in_, b, auth); // the flag off: a report, not a revert
    }

    /// @notice AC4: the mapping rows are one per manifest signature per target instance, every `to` the manager,
    ///         and the script never sends them (proved by the unmapped state after {runWith}).
    function test_mappingRowsPrintedNotSent() public {
        DeployHouseVault.Inputs memory in_ = _one();
        DeployHouseVault.Built memory b = script.runWith(in_, _signer(deployer), _nobody());
        string memory json = script.rolesJson();
        uint256 fSigs = script.targetSigs(json, "HouseVaultFactory").length;
        V2DeployBase.Call[] memory rows = script.mappingCalls(d.accessManager, b.factory, in_.tickers, b.vaults);
        assertEq(rows.length, fSigs, "factory rows only while no vault exists");
        for (uint256 i; i < rows.length; ++i) {
            assertEq(rows[i].to, d.accessManager, "every row targets the manager");
            assertEq(
                bytes32(bytes4(rows[i].data)),
                bytes32(AccessManager.setTargetFunctionRole.selector),
                "setTargetFunctionRole"
            );
        }
        // not mapped by the script: a role-less caller gets neither immediate nor delayed ...
        (bool immediate, uint32 delay) =
            AccessManager(d.accessManager).canCall(deployer, b.factory, HouseVaultFactory.createVault.selector);
        assertFalse(immediate, "not mapped by the script");
        assertEq(delay, 0, "not mapped by the script: neither immediate nor delayed for a role-less caller");
        // ... while the Safe, which holds ADMIN, is answered the ADMIN delay: an unmapped selector defaults to
        // ADMIN_ROLE, which is exactly why the script refuses to schedule at any delay but delaysS.LISTING
        (immediate, delay) =
            AccessManager(d.accessManager).canCall(adminSafe, b.factory, HouseVaultFactory.createVault.selector);
        assertFalse(immediate, "unmapped is not immediate for the Safe either");
        assertEq(delay, script.roleDelayOf(script.rolesJson(), "ADMIN"), "unmapped selector answers to ADMIN");
    }

    /// @notice The ADMIN-default trap: a Safe that schedules createVault on an UNMAPPED factory would go through
    ///         the 48 h ADMIN lane and succeed. The script refuses that by name instead of scheduling it.
    function test_unmappedFactory_safeScheduleRefusedNotAdminLane() public {
        DeployHouseVault.Inputs memory in_ = _one();
        DeployHouseVault.Built memory b = script.runWith(in_, _signer(deployer), _nobody());
        in_.factory = b.factory; // mapping rows deliberately NOT executed
        try script.runWith(in_, _signer(deployer), _safe(true, "schedule")) {
            fail("scheduling through the ADMIN default must be refused");
        } catch Error(string memory reason) {
            _expect(reason, "not delaysS.LISTING");
            _expect(reason, "is not mapped to LISTING on this factory yet");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        THE LIMITS SEAM (file-driven)
    //////////////////////////////////////////////////////////////*/

    /// @notice AC2 (amended M-b02234cf247c4d5f): a well-formed file gives one Limits per launch ticker, in ticker
    ///         order, equal to the file; and the three STOPs -- missing file, missing ticker, missing field --
    ///         each name what is missing. One test, sequential, because the file path is shared state.
    function test_limitsSeam_fileDriven() public {
        string[] memory tickers = new string[](2);
        tickers[0] = "NVDA";
        tickers[1] = "SPCX";
        string memory path = _writeLimitsFile(tickers);

        // (a) the happy shape: per-ticker values read back exactly
        HouseVault.Limits[] memory ls = script.limitsFromFile(path, tickers);
        assertEq(ls.length, 2, "one per ticker");
        for (uint256 i; i < 2; ++i) {
            HouseVault.Limits memory want = _limits(i);
            assertEq(ls[i].maxSeriesUnits, want.maxSeriesUnits, "maxSeriesUnits");
            assertEq(ls[i].maxTotalNotional, want.maxTotalNotional, "maxTotalNotional");
            assertEq(ls[i].askToleranceBps, want.askToleranceBps, "askToleranceBps");
            assertEq(ls[i].maxBidBpsOfSpot, want.maxBidBpsOfSpot, "maxBidBpsOfSpot");
            assertEq(ls[i].maxOrderLifetime, want.maxOrderLifetime, "maxOrderLifetime");
            assertEq(ls[i].maxDailyOutflow, want.maxDailyOutflow, "maxDailyOutflow");
        }

        // (b) a launch ticker the file lacks STOPs naming the ticker
        string[] memory three = new string[](3);
        three[0] = "NVDA";
        three[1] = "SPCX";
        three[2] = "TSLA";
        try script.limitsFromFile(path, three) {
            fail("a ticker missing from the file must STOP");
        } catch Error(string memory reason) {
            _expect(reason, "has no entry for launch ticker TSLA");
        }

        // (c) a field the ticker's object lacks STOPs naming the ticker and the field
        string memory broken = "broadcast/house-limits.DeployHouseVaultTest.broken.json";
        vm.writeFile(
            broken,
            '{"NVDA":{"maxSeriesUnits":7500,"maxTotalNotional":180000000000,"askToleranceBps":75,"maxBidBpsOfSpot":900,"maxOrderLifetime":1800},"SPCX":{"maxSeriesUnits":1,"maxTotalNotional":1,"askToleranceBps":1,"maxBidBpsOfSpot":1,"maxOrderLifetime":1,"maxDailyOutflow":1}}'
        );
        try script.limitsFromFile(broken, tickers) {
            fail("a missing field must STOP");
        } catch Error(string memory reason) {
            _expect(reason, "NVDA has no maxDailyOutflow");
        }

        // (d) a missing file STOPs naming the env variable and the path
        string memory absent = "broadcast/house-limits.DeployHouseVaultTest.absent.json";
        vm.removeFile(broken);
        try script.limitsFromFile(absent, tickers) {
            fail("a missing file must STOP");
        } catch Error(string memory reason) {
            _expect(reason, "V2_HOUSE_LIMITS_FILE names ");
            _expect(reason, "which does not exist");
        }

        // (e) an unset variable STOPs by name
        try script.limitsFromFile("", tickers) {
            fail("an unset variable must STOP");
        } catch Error(string memory reason) {
            _expect(reason, "V2_HOUSE_LIMITS_FILE is not set");
        }
        vm.removeFile(path);
    }

    /*//////////////////////////////////////////////////////////////
                              PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @notice A source on another manager is refused by name before anything is deployed.
    function test_preflight_sourceOnAnotherManagerRefused() public {
        DeployHouseVault.Inputs memory in_ = _one();
        AccessManager other = new AccessManager(address(this));
        in_.orderBook = address(new StrangerManaged(address(other)));
        try script.preflight(in_) {
            fail("a book on another manager must be refused");
        } catch Error(string memory reason) {
            _expect(reason, "V2_ORDER_BOOK");
            _expect(reason, "not V2_ACCESS_MANAGER");
        }
    }

    /// @notice A 6-decimal underlying is refused by the ticker's own variable name.
    function test_preflight_sixDecimalUnderlyingRefused() public {
        DeployHouseVault.Inputs memory in_ = _one();
        in_.underlyings[0] = address(usdg);
        try script.preflight(in_) {
            fail("a 6-decimal underlying must be refused");
        } catch Error(string memory reason) {
            _expect(reason, "V2_MARKET_NVDA_ASSET");
            _expect(reason, "6 decimals, not 18");
        }
    }

    /// @notice A duplicate underlying across tickers is refused: the factory keeps one vault per underlying.
    function test_preflight_duplicateUnderlyingRefused() public {
        DeployHouseVault.Inputs memory in_ = _two();
        in_.underlyings[1] = address(nvda);
        try script.preflight(in_) {
            fail("a duplicate underlying must be refused");
        } catch Error(string memory reason) {
            _expect(reason, "V2_MARKET_SPCX_ASSET repeats an earlier ticker's asset");
        }
    }

    /// @dev The script's reasons carry addresses, so a whole-data revert match would pin the test to this run's
    ///      addresses; the tests catch `Error(string)` and require the named fragment instead.
    function _expect(string memory reason, string memory fragment) internal pure {
        assertTrue(
            vm.indexOf(reason, fragment) != type(uint256).max,
            string.concat("revert reason lacks '", fragment, "': ", reason)
        );
    }
}

/// @dev A `Managed`-shaped contract on some other authority, for the wrong-manager refusal.
contract StrangerManaged {
    address private immutable _authority;

    constructor(address authority_) {
        _authority = authority_;
    }

    function authority() external view returns (address) {
        return _authority;
    }
}
