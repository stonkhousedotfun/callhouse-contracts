// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConfigureSolo} from "../../script/ConfigureSolo.s.sol";
import {AccountFactory} from "../../src/solo/AccountFactory.sol";
import {PolicyParams} from "../../src/Policy.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockFeed} from "../../src/mocks/MockFeed.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {MockSeaport} from "../../src/mocks/MockSeaport.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {ISeaport} from "../../src/interfaces/ISeaport.sol";

/// @notice `script/ConfigureSolo.s.sol` against a mock-backed AccountFactory: the grants land, a second run
///         sends nothing, the cap moves only when it differs, and the refusals hold.
/// @dev Driven through `runWith(Inputs)`, the script's explicit-input entry, rather than `vm.setEnv` +
///      `run()`: `setEnv` writes the process environment that every parallel test thread shares, and this
///      script reads DEPOSIT_CAP, which the DeploySolo preflight test (the suite's one env-driven test)
///      also sets. `run()` is one line over `runWith` (`_inputsFromEnv`), and the fork rehearsal
///      (script/rehearse-solo.sh) runs it the real way, environment and all.
///      Each test writes its batch file under its own name: the tests run in parallel.
contract ConfigureSoloTest is Test {
    uint256 internal constant ADMIN_PK = 0xAD;
    uint256 internal constant CAP = 20e18;

    address internal admin = vm.addr(ADMIN_PK);
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal feeSafe = makeAddr("feeSafe");

    AccountFactory internal factory;

    function setUp() public {
        vm.warp(1_789_000_000);
        MockStockToken tsla = new MockStockToken("Tesla Stock Token", "TSLA");
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        factory = new AccountFactory(
            IERC20(address(tsla)),
            IERC20(address(usdg)),
            IValoremClear(address(new MockClear())),
            ISeaport(address(new MockSeaport())),
            IChainlinkFeed(address(new MockFeed(8, 358_04000000, "Robinhood TSLA / USD"))),
            4 days,
            bytes32(0),
            admin,
            feeSafe,
            CAP
        );
    }

    function _inputs(string memory name) internal view returns (ConfigureSolo.Inputs memory in_) {
        in_.factory = factory;
        in_.keeper = keeper;
        in_.guardian = guardian;
        in_.adminPk = ADMIN_PK;
        in_.batchOut = string.concat("broadcast/test-configure-solo-", name, ".json");
    }

    function _roleGrants(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IAccessControl.RoleGranted.selector) n++;
        }
    }

    function test_grantsBothRoles_andWritesTheBatch() public {
        ConfigureSolo.Inputs memory in_ = _inputs("grants");
        (uint256 executed, uint256 skipped) = new ConfigureSolo().runWith(in_);
        assertEq(executed, 2, "two grants broadcast");
        assertEq(skipped, 0);
        assertTrue(factory.hasRole(factory.KEEPER_ROLE(), keeper), "keeper granted");
        assertTrue(factory.hasRole(factory.GUARDIAN_ROLE(), guardian), "guardian granted");
        assertFalse(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), keeper), "keeper is not admin");
        assertEq(factory.depositCap(), CAP, "cap untouched when DEPOSIT_CAP is not set");

        // The batch file holds the same two calls a Safe would sign, in Transaction Builder shape.
        string memory json = vm.readFile(in_.batchOut);
        assertEq(vm.parseJsonString(json, ".version"), "1.0");
        assertEq(vm.parseJsonString(json, ".transactions[0].to"), vm.toString(address(factory)));
        assertEq(
            vm.parseJsonBytes(json, ".transactions[0].data"),
            abi.encodeCall(factory.grantRole, (factory.KEEPER_ROLE(), keeper))
        );
        assertEq(
            vm.parseJsonBytes(json, ".transactions[1].data"),
            abi.encodeCall(factory.grantRole, (factory.GUARDIAN_ROLE(), guardian))
        );
    }

    /// @dev The second run must not revert (AccessControl's grantRole would not either, but the script
    ///      skips instead of re-sending) and must emit nothing: "already granted" is logged, not broadcast.
    function test_secondRun_isIdempotent() public {
        ConfigureSolo.Inputs memory in_ = _inputs("idempotent");
        new ConfigureSolo().runWith(in_);

        vm.recordLogs();
        (uint256 executed, uint256 skipped) = new ConfigureSolo().runWith(in_);
        assertEq(executed, 0, "nothing broadcast the second time");
        assertEq(skipped, 2, "both grants reported as already granted");
        assertEq(_roleGrants(vm.getRecordedLogs()), 0, "no RoleGranted event on the second run");
        assertTrue(factory.hasRole(factory.KEEPER_ROLE(), keeper));
        assertTrue(factory.hasRole(factory.GUARDIAN_ROLE(), guardian));
    }

    function test_depositCap_appliedOnlyWhenDifferent() public {
        ConfigureSolo.Inputs memory in_ = _inputs("cap");
        in_.capSet = true;
        in_.depositCap = CAP; // equal to the constructor's: no call
        (uint256 executed, uint256 skipped) = new ConfigureSolo().runWith(in_);
        assertEq(executed, 2, "only the two grants");
        assertEq(skipped, 1, "the equal cap is skipped");
        assertEq(factory.depositCap(), CAP);

        in_.depositCap = 30e18; // different: one call, and the grants are now skipped
        (executed, skipped) = new ConfigureSolo().runWith(in_);
        assertEq(executed, 1, "just setDepositCap");
        assertEq(skipped, 2, "both grants already held");
        assertEq(factory.depositCap(), 30e18, "cap applied");

        in_.capSet = false; // not set at all: never touched, whatever it is
        in_.depositCap = 1;
        (executed, skipped) = new ConfigureSolo().runWith(in_);
        assertEq(executed, 0);
        assertEq(factory.depositCap(), 30e18, "unset DEPOSIT_CAP leaves the cap alone");
    }

    function test_setPolicy_appliedOnlyWhenDifferent() public {
        ConfigureSolo.Inputs memory in_ = _inputs("policy");
        in_.setPolicy = true;
        in_.policy = PolicyParams({
            minOtmBps: 300,
            maxOtmBps: 1200,
            minPremiumBps: 40,
            maxUtilizationBps: 9500,
            protocolFeeBps: 500,
            maxContractsCap: 50
        }); // launchDefaults, already installed by the constructor
        (uint256 executed, uint256 skipped) = new ConfigureSolo().runWith(in_);
        assertEq(executed, 2);
        assertEq(skipped, 1, "identical policy skipped");

        in_.policy.minPremiumBps = 10; // the live NVDA setting
        (executed, skipped) = new ConfigureSolo().runWith(in_);
        assertEq(executed, 1, "just setPolicy");
        (,, uint16 minPrem,,,) = factory.policy();
        assertEq(minPrem, 10, "policy applied");
    }

    function test_refusesAKeyWithoutAdmin() public {
        ConfigureSolo.Inputs memory in_ = _inputs("nonadmin");
        in_.adminPk = 0xBAD;
        ConfigureSolo script = new ConfigureSolo();
        vm.expectRevert(bytes("ADMIN_PK does not hold DEFAULT_ADMIN_ROLE"));
        script.runWith(in_);
        assertFalse(factory.hasRole(factory.KEEPER_ROLE(), keeper), "nothing granted");
    }

    function test_refusesKeeperEqualToGuardian() public {
        ConfigureSolo.Inputs memory in_ = _inputs("same");
        in_.guardian = keeper;
        ConfigureSolo script = new ConfigureSolo();
        vm.expectRevert(bytes("keeper and guardian must be different keys"));
        script.runWith(in_);
    }

    /// @dev The keeper is a hot key; it must never be the admin, in either mode.
    function test_refusesKeeperEqualToAdmin() public {
        ConfigureSolo.Inputs memory in_ = _inputs("keeperadmin");
        in_.keeper = admin;
        ConfigureSolo script = new ConfigureSolo();
        vm.expectRevert(bytes("keeper and guardian must differ from the admin"));
        script.runWith(in_);

        in_ = _inputs("guardianadmin-batch");
        in_.adminPk = 0;
        in_.safeAdmin = admin;
        in_.guardian = admin;
        vm.expectRevert(bytes("keeper and guardian must differ from the admin"));
        script.runWith(in_);
    }

    function test_batchMode_broadcastsNothing() public {
        ConfigureSolo.Inputs memory in_ = _inputs("batch");
        in_.adminPk = 0;
        in_.safeAdmin = makeAddr("safe");
        (uint256 executed, uint256 skipped) = new ConfigureSolo().runWith(in_);
        assertEq(executed, 0, "nothing broadcast without ADMIN_PK");
        assertEq(skipped, 0);
        assertFalse(factory.hasRole(factory.KEEPER_ROLE(), keeper), "no grant in batch mode");
        string memory json = vm.readFile(in_.batchOut);
        assertEq(vm.parseJsonString(json, ".meta.createdFromSafeAddress"), vm.toString(in_.safeAdmin));
        assertEq(vm.parseJsonString(json, ".transactions[1].to"), vm.toString(address(factory)));
    }
}
