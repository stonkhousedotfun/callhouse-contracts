// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FreezeV1} from "../../../script/v2/FreezeV1.s.sol";
import {AccountFactory} from "../../../src/solo/AccountFactory.sol";
import {WriterAccount} from "../../../src/solo/Account.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockFeed} from "../../../src/mocks/MockFeed.sol";
import {MockClear} from "../../../src/mocks/MockClear.sol";
import {MockSeaport} from "../../../src/mocks/MockSeaport.sol";
import {IValoremClear} from "../../../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../../../src/interfaces/IChainlinkFeed.sol";
import {ISeaport, OrderComponents} from "../../../src/interfaces/ISeaport.sol";

/// @notice `script/v2/FreezeV1.s.sol` against two mock-backed v1 AccountFactories: both calls land on every
///         factory, a second run sends nothing, partial state is finished rather than repeated, the post-check
///         has teeth, and the refusals hold before anything is sent. The last tests pin the claims
///         docs/V1-RUNOFF.md makes about a frozen market (a listed lot stops filling at once, lifting the halt
///         before the close revives it, settle/withdraw/claim still work, `list()` is refused).
/// @dev Driven through `runWith(Inputs)` for the reason test/unit/ConfigureSolo.t.sol gives: `vm.setEnv` writes
///      the environment every parallel test thread shares. Each test writes its batches under its own name.
///      Same setup and constants as test/unit/SoloAccount.t.sol (NVDA 220 USDG, strike 231, ask 1.90).
contract FreezeV1Test is Test {
    uint256 internal constant GUARDIAN_PK = 0x6A;
    uint256 internal constant ADMIN_PK = 0xAD;
    uint256 internal constant CAP = 20e18;
    uint256 internal constant STRIKE = 231_000_000;
    uint256 internal constant ASK = 1_900_000;

    address internal guardian = vm.addr(GUARDIAN_PK);
    address internal admin = vm.addr(ADMIN_PK);
    address internal keeper = makeAddr("keeper");
    address internal feeSafe = makeAddr("feeSafe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buyer = makeAddr("buyer");

    MockStockToken internal nvda;
    MockERC20 internal usdg;
    MockClear internal mockClear;
    MockSeaport internal mockSeaport;
    AccountFactory internal nvdaFactory;
    AccountFactory internal tslaFactory;

    uint40 internal exerciseTs;
    uint40 internal expiryTs;

    function setUp() public {
        vm.warp(1_789_000_000);
        nvda = new MockStockToken("NVDA Stock Token", "NVDAx");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        mockClear = new MockClear();
        mockSeaport = new MockSeaport();
        nvdaFactory = _factory(nvda, new MockFeed(8, 220_00000000, "NVDA / USD"));
        tslaFactory =
            _factory(new MockStockToken("Tesla Stock Token", "TSLA"), new MockFeed(8, 358_04000000, "TSLA / USD"));

        nvda.mint(alice, 10e18);
        nvda.mint(bob, 10e18);
        usdg.mint(buyer, 5_000_000_000);
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
    }

    function _factory(MockStockToken asset, MockFeed feed) internal returns (AccountFactory f) {
        f = new AccountFactory(
            IERC20(address(asset)),
            IERC20(address(usdg)),
            IValoremClear(address(mockClear)),
            ISeaport(address(mockSeaport)),
            IChainlinkFeed(address(feed)),
            6 hours,
            bytes32(0),
            admin,
            feeSafe,
            CAP
        );
        vm.startPrank(admin);
        f.grantRole(f.KEEPER_ROLE(), keeper);
        f.grantRole(f.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    function _inputs(string memory name) internal view returns (FreezeV1.Inputs memory in_) {
        in_.factories = new AccountFactory[](2);
        in_.factories[0] = nvdaFactory;
        in_.factories[1] = tslaFactory;
        in_.guardianPk = GUARDIAN_PK;
        in_.adminPk = ADMIN_PK;
        in_.guardianBatchOut = string.concat("broadcast/test-freeze-v1-", name, "-guardian.json");
        in_.adminBatchOut = string.concat("broadcast/test-freeze-v1-", name, "-admin.json");
    }

    function _frozen(AccountFactory f) internal view returns (bool) {
        return f.writesHalted() && f.depositCap() == 0;
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) n++;
        }
    }

    /// @dev Sends every transaction of a Transaction Builder batch from `sender`, as the Safe would.
    function _executeBatch(string memory path, address sender) internal returns (uint256 n) {
        string memory json = vm.readFile(path);
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(n), "]"))) {
            string memory base = string.concat(".transactions[", vm.toString(n), "]");
            vm.prank(sender);
            (bool ok,) = vm.parseJsonAddress(json, string.concat(base, ".to"))
                .call(vm.parseJsonBytes(json, string.concat(base, ".data")));
            assertTrue(ok, "batch call reverted");
            n++;
        }
    }

    /*//////////////////////////////////////////////////////////////
                               THE SCRIPT
    //////////////////////////////////////////////////////////////*/

    function test_freezesEveryFactory_withKeys_andPostChecks() public {
        FreezeV1.Inputs memory in_ = _inputs("keys");
        vm.recordLogs();
        (uint256 executed, uint256 skipped, uint256 batched, bool postChecked) = new FreezeV1().runWith(in_);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(executed, 4, "a halt and a cap on each of two factories");
        assertEq(skipped, 0);
        assertEq(batched, 0, "both keys present: nothing left to a Safe");
        assertTrue(postChecked, "post-check ran and passed");
        assertTrue(_frozen(nvdaFactory) && _frozen(tslaFactory), "both frozen");
        assertEq(_count(logs, AccountFactory.WritesHalted.selector), 2, "two WritesHalted events");
        assertEq(_count(logs, AccountFactory.DepositCapSet.selector), 2, "two DepositCapSet events");

        // The files hold the same calls the keys sent, split by the role that must send them.
        string memory g = vm.readFile(in_.guardianBatchOut);
        assertEq(vm.parseJsonString(g, ".version"), "1.0");
        assertEq(vm.parseJsonString(g, ".transactions[0].to"), vm.toString(address(nvdaFactory)));
        assertEq(vm.parseJsonBytes(g, ".transactions[1].data"), abi.encodeCall(AccountFactory.setWritesHalted, (true)));
        assertFalse(vm.keyExistsJson(g, ".transactions[2]"), "one halt per factory");
        string memory a = vm.readFile(in_.adminBatchOut);
        assertEq(vm.parseJsonString(a, ".transactions[1].to"), vm.toString(address(tslaFactory)));
        assertEq(vm.parseJsonBytes(a, ".transactions[0].data"), abi.encodeCall(AccountFactory.setDepositCap, (0)));
    }

    /// @dev "Already halted" and "already 0" are logged, not re-sent: no event, nothing executed, and the
    ///      post-check still runs, which is what makes a key-less re-run the verification step.
    function test_secondRun_isIdempotent() public {
        FreezeV1.Inputs memory in_ = _inputs("idempotent");
        new FreezeV1().runWith(in_);

        vm.recordLogs();
        (uint256 executed, uint256 skipped, uint256 batched, bool postChecked) = new FreezeV1().runWith(in_);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(executed, 0, "nothing sent the second time");
        assertEq(skipped, 4, "every call reported as already done");
        assertEq(batched, 0);
        assertTrue(postChecked);
        assertEq(_count(logs, AccountFactory.WritesHalted.selector), 0, "no WritesHalted event");
        assertEq(_count(logs, AccountFactory.DepositCapSet.selector), 0, "no DepositCapSet event");

        // Without keys too: nothing to build, nothing to batch, and the post-check passes.
        in_.guardianPk = 0;
        in_.adminPk = 0;
        (executed, skipped, batched, postChecked) = new FreezeV1().runWith(in_);
        assertEq(executed + batched, 0);
        assertEq(skipped, 4);
        assertTrue(postChecked, "a key-less run on frozen factories is the check");
    }

    /// @dev A half-finished freeze (the guardian halted NVDA, the admin zeroed TSLA's cap) is finished, not
    ///      repeated: exactly the two missing calls go out.
    function test_partialState_sendsOnlyWhatIsMissing() public {
        vm.prank(guardian);
        nvdaFactory.setWritesHalted(true);
        vm.prank(admin);
        tslaFactory.setDepositCap(0);

        FreezeV1.Inputs memory in_ = _inputs("partial");
        vm.recordLogs();
        (uint256 executed, uint256 skipped,, bool postChecked) = new FreezeV1().runWith(in_);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(executed, 2, "TSLA's halt and NVDA's cap");
        assertEq(skipped, 2, "NVDA's halt and TSLA's cap");
        assertTrue(postChecked);
        assertEq(_count(logs, AccountFactory.WritesHalted.selector), 1);
        assertEq(_count(logs, AccountFactory.DepositCapSet.selector), 1);

        string memory g = vm.readFile(in_.guardianBatchOut);
        assertEq(vm.parseJsonString(g, ".transactions[0].to"), vm.toString(address(tslaFactory)));
        assertFalse(vm.keyExistsJson(g, ".transactions[1]"), "only the missing halt is in the batch");
    }

    /// @dev No keys: both batches written, nothing sent, no post-check (it would fail). The Safes execute the
    ///      exact files, and the key-less re-run then skips all four and post-checks.
    function test_batchMode_sendsNothing_thenTheReRunChecks() public {
        FreezeV1.Inputs memory in_ = _inputs("batch");
        in_.guardianPk = 0;
        in_.adminPk = 0;
        in_.safeGuardian = guardian;
        in_.safeAdmin = admin;
        (uint256 executed, uint256 skipped, uint256 batched, bool postChecked) = new FreezeV1().runWith(in_);
        assertEq(executed, 0, "nothing broadcast without keys");
        assertEq(skipped, 0);
        assertEq(batched, 4);
        assertFalse(postChecked, "post-check deferred until the batches are executed");
        assertFalse(nvdaFactory.writesHalted() || tslaFactory.writesHalted(), "no halt in batch mode");
        assertEq(nvdaFactory.depositCap(), CAP, "no cap change in batch mode");
        assertEq(
            vm.parseJsonString(vm.readFile(in_.guardianBatchOut), ".meta.createdFromSafeAddress"), vm.toString(guardian)
        );

        assertEq(_executeBatch(in_.guardianBatchOut, guardian), 2, "guardian batch: two halts");
        assertEq(_executeBatch(in_.adminBatchOut, admin), 2, "admin batch: two caps");

        (executed, skipped, batched, postChecked) = new FreezeV1().runWith(in_);
        assertEq(executed + batched, 0);
        assertEq(skipped, 4);
        assertTrue(postChecked);
    }

    /// @dev One key, one Safe: the guardian key halts now, the admin's caps wait in the batch, and the
    ///      post-check is deferred rather than failed.
    function test_mixedMode_guardianKeyAdminSafe() public {
        FreezeV1.Inputs memory in_ = _inputs("mixed");
        in_.adminPk = 0;
        (uint256 executed,, uint256 batched, bool postChecked) = new FreezeV1().runWith(in_);
        assertEq(executed, 2);
        assertEq(batched, 2);
        assertFalse(postChecked);
        assertTrue(nvdaFactory.writesHalted() && tslaFactory.writesHalted(), "sales stopped");
        assertEq(tslaFactory.depositCap(), CAP, "caps wait for the admin Safe");
    }

    /// @dev The post-check fails on a factory that is not frozen, check by check. Unfrozen, the probe's
    ///      deposit(1) fails on the token allowance, not the cap, so the third check fails too.
    function test_postCheck_hasTeeth() public {
        AccountFactory[] memory one = new AccountFactory[](1);
        one[0] = nvdaFactory;
        FreezeV1 script = new FreezeV1();
        assertEq(script.postCheck(one), 3, "not halted, cap not 0, deposit not refused by the cap");

        vm.prank(guardian);
        nvdaFactory.setWritesHalted(true);
        assertEq(script.postCheck(one), 2, "halted only: the cap and the probe still fail");

        vm.prank(admin);
        nvdaFactory.setDepositCap(0);
        assertEq(script.postCheck(one), 0, "frozen");

        // The probe is the error the code has, nothing looser: deposit(1) as the probe owner.
        WriterAccount probe = nvdaFactory.accountOf(script.PROBE_OWNER());
        assertTrue(address(probe) != address(0), "the probe account exists after a post-check");
        vm.prank(script.PROBE_OWNER());
        vm.expectRevert(WriterAccount.DepositCapExceeded.selector);
        probe.deposit(1);
    }

    function test_refusesAKeyWithoutItsRole_beforeSendingAnything() public {
        FreezeV1.Inputs memory in_ = _inputs("norole");
        in_.guardianPk = 0xBAD;
        FreezeV1 script = new FreezeV1();
        vm.expectRevert(
            bytes(
                string.concat(
                    "GUARDIAN_PK ",
                    vm.toString(vm.addr(0xBAD)),
                    " does not hold GUARDIAN_ROLE on ",
                    vm.toString(address(nvdaFactory))
                )
            )
        );
        script.runWith(in_);
        assertEq(nvdaFactory.depositCap(), CAP, "the admin's valid calls were not sent either");

        // The admin key is not the guardian: a key with the wrong role is refused just the same.
        in_ = _inputs("wrongrole");
        in_.adminPk = GUARDIAN_PK;
        vm.expectRevert(
            bytes(
                string.concat(
                    "ADMIN_PK ",
                    vm.toString(guardian),
                    " does not hold DEFAULT_ADMIN_ROLE on ",
                    vm.toString(address(nvdaFactory))
                )
            )
        );
        script.runWith(in_);
        assertFalse(nvdaFactory.writesHalted(), "nothing halted");

        // A named Safe that does not hold the role is refused too: its batch could only revert.
        in_ = _inputs("safenorole");
        in_.guardianPk = 0;
        in_.safeGuardian = makeAddr("notTheGuardianSafe");
        vm.expectRevert(
            bytes(
                string.concat(
                    "SAFE_GUARDIAN ",
                    vm.toString(in_.safeGuardian),
                    " does not hold GUARDIAN_ROLE on ",
                    vm.toString(address(nvdaFactory))
                )
            )
        );
        script.runWith(in_);
    }

    function test_refusesBadFactoryLists() public {
        FreezeV1 script = new FreezeV1();
        FreezeV1.Inputs memory in_ = _inputs("bad");

        in_.factories = new AccountFactory[](0);
        vm.expectRevert(bytes("V1_FACTORIES is empty"));
        script.runWith(in_);

        in_.factories = new AccountFactory[](2);
        in_.factories[0] = nvdaFactory;
        in_.factories[1] = nvdaFactory;
        vm.expectRevert(bytes(string.concat("factory listed twice: ", vm.toString(address(nvdaFactory)))));
        script.runWith(in_);

        in_.factories[1] = AccountFactory(makeAddr("eoa"));
        vm.expectRevert(bytes(string.concat("no code at ", vm.toString(makeAddr("eoa")))));
        script.runWith(in_);

        in_.factories[1] = AccountFactory(address(usdg)); // code, but not a factory
        vm.expectRevert(bytes(string.concat("not an AccountFactory: ", vm.toString(address(usdg)))));
        script.runWith(in_);
        assertFalse(nvdaFactory.writesHalted(), "nothing sent for the good factory either");
    }

    /*//////////////////////////////////////////////////////////////
                  WHAT A FROZEN MARKET DOES (V1-RUNOFF.md)
    //////////////////////////////////////////////////////////////*/

    function _openAndList(address who, uint64 lots) internal returns (WriterAccount account) {
        vm.prank(who);
        account = nvdaFactory.createAccount();
        vm.startPrank(who);
        nvda.approve(address(account), type(uint256).max);
        account.deposit(5e18);
        account.requestWrite(lots);
        vm.stopPrank();
        vm.prank(keeper);
        nvdaFactory.listFor(who);
    }

    function _fill(WriterAccount account, uint256 salt) internal {
        OrderComponents memory c = account.lotOrder(salt);
        vm.startPrank(buyer);
        usdg.approve(address(mockSeaport), type(uint256).max);
        mockSeaport.fulfil(c, 1);
        vm.stopPrank();
    }

    function _freeze() internal {
        new FreezeV1().runWith(_inputs("market"));
        assertTrue(_frozen(nvdaFactory));
    }

    /// @dev The halt is immediate: a lot listed before the freeze does NOT stay fillable until `exerciseTs`,
    ///      because `authorizeOrder` reads `writesHalted()` on every fill. What was sold before stays sold and
    ///      exercisable, `settle()` runs at the account's expiry, and the writer can take everything home.
    function test_frozenMarket_listedLotStopsFilling_soldLotRunsOff() public {
        vm.prank(keeper);
        nvdaFactory.setWeek(STRIKE, exerciseTs, expiryTs, ASK);
        WriterAccount a = _openAndList(alice, 2);
        _fill(a, 0);
        assertEq(a.contractsWritten(), 1, "one lot sold before the freeze");

        _freeze();

        OrderComponents memory lot1 = a.lotOrder(1);
        vm.prank(buyer);
        vm.expectRevert(WriterAccount.WritesAreHalted.selector);
        mockSeaport.fulfil(lot1, 1);
        assertEq(a.idleAssets(), 3e18, "the unsold lot stays reserved until settle");

        vm.prank(alice);
        vm.expectRevert(WriterAccount.DepositCapExceeded.selector);
        a.deposit(1);

        // The buyer's option is Valorem's, not the factory's: exercise works inside the window.
        vm.warp(exerciseTs);
        vm.startPrank(buyer);
        usdg.approve(address(mockClear), type(uint256).max);
        mockClear.exercise(a.optionId(), 1);
        vm.stopPrank();

        vm.warp(a.listedExpiryTs() - 1);
        vm.expectRevert(WriterAccount.TooEarly.selector);
        a.settle();
        vm.warp(a.listedExpiryTs());
        vm.prank(makeAddr("stranger"));
        a.settle();
        assertEq(nvdaFactory.liveCount(), 0, "drained");
        assertEq(usdg.balanceOf(address(a)), STRIKE, "strike landed");
        assertEq(a.idleAssets(), 4e18, "the unsold lot is released");

        vm.startPrank(alice);
        a.withdraw(4e18);
        a.claimUsdg();
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 9e18, "all NVDA home but the assigned lot");
    }

    /// @dev The halt is the only thing holding a listed lot back: lifting it before `exerciseTs` makes the same
    ///      Seaport order fillable again. Leave `writesHalted` true for the whole run-off.
    function test_frozenMarket_liftingTheHaltRevivesListedLots() public {
        vm.prank(keeper);
        nvdaFactory.setWeek(STRIKE, exerciseTs, expiryTs, ASK);
        WriterAccount a = _openAndList(alice, 1);
        _freeze();

        vm.prank(guardian);
        nvdaFactory.setWritesHalted(false);
        _fill(a, 0);
        assertEq(a.contractsWritten(), 1, "sold after the halt was lifted, cap still 0");
    }

    /// @dev What the halt refuses and what it leaves alone for a writer with collateral and no listing.
    function test_frozenMarket_listRefused_requestWriteStillQueues() public {
        vm.prank(keeper);
        nvdaFactory.setWeek(STRIKE, exerciseTs, expiryTs, ASK);
        vm.prank(bob);
        WriterAccount b = nvdaFactory.createAccount();
        vm.startPrank(bob);
        nvda.approve(address(b), type(uint256).max);
        b.deposit(3e18);
        vm.stopPrank();

        _freeze();

        vm.prank(bob);
        b.requestWrite(2); // not gated by the halt: it only records a number and queues the account
        assertEq(nvdaFactory.pendingCount(), 1, "a frozen market can still gain pending entries");
        vm.prank(keeper);
        vm.expectRevert(WriterAccount.WritesAreHalted.selector);
        nvdaFactory.listFor(bob);
        vm.prank(bob);
        vm.expectRevert(WriterAccount.WritesAreHalted.selector);
        b.list();

        vm.prank(bob);
        b.requestWrite(0); // only the owner clears a pending entry
        assertEq(nvdaFactory.pendingCount(), 0);
        vm.prank(bob);
        b.withdraw(3e18);
        assertEq(nvda.balanceOf(bob), 10e18, "idle collateral is always withdrawable");
    }
}
