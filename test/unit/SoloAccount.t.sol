// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccountFactory} from "../../src/solo/AccountFactory.sol";
import {WriterAccount} from "../../src/solo/Account.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockFeed} from "../../src/mocks/MockFeed.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {MockSeaport} from "../../src/mocks/MockSeaport.sol";
import {ValoremLib} from "../../src/lib/ValoremLib.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {ISeaport, OrderComponents} from "../../src/interfaces/ISeaport.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Isolated 1-lot accounts: a fill and an assignment on Alice never move Bob's NVDA.
contract SoloAccountTest is Test {
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal feeSafe = makeAddr("feeSafe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buyer = makeAddr("buyer");

    MockStockToken internal nvda;
    MockERC20 internal usdg;
    MockClear internal mockClear;
    MockSeaport internal mockSeaport;
    MockFeed internal feed;
    AccountFactory internal factory;

    uint256 internal constant SPOT_USDG = 220_000_000;
    int256 internal constant SPOT_FEED = 220_00000000;
    uint256 internal constant STRIKE = 231_000_000;
    uint256 internal constant ASK = 1_900_000;
    uint256 internal constant LOT = 1e18;
    uint256 internal constant FEE = 95_000; // 5% of 1_900_000
    uint256 internal constant SELLER = 1_805_000;

    uint40 internal exerciseTs;
    uint40 internal expiryTs;

    function setUp() public {
        vm.warp(1_789_000_000);
        nvda = new MockStockToken("NVDA Stock Token", "NVDAx");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        mockClear = new MockClear();
        mockSeaport = new MockSeaport();
        feed = new MockFeed(8, SPOT_FEED, "NVDA / USD");

        nvda.mint(alice, 10e18);
        nvda.mint(bob, 10e18);
        usdg.mint(buyer, 5_000_000_000);

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);

        factory = new AccountFactory(
            IERC20(address(nvda)),
            IERC20(address(usdg)),
            IValoremClear(address(mockClear)),
            ISeaport(address(mockSeaport)),
            IChainlinkFeed(address(feed)),
            6 hours,
            bytes32(0),
            admin,
            feeSafe,
            20e18
        );

        vm.startPrank(admin);
        factory.grantRole(factory.KEEPER_ROLE(), keeper);
        factory.grantRole(factory.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    function _open(address who) internal returns (WriterAccount account) {
        vm.prank(who);
        account = factory.createAccount();
        vm.startPrank(who);
        nvda.approve(address(account), type(uint256).max);
        account.deposit(5e18);
        vm.stopPrank();
    }

    function _week() internal {
        vm.prank(keeper);
        factory.setWeek(STRIKE, exerciseTs, expiryTs, ASK);
    }

    function _list(address who, uint64 lots) internal returns (WriterAccount account) {
        account = factory.accountOf(who);
        vm.prank(who);
        account.requestWrite(lots);
        vm.prank(keeper);
        factory.listFor(who);
    }

    function _fillLot(WriterAccount account, uint256 salt) internal {
        OrderComponents memory c = account.lotOrder(salt);
        vm.startPrank(buyer);
        usdg.approve(address(mockSeaport), type(uint256).max);
        mockSeaport.fulfil(c, 1);
        vm.stopPrank();
    }

    function test_createDepositWithdraw() public {
        WriterAccount a = _open(alice);
        assertEq(nvda.balanceOf(address(a)), 5e18);
        vm.prank(alice);
        a.withdraw(2e18);
        assertEq(nvda.balanceOf(alice), 7e18);
        assertEq(a.idleAssets(), 3e18);
    }

    function test_uniqueOptionTypes() public {
        _open(alice);
        _open(bob);
        _week();
        WriterAccount a = _list(alice, 1);
        WriterAccount b = _list(bob, 1);
        assertTrue(a.optionId() != b.optionId(), "each account has its own Valorem type");
        assertEq(a.index() + 1, b.index());
    }

    function test_fillPaysAliceNotBob() public {
        _open(alice);
        _open(bob);
        _week();
        WriterAccount a = _list(alice, 1);
        WriterAccount b = _list(bob, 1);

        uint256 aliceUsdgBefore = usdg.balanceOf(alice);
        uint256 bobNvdaBefore = nvda.balanceOf(address(b));
        uint256 feeBefore = usdg.balanceOf(feeSafe);

        _fillLot(a, 0);

        assertEq(usdg.balanceOf(alice) - aliceUsdgBefore, SELLER, "premium to Alice");
        assertEq(usdg.balanceOf(feeSafe) - feeBefore, FEE, "protocol fee");
        assertEq(nvda.balanceOf(address(b)), bobNvdaBefore, "Bob's NVDA untouched");
        assertEq(a.contractsWritten(), 1);
        assertEq(b.contractsWritten(), 0);
        assertEq(nvda.balanceOf(address(a)), 4e18, "Alice's filled lot left for Valorem");
        assertEq(a.reserved(), 0);
        assertEq(b.reserved(), 1e18);
    }

    function test_unfilledReturnsNvda() public {
        _open(alice);
        _week();
        WriterAccount a = _list(alice, 2);
        assertEq(a.idleAssets(), 3e18);
        vm.prank(alice);
        vm.expectRevert(WriterAccount.InsufficientIdle.selector);
        a.withdraw(4e18);

        vm.warp(expiryTs + a.index());
        a.settle();
        assertEq(a.reserved(), 0);
        assertEq(a.listedLots(), 0);
        assertEq(a.idleAssets(), 5e18);
        vm.prank(alice);
        a.withdraw(5e18);
        assertEq(nvda.balanceOf(alice), 10e18);
    }

    function test_exerciseAssignsOnlyAlice() public {
        _open(alice);
        _open(bob);
        _week();
        WriterAccount a = _list(alice, 1);
        WriterAccount b = _list(bob, 1);

        _fillLot(a, 0);
        assertEq(nvda.balanceOf(address(b)), 5e18);

        vm.warp(exerciseTs);
        vm.startPrank(buyer);
        usdg.approve(address(mockClear), type(uint256).max);
        mockClear.exercise(a.optionId(), 1);
        vm.stopPrank();

        assertEq(nvda.balanceOf(buyer), 1e18, "buyer received Alice's NVDA");
        assertEq(nvda.balanceOf(address(b)), 5e18, "Bob still holds 5");
        assertEq(ValoremLib.lockedAssets(IValoremClear(address(mockClear)), a.claimKey()), 0);
        assertEq(b.contractsWritten(), 0);

        vm.warp(uint256(expiryTs) + b.index());
        a.settle();
        b.settle();

        assertEq(nvda.balanceOf(address(a)), 4e18, "Alice's unwritten 4 stay; the 1 is gone");
        assertEq(usdg.balanceOf(address(a)), STRIKE, "Alice gets strike USDG");
        assertEq(nvda.balanceOf(address(b)), 5e18, "Bob's stock is whole");
        assertEq(usdg.balanceOf(address(b)), 0, "Bob earned no strike");

        vm.prank(alice);
        a.claimUsdg();
        assertEq(usdg.balanceOf(alice), SELLER + STRIKE);
        vm.prank(bob);
        b.withdraw(5e18);
        assertEq(nvda.balanceOf(bob), 10e18);
    }

    function test_twoAliceLotsPartialBook() public {
        _open(alice);
        _week();
        WriterAccount a = _list(alice, 2);
        _fillLot(a, 0);
        assertEq(a.contractsWritten(), 1);
        assertEq(a.reserved(), 1e18);
        assertEq(a.idleAssets(), 3e18);

        vm.warp(uint256(expiryTs) + a.index());
        a.settle();
        assertEq(nvda.balanceOf(address(a)), 5e18, "unexercised write returns; unfilled lot unlocks");
        vm.prank(alice);
        a.withdraw(5e18);
        assertEq(nvda.balanceOf(alice), 10e18);
    }

    function test_settleAfterSetWeek_usesPinnedExpiry() public {
        _open(alice);
        _week();
        WriterAccount a = _list(alice, 1);
        uint40 pinned = a.listedExpiryTs();

        vm.prank(keeper);
        factory.setWeek(STRIKE, uint40(block.timestamp + 10 days), uint40(block.timestamp + 11 days), ASK);

        vm.warp(pinned);
        a.settle();
        assertEq(a.reserved(), 0);
        assertEq(a.listedLots(), 0);
        vm.prank(alice);
        a.withdraw(5e18);
    }

    function test_fillAfterSetWeek_keepsPinnedStrikeAndAsk() public {
        _open(alice);
        _week();
        WriterAccount a = _list(alice, 1);
        uint256 pinnedStrike = a.listedStrikeUsdg();
        uint256 pinnedAsk = a.listedAskUsdg();

        vm.prank(keeper);
        factory.setWeek(240_000_000, uint40(block.timestamp + 10 days), uint40(block.timestamp + 11 days), 2_000_000);

        assertEq(a.listedStrikeUsdg(), pinnedStrike);
        assertEq(a.listedAskUsdg(), pinnedAsk);
        _fillLot(a, 0);
        assertEq(a.contractsWritten(), 1);
        assertEq(usdg.balanceOf(alice), SELLER);
    }

    function test_emptyAccountNotInPendingOrLive() public {
        vm.prank(alice);
        factory.createAccount();
        assertEq(factory.pendingCount(), 0);
        assertEq(factory.liveCount(), 0);

        _open(bob);
        _week();
        _list(bob, 1);
        assertEq(factory.pendingCount(), 0);
        assertEq(factory.liveCount(), 1);
        assertEq(factory.liveAt(0), address(factory.accountOf(bob)));
    }

    function test_requestWriteEnqueuesThenListDequeues() public {
        _open(alice);
        _week();
        WriterAccount a = factory.accountOf(alice);
        vm.prank(alice);
        a.requestWrite(1);
        assertEq(factory.pendingCount(), 1);
        vm.prank(keeper);
        factory.listFor(alice);
        assertEq(factory.pendingCount(), 0);
        assertEq(factory.liveCount(), 1);
    }

    function test_transferOwnership() public {
        address carol = makeAddr("carol");
        _open(alice);
        WriterAccount a = factory.accountOf(alice);
        vm.prank(alice);
        a.transferOwnership(carol);
        assertEq(a.owner(), carol);
        assertEq(address(factory.accountOf(carol)), address(a));
        assertEq(address(factory.accountOf(alice)), address(0));
        vm.prank(carol);
        a.withdraw(5e18);
        assertEq(nvda.balanceOf(carol), 5e18);
    }

    function test_ownerCanList() public {
        _open(alice);
        _week();
        WriterAccount a = factory.accountOf(alice);
        vm.startPrank(alice);
        a.requestWrite(1);
        a.list();
        vm.stopPrank();
        assertEq(a.listedLots(), 1);
        assertEq(factory.liveCount(), 1);
    }
}
