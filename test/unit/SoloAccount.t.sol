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

    /*//////////////////////////////////////////////////////////////
                        P4 BATCH (SEC-24, SEC-25, SEC-26)
    //////////////////////////////////////////////////////////////*/

    /// @dev SEC-26. {WriterAccount.initialize} approves SEAPORT for the Clear ERC-1155 and nothing else, so a
    ///      non-zero conduit key produces an account that can list and can never be filled: Seaport would move the
    ///      offer through a conduit address this account never approved. Until this row only the deploy verifier
    ///      said so, off chain. The factory deploys the implementation in its own constructor, so the refusal
    ///      lands there -- a misconfigured factory cannot be deployed at all. The positive control is `setUp`
    ///      itself, which builds the same factory with a zero key.
    function test_factoryRefusesANonZeroConduitKey() public {
        vm.expectRevert(WriterAccount.ConduitNotSupported.selector);
        new AccountFactory(
            IERC20(address(nvda)),
            IERC20(address(usdg)),
            IValoremClear(address(mockClear)),
            ISeaport(address(mockSeaport)),
            IChainlinkFeed(address(feed)),
            6 hours,
            keccak256("some conduit"),
            admin,
            feeSafe,
            20e18
        );
    }

    /// @dev SEC-24. The per-account expiry is `baseExpiryTs + index` narrowed to the uint40 a Valorem option type
    ///      is keyed by. The addition is done in uint256 and cannot wrap; the DOWNCAST could, and a truncated
    ///      expiry keys a different option type, so the account would write against terms nobody agreed to instead
    ///      of refusing. Unreachable at any plausible timestamp -- uint40 runs to the year 36812 -- so the week is
    ///      set at the very top of the range to reach it at all. The control below it: one second lower, with the
    ///      same account and the same index, lists fine.
    function test_listRefusesAnExpiryThatWouldNotFitInUint40() public {
        _open(alice);
        _open(bob);

        // Positive control FIRST, through the same path: at an ordinary week this account lists.
        _week();
        WriterAccount a = _list(alice, 1);
        assertGt(a.optionId(), 0, "control: an ordinary week lists");

        // Now the top of the uint40 range, where `baseExpiryTs + index` no longer fits. Bob's account carries a
        // non-zero index, which is the whole reason the sum leaves the range.
        WriterAccount b = factory.accountOf(bob);
        assertGt(b.index(), 0, "the index is what pushes the sum over");
        vm.prank(keeper);
        factory.setWeek(STRIKE, type(uint40).max - 1 days, type(uint40).max, ASK);
        vm.prank(bob);
        b.requestWrite(1);
        vm.expectRevert(WriterAccount.ExpiryOutOfRange.selector);
        vm.prank(keeper);
        factory.listFor(bob);
    }

    /// @dev SEC-25, and it is the opposite of what the finding assumed. A live listing's consideration recipient
    ///      is fixed in the signed order, so after {transferOwnership} it still names the OLD owner -- but every
    ///      listing is FULL_RESTRICTED with this account as its zone, and {authorizeOrder} refuses a fill whose
    ///      `consideration[0].recipient` is not the CURRENT owner. The old order is therefore UNFILLABLE, not a
    ///      leak. What it costs instead is pinned here too: there is no cancel path, so the new owner cannot
    ///      re-list until the listing's own week ends.
    function test_transferOwnershipMakesALiveListingUnfillableNotPayableToTheOldOwner() public {
        address carol = makeAddr("carol");
        _open(alice);
        _week();
        WriterAccount a = _list(alice, 1);
        uint256 aliceBefore = usdg.balanceOf(alice);

        // The order as it was SIGNED, captured before the transfer. {lotOrder} is a view that rebuilds from
        // current storage, so reading it afterwards returns the new owner and proves nothing about the live one.
        OrderComponents memory signed = a.lotOrder(0);
        assertEq(signed.consideration[0].recipient, alice, "the live order pays the owner who listed it");

        vm.prank(alice);
        a.transferOwnership(carol);
        assertEq(a.owner(), carol);
        assertEq(a.lotOrder(0).consideration[0].recipient, carol, "a NEW order would name the new owner");

        vm.startPrank(buyer);
        usdg.approve(address(mockSeaport), type(uint256).max);
        vm.expectRevert(WriterAccount.BadLot.selector);
        mockSeaport.fulfil(signed, 1);
        vm.stopPrank();
        assertEq(usdg.balanceOf(alice), aliceBefore, "the old owner is paid nothing");

        // The cost of failing closed without a cancel path: the account is stuck listed for the week.
        vm.expectRevert(WriterAccount.AlreadyListed.selector);
        vm.prank(carol);
        a.requestWrite(1);
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

    /*//////////////////////////////////////////////////////////////
                    SEC-03: A FAILED REDEEM IS RECOVERABLE
    //////////////////////////////////////////////////////////////*/

    /// @dev THE ok == false BRANCH HAD NO COVERAGE AT ALL BEFORE THIS ROW, which is why the dead end survived:
    ///      `ValoremLib.tryRedeemClaim` CATCHES a reverting `redeem` and returns `false`, so `settle` completed
    ///      and looked successful while leaving the claim open forever.
    ///
    ///      THE FAILURE IS INJECTED WITH `vm.mockCallRevert` ON `redeem` ALONE, deliberately, rather than by
    ///      swapping in a fake Clear. `src/mocks/MockClear.sol` is outside this row's scope, and intercepting the
    ///      one function keeps every other part of the real mock -- the position accounting `settle` and
    ///      `lockedAssets` read -- genuinely in play. A wholesale fake would have made the assertions below agree
    ///      with a stub instead of with the contract.
    function test_settle_failedRedeemStrandsTheClaimAndIsRecoverable() public {
        _open(alice);
        _week();
        WriterAccount a = _list(alice, 1);
        // The claim only exists once a lot is FILLED -- `claimKey` is written in the fill path
        // (`Account.sol:315`), not at listing time.
        _fillLot(a, 0);
        vm.warp(uint256(expiryTs) + a.index());

        // USDG paused, or this account frozen on either token: the documented F-02 scenario.
        vm.mockCallRevert(address(mockClear), abi.encodeWithSelector(IValoremClear.redeem.selector), "paused");
        a.settle();

        assertTrue(a.isStranded(), "a caught redeem failure must leave the account stranded");
        assertTrue(a.claimKey() != 0, "the claim is still open");
        assertEq(a.listedExpiryTs(), 0, "settle cleared the listing even though the redeem failed");

        // THE DEAD END ITSELF. Before this fix these two were the whole story: no entry point redeemed.
        vm.expectRevert(WriterAccount.TooEarly.selector);
        a.settle();
        vm.prank(alice);
        vm.expectRevert(WriterAccount.StillOpen.selector);
        a.list();

        // The recovery path exists, and refuses while the cause persists rather than reporting success.
        vm.expectRevert(WriterAccount.StillStranded.selector);
        a.retryStrandedClaim();

        // The pause lifts. PERMISSIONLESS: called with no prank, so not as the owner.
        vm.clearMockedCalls();
        a.retryStrandedClaim();

        assertFalse(a.isStranded(), "the account is no longer stranded");
        assertEq(a.claimKey(), 0, "the claim was redeemed");
        assertEq(a.optionId(), 0, "optionId cleared, so the account can list again");
        assertEq(a.contractsWritten(), 0, "contractsWritten cleared");
    }

    /// @dev The gate is {isStranded}, not `claimKey != 0`. A live listing also has a claim open, and if the
    ///      recovery path keyed on the claim alone then ANYONE could redeem a writer's position out from under
    ///      them before expiry. This is the assertion that would catch that mistake.
    function test_retryStrandedClaim_refusesWhileTheListingIsStillLive() public {
        _open(alice);
        _week();
        WriterAccount a = _list(alice, 1);
        _fillLot(a, 0);

        assertTrue(a.claimKey() != 0, "a filled, live listing does have an open claim");
        assertFalse(a.isStranded(), "but a live listing is NOT stranded");
        vm.expectRevert(WriterAccount.NotStranded.selector);
        a.retryStrandedClaim();
    }

    /// @dev And a settled account, where the redeem succeeded, is not stranded either.
    function test_retryStrandedClaim_refusesAfterACleanSettle() public {
        _open(alice);
        _week();
        WriterAccount a = _list(alice, 1);
        _fillLot(a, 0);
        vm.warp(uint256(expiryTs) + a.index());
        a.settle();

        assertEq(a.claimKey(), 0, "a clean settle redeemed the claim");
        assertFalse(a.isStranded());
        vm.expectRevert(WriterAccount.NotStranded.selector);
        a.retryStrandedClaim();
    }
}
