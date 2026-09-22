// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MakerTestBase} from "./MakerBase.t.sol";
import {EarnVault} from "../../../src/v2/periphery/earn/EarnVault.sol";
import {IFundingSource} from "../../../src/v2/interfaces/IFundingSource.sol";
import {IEarnVault} from "../../../src/v2/interfaces/IEarnVault.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {Mock4626Vault} from "../../../src/v2/mocks/Mock4626Vault.sol";
import {MockEarnVenue} from "../../../src/v2/mocks/MockEarnVenue.sol";
import {StockVenueAdapter} from "../../../src/v2/periphery/earn/adapters/StockVenueAdapter.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";

/// @dev Code-bearing sink so EarnVault's constructor `splitter_.code.length == 0` check passes. ERC-20 transfers
///      to it do not need a fallback.
contract EarnVaultSplitterStub {}

/// @notice Shared EarnVault fixture. Extends {MakerTestBase} for the real Clearinghouse + OrderBook + AccessManager.
/// @dev T-CV-EARNVAULT: THE SELECTOR MAP IS READ FROM `script/v2/roles.v8.json`, NOT RESTATED HERE. It used to be
///      hand-written, with a NatSpec claiming it was the manifest block; by the time anyone checked, three of its
///      eleven rows disagreed with the manifest -- `setFundingEnabled(bool)` and `setBookFunding(bool)` had moved
///      to CONFIG_ADMIN and `refreshApprovals()` to QUOTER (the landed T-253 owner ruling) while this fixture
///      still said OPS_ADMIN. Every test in this file passed throughout, because the fixture asserted a map it
///      never read: the cannot-see-its-subject shape aimed at the fixture itself. {V8AccessTest._map} is the same
///      mechanism T-252 gave `DevDeploy` for the same reason, and it FAILS CLOSED -- a missing or unreadable
///      manifest reverts in `vm.readFile`, an absent `.targets.EarnVault` block reverts in `vm.parseJsonKeys`,
///      and an empty one trips its `require`. A silent fallback map would be strictly worse than the hand-written
///      version, because it would look authoritative.
abstract contract EarnVaultTestBase is MakerTestBase {
    EarnVault internal earn;
    MockEarnVenue internal venue;
    address internal splitter;

    uint256 internal constant DEP = 10_000e6;

    function setUp() public virtual override {
        super.setUp();
        _deployEarn();
    }

    function _deployEarn() internal {
        splitter = address(new EarnVaultSplitterStub());
        earn = new EarnVault(
            IOrderBook(address(book)), address(manager), address(usdg), splitter, "Stonkhouse Earn USDG", "eUSDG"
        );
        vm.label(address(earn), "EarnVault");
        _wireEarnFromManifest(address(earn));
        _grant(V8Roles.TREASURY_ADMIN, admin, 0);
        _grant(V8Roles.QUOTER, admin, 0);
        _grant(V8Roles.QUOTER, quoter, 0);
        // CONFIG_ADMIN is REQUIRED BY THE MANIFEST MAP and was absent while the fixture hand-wired
        // `setFundingEnabled`/`setBookFunding` to OPS_ADMIN. Reading the real map is what surfaced it.
        _grant(V8Roles.CONFIG_ADMIN, admin, 0);
        _grant(V8Roles.OPS_ADMIN, admin, 0);

        venue = new MockEarnVenue(IERC20(address(usdg)));
        vm.label(address(venue), "MockEarnVenue");

        vm.startPrank(alice);
        usdg.approve(address(earn), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        usdg.approve(address(earn), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Maps every EarnVault selector the manifest lists, at the role the manifest gives it. GRANTS NOTHING --
    ///      the grants are the `_grant` calls in {_deployEarn}, because a target's roles belong to different
    ///      holders. Do not reintroduce a literal selector list here: a fixture that restates its source of truth
    ///      diverges from it silently and keeps passing, which is the defect this replaced.
    function _wireEarnFromManifest(address target) internal {
        _map(target, "EarnVault");
    }

    function _setAdapter() internal {
        vm.prank(admin);
        earn.setAdapter(address(venue));
    }

    function _enableFunding() internal {
        vm.prank(admin);
        earn.setFundingEnabled(true);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = earn.deposit(assets, who);
    }

    /// @dev T-184: `deposit` keeps its one-value return by owner ruling, so a QUEUED deposit returns 0 and its id
    ///      has NO return channel -- it rides {IEarnVault.DepositQueued}. The id is the queue's new tail, which
    ///      {IEarnVault.queue} exposes, so the cases below read it from public state rather than from a log.
    function _depositFull(address who, uint256 assets) internal returns (uint256 shares, uint256 id) {
        vm.prank(who);
        shares = earn.deposit(assets, who);
        (, id) = earn.queue();
    }

    function _sweep(uint256 assets) internal {
        vm.prank(quoter);
        earn.sweepToVenue(assets);
    }
}

/// @notice EarnVault core: shares, ledger account, frozen IFundingSource, skim, inflation guard.
contract EarnVaultTest is EarnVaultTestBase {
    /*//////////////////////////////////////////////////////////////
                         IFundingSource SURFACE
    //////////////////////////////////////////////////////////////*/

    function test_implementsFrozenIFundingSourceExactly() public view {
        IFundingSource src = IFundingSource(address(earn));
        src.fundable(address(usdg));
        assertEq(IFundingSource.fundable.selector, bytes4(keccak256("fundable(address)")));
        assertEq(IFundingSource.fund.selector, bytes4(keccak256("fund(address,uint256)")));
    }

    function test_fund_revertsNotAuthorizedForAnyoneButTheBook() public {
        _enableFunding();
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.fund(address(usdg), 1e6);
        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.fund(address(usdg), 1e6);
    }

    function test_fund_shortVenueDeliveryDoesNotRevertAndLeavesAccountingConsistent() public {
        _setAdapter();
        _enableFunding();
        _deposit(alice, DEP);
        _sweep(DEP);
        venue.setWithdrawableCap(1_000e6);

        uint256 sharesBefore = earn.balanceOf(alice);
        uint256 supplyBefore = earn.totalSupply();
        uint256 aliceUsdg = usdg.balanceOf(alice);
        uint256 aliceFree = ch.free(alice, address(usdg));
        uint256 freeBefore = ch.free(address(earn), address(usdg));

        vm.prank(address(book));
        earn.fund(address(usdg), DEP);

        uint256 delivered = ch.free(address(earn), address(usdg)) - freeBefore;
        assertEq(delivered, 1_000e6, "book measures the free delta, not a return");
        assertLt(delivered, DEP, "short of the ask");
        assertEq(earn.balanceOf(alice), sharesBefore, "shares did not move");
        assertEq(earn.totalSupply(), supplyBefore, "supply did not move");
        assertEq(usdg.balanceOf(alice), aliceUsdg, "no other account's USDG moved");
        assertEq(ch.free(alice, address(usdg)), aliceFree, "nothing extra landed on the depositor");
    }

    function test_fundable_isWithdrawableNotNominalTotalAssets() public {
        _setAdapter();
        _enableFunding();
        _deposit(alice, DEP);
        _sweep(DEP);
        uint256 worth = earn.totalAssets();
        assertGt(worth, 0, "vault still has assets");
        venue.setFrozen(true);
        assertEq(venue.withdrawable(), 0, "venue pays nothing");
        assertEq(venue.totalAssets(), DEP, "venue still reports the position");
        assertEq(earn.fundable(address(usdg)), 0, "fundable follows withdrawable");
        assertEq(earn.totalAssets(), worth, "totalAssets still counts the frozen position");
    }

    function test_fundingBudget_mirrorsV2Constants() public view {
        (uint256 fundGas, uint256 fundableReadGas, uint256 maxFunded) = earn.fundingBudget();
        assertEq(fundGas, V2Constants.FUNDING_GAS);
        assertEq(fundableReadGas, V2Constants.FUNDABLE_READ_GAS);
        assertEq(maxFunded, V2Constants.MAX_FUNDED_MAKERS_PER_TAKE);
    }

    /*//////////////////////////////////////////////////////////////
                              TOTAL ASSETS
    //////////////////////////////////////////////////////////////*/

    function test_totalAssets_sumsWalletLedgerAndVenue_lossIsProRata() public {
        _setAdapter();
        _deposit(alice, DEP);
        _deposit(bob, DEP);
        _sweep(DEP * 2);

        uint256 aliceShares = earn.balanceOf(alice);
        uint256 bobShares = earn.balanceOf(bob);
        uint256 aliceUsdg = usdg.balanceOf(alice);
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 before = earn.totalAssets();
        assertEq(before, DEP * 2);

        venue.loseAssets(DEP);

        assertEq(earn.totalAssets(), before - DEP, "venue loss lands in totalAssets");
        assertEq(earn.balanceOf(alice), aliceShares, "alice share balance unchanged");
        assertEq(earn.balanceOf(bob), bobShares, "bob share balance unchanged");
        assertEq(usdg.balanceOf(alice), aliceUsdg, "alice USDG unchanged");
        assertEq(usdg.balanceOf(bob), bobUsdg, "bob USDG unchanged");
        uint256 aliceAssets = earn.convertToAssets(aliceShares);
        uint256 bobAssets = earn.convertToAssets(bobShares);
        assertLt(aliceAssets, DEP, "alice is down");
        assertLt(bobAssets, DEP, "bob is down");
        // Dead shares take a dust slice, so the two living holders are not wei-equal.
        assertApproxEqAbs(
            aliceAssets + bobAssets + earn.convertToAssets(earn.MIN_SHARES()),
            earn.totalAssets(),
            1,
            "loss is entirely in share price; no other account was credited"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         FIRST-DEPOSITOR INFLATION
    //////////////////////////////////////////////////////////////*/

    function test_firstDeposit_isOneToOneDespiteADonation() public {
        uint256 donation = 50_000e6;
        vm.prank(bob);
        usdg.transfer(address(earn), donation);

        uint256 shares = _deposit(alice, DEP);
        assertEq(shares, DEP, "first deposit is 1 share per 1 asset base unit");
        assertEq(earn.balanceOf(bob), 0, "the donor bought nothing");
        assertEq(earn.balanceOf(earn.DEAD_SHARES()), earn.MIN_SHARES(), "dead shares credited");
        assertGt(earn.convertToAssets(shares), DEP, "alice captures the donation, the donor does not");
    }

    /*//////////////////////////////////////////////////////////////
                                  SKIM
    //////////////////////////////////////////////////////////////*/

    function test_skim_flatOrLosingPeriodTakesZero() public {
        _setAdapter();
        vm.prank(admin);
        earn.setSkimBps(1_000);
        _deposit(alice, DEP);
        _sweep(DEP);

        uint256 splitterBefore = usdg.balanceOf(splitter);
        uint256 mark = earn.highWaterMark();
        uint256 fee = earn.skim();
        assertEq(fee, 0, "flat takes zero");
        assertEq(usdg.balanceOf(splitter), splitterBefore, "splitter unpaid on flat");
        assertEq(earn.highWaterMark(), mark, "flat leaves the mark (priceNow == mark)");

        venue.loseAssets(1_000e6);
        uint256 feeLoss = earn.skim();
        assertEq(feeLoss, 0, "loss takes zero");
        assertEq(usdg.balanceOf(splitter), splitterBefore, "splitter unpaid on loss");
        assertEq(earn.highWaterMark(), mark, "a loss does not raise the mark");
    }

    function test_skim_gainGoesToSplitterBySafeTransfer() public {
        _setAdapter();
        vm.prank(admin);
        earn.setSkimBps(1_000);
        _deposit(alice, DEP);
        _sweep(DEP);

        uint256 yield_ = 10_000e6;
        usdg.mint(address(this), yield_);
        usdg.approve(address(venue), yield_);
        venue.addYield(yield_);

        uint256 splitterBefore = usdg.balanceOf(splitter);
        uint256 aliceUsdg = usdg.balanceOf(alice);
        uint256 fee = earn.skim();
        assertGt(fee, 0, "a realised gain is charged");
        assertEq(usdg.balanceOf(splitter) - splitterBefore, fee, "plain transfer to the splitter address");
        assertEq(usdg.balanceOf(alice), aliceUsdg, "depositor USDG unchanged");
    }

    function test_setSkimBps_ceilingIsCompiled() public {
        uint16 tooMuch = earn.SKIM_BPS_CEIL() + 1;
        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        earn.setSkimBps(tooMuch);
    }

    /// @dev SEC-16. {skim} is PERMISSIONLESS and raises its fee wallet-first. While a redemption is queued, the cash in
    ///      the wallet is what the queue head is waiting on, so a fee taken now is paid out of money already owed to
    ///      a redeemer. {fundable} and {fund} both answer 0 in this state; {skim} must too, and must leave the mark.
    ///
    ///      RED ON THE OLD CODE: the gain here is ~DEP, the fee ~10 % of it, and the wallet holds DEP after bob's
    ///      partial raise, so `_raise(fee)` is satisfied from the wallet and the splitter is paid.
    function test_skim_takesNothingWhileARedemptionIsQueued() public {
        _setAdapter();
        vm.prank(admin);
        earn.setSkimBps(1_000);
        _deposit(alice, DEP);
        uint256 bobShares = _deposit(bob, DEP);
        _sweep(DEP);

        // A real gain, sitting in the venue.
        usdg.mint(address(this), DEP);
        usdg.approve(address(venue), DEP);
        venue.addYield(DEP);

        // Freeze the venue so bob's exit cannot be raised in full and queues with the wallet cash left behind.
        venue.setFrozen(true);
        vm.prank(bob);
        (, uint256 id) = earn.redeem(bobShares, bob);
        assertGt(id, 0, "premise: bob is queued, not paid");
        uint256 wallet = usdg.balanceOf(address(earn));
        assertGt(wallet, 0, "premise: the wallet still holds cash a fee could be taken from");

        uint256 splitterBefore = usdg.balanceOf(splitter);
        uint256 mark = earn.highWaterMark();
        uint256 fee = earn.skim();
        assertEq(fee, 0, "a fee was charged while the queue is open");
        assertEq(usdg.balanceOf(splitter), splitterBefore, "the splitter was paid while the queue is open");
        assertEq(usdg.balanceOf(address(earn)), wallet, "the queue head's cash moved");
        assertEq(earn.highWaterMark(), mark, "the mark moved while nothing was charged");

        // POSITIVE CONTROL: the refusal is about the queue, not about skim. Drain it and the gain is charged.
        venue.setFrozen(false);
        assertEq(earn.processQueue(10), 1, "premise: the queue drains once the venue reopens");
        assertGt(earn.skim(), 0, "the gain on the shares that stayed is still charged once the queue is empty");
    }

    /// @dev SEC-17. `before == 0` with shares outstanding is total loss. {deposit} used to reopen at the fixed 1:1 rate
    ///      there, so the wiped-out holders owned supply/(supply + minted) of the newcomer's assets. It must refuse,
    ///      and {convertToShares} must stop quoting the rate it refuses.
    ///
    ///      Reached through the venue double's bad debt. The row calls SEC-17 latent: no permissionless sequence to
    ///      an EXACT zero is known on the real stack, so this is the footgun's shape, not a live path.
    function test_deposit_refusesToReopenAgainstAWipedOutSupply() public {
        _setAdapter();
        _deposit(alice, DEP);
        _sweep(DEP);
        venue.loseAssets(DEP);

        assertEq(earn.totalAssets(), 0, "premise: total loss");
        uint256 supply = earn.totalSupply();
        assertGt(supply, 0, "premise: shares are outstanding");
        assertEq(earn.convertToShares(DEP), 0, "the view still quotes a reopening rate");

        vm.prank(bob);
        vm.expectRevert(V2Errors.BadUnits.selector);
        earn.deposit(DEP, bob);
        assertEq(earn.totalSupply(), supply, "a deposit was minted against a wiped-out supply");
    }

    /// @dev The boundary is EXACTLY zero: one wei of NAV is a price, and a deposit against it is fair to both sides
    ///      and still mints. Without this the refusal above could pass by refusing every post-loss deposit.
    function test_deposit_oneWeiOfNavIsStillAPrice() public {
        _setAdapter();
        _deposit(alice, DEP);
        _sweep(DEP);
        venue.loseAssets(DEP - 1);

        assertEq(earn.totalAssets(), 1, "premise: one wei of NAV");
        uint256 shares = _deposit(bob, DEP);
        assertGt(shares, 0, "a deposit against a non-zero NAV was refused");
    }
}

/// @notice T-177 / F-CP-06: EarnVault.place applies an oracle price guard, like its siblings.
/// @notice T-257 + T-298: the ERC-1155 inbox. Both hooks learn the same fact from the same code path, and the fact
///         is learned only from a MINT.
/// @dev T-257 made both hooks record through {EarnVault._noteIncoming}. T-298 found that the path recorded ANY
///      delivery routed through the Clearinghouse token -- including a permissionless zero-value transfer from an
///      account holding none of the series -- because `msg.sender == clearinghouse` is true for every transfer and
///      the amount was never read. The T-257 cases used to deliver shorts by TRANSFER from `mm`; under T-298 that
///      delivery is deliberately not recorded, so they now reach the recording path through the vault's own fill,
///      which is the only way a real write reaches it.
///
///      THE TRACKER HAS NO GETTER, so "was it recorded" is observed as "did the vault write storage", via
///      `vm.record` / `vm.accesses`. The hooks have no other storage effect (the reentrancy guard is transient),
///      so zero writes means {_recordShort} did not run. {hasOpenShort} cannot see this defect on its own: it
///      re-reads the vault's short BALANCE for each tracked series, so a bogus zero-balance entry still answers
///      false. The damage is the entry itself -- every one is walked by {_pruneShorts} and {hasOpenShort} at the
///      top of {deposit}, {redeem} and {processQueue}, and only a later prune removes it.
/// @notice SEC-30 and SEC-41: the adapter this vault will accept, and the queue entry it can never pay.
contract EarnVaultP4BatchTest is EarnVaultTestBase {
    /// @dev SEC-30. `setAdapter`'s asset check is not an ownership check: an adapter built for a SIBLING EarnVault
    ///      holds the same asset and passes it, after which this vault counts the sibling's venue balance in its own
    ///      {totalAssets} while the sibling can still move it. The probe refuses any adapter that does not name THIS
    ///      vault. The control comes first so the refusals below are the probe's and not the fixture's.
    function test_setAdapter_refusesAnAdapterOwnedByAnotherVault() public {
        // Control: a venue that names this vault is accepted.
        venue.setVault(address(earn));
        vm.prank(admin);
        earn.setAdapter(address(venue));
        assertEq(address(earn.adapter()), address(venue), "control: an adapter that names this vault is accepted");

        // A sibling vault's adapter: same asset, different owner.
        MockEarnVenue sibling = new MockEarnVenue(IERC20(address(usdg)));
        sibling.setVault(makeAddr("some other EarnVault"));
        assertEq(sibling.asset(), address(usdg), "the asset check alone cannot tell these apart");
        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.setAdapter(address(sibling));
        assertEq(address(earn.adapter()), address(venue), "the wiring did not move");
    }

    /// @dev SEC-30, the other refusal: an adapter that cannot say which vault owns it. {Mock4626Vault} holds the
    ///      right asset and has no `vault()`, so it stands in for a third-party adapter that answers the asset check
    ///      and nothing else. Refusing is the safe direction -- an adapter that cannot name its owner is exactly the
    ///      one not to wire.
    function test_setAdapter_refusesAnAdapterThatCannotNameItsVault() public {
        Mock4626Vault silent = new Mock4626Vault(IERC20(address(usdg)));
        assertEq(silent.asset(), address(usdg), "it passes the asset check");
        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.setAdapter(address(silent));
    }

    /// @dev SEC-41. After a total venue loss every queued redemption prices to nothing: `owed` is
    ///      `shares * totalAssets() / supply` and `totalAssets()` is 0. The `have == 0` break exists for
    ///      ILLIQUIDITY, where waiting is the right answer -- here waiting can never help, so before this row the
    ///      head parked on the first such entry and every entry behind it starved. Both entries must now be
    ///      released, their escrowed shares returned as {cancelQueued} returns them, and the head stepped past both.
    function test_processQueue_doesNotWedgeOnAnEntryThatCanNeverBePaid() public {
        _setAdapter();
        _deposit(alice, DEP);
        _deposit(bob, DEP);
        _sweep(DEP * 2);
        venue.setFrozen(true);

        uint256 aliceShares = earn.balanceOf(alice);
        uint256 bobShares = earn.balanceOf(bob);
        vm.prank(alice);
        (, uint256 aliceId) = earn.redeem(aliceShares, alice);
        vm.prank(bob);
        (, uint256 bobId) = earn.redeem(bobShares, bob);
        assertEq(aliceId, 1, "alice is at the head");
        assertEq(bobId, 2, "bob is behind her");
        assertEq(earn.balanceOf(alice), 0, "her shares are escrowed");

        // Total loss: the venue keeps nothing and the vault holds nothing, so NAV is zero.
        venue.setFrozen(false);
        venue.loseAssets(DEP * 2);
        assertEq(earn.totalAssets(), 0, "precondition: nothing left to price against");

        uint256 served = earn.processQueue(2);
        assertEq(served, 0, "nothing can be paid at this price, and nothing is");
        assertEq(earn.balanceOf(alice), aliceShares, "her escrowed shares come back, as cancelling returns them");
        assertEq(earn.balanceOf(bob), bobShares, "and his, which is what the head sticking used to prevent");

        (uint256 head, uint256 tail) = earn.queue();
        assertEq(tail, 2, "two entries were queued");
        assertGt(head, tail, "the head stepped PAST both rather than parking on the first");
    }
}

contract EarnVaultInboxTest is EarnVaultTestBase {
    /// @dev Same fixture choice as {EarnVaultFlatBoundaryQueueTest}: spot 240 leaves the 210 put out of the money,
    ///      so the price guard's intrinsic floor is zero and cannot be the thing refusing a write here.
    uint128 internal constant WRITE_PRICE = uint128(V2Constants.PRICE_TICK * 10);

    function setUp() public override {
        super.setUp();
        _setSpot(address(nvda), 240_000_000);
    }

    /// @dev Gives the vault free USDG collateral on the Clearinghouse so its own AskWrite can fill.
    function _fundVault() private {
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP);
    }

    /// @dev The vault's OWN write fills: the book mints the short to the vault, reaching the single hook with
    ///      `from == address(0)`. The only route by which a real short of the vault's arrives.
    function _vaultWritesAPut(uint64 units) private {
        vm.prank(quoter);
        uint256 orderId = earn.place(putId, WRITE, WRITE_PRICE, units, 0);
        _take(carol, _buy(putId, _ids(orderId), units, WRITE_PRICE, carol));
    }

    /// @dev Storage slots the vault wrote since the last `vm.record()`.
    function _vaultWrites() private returns (uint256) {
        (, bytes32[] memory writes) = vm.accesses(address(earn));
        return writes.length;
    }

    /// @dev `mm` writes a call through the book and holds a REAL short -- someone else's write, backed by `mm`'s
    ///      collateral.
    function _mmHoldsAShort(uint64 units) private returns (uint256 shortId, uint256 amount) {
        uint256 orderId = _place(mm, callId, V2Types.OrderKind.AskWrite, P2_50, units);
        _take(carol, _buy(callId, _ids(orderId), units, P2_50, carol));
        shortId = _short(callId);
        amount = ch.balanceOf(mm, shortId);
        assertGt(amount, 0, "precondition: mm's write filled and minted it a short");
    }

    /// @notice POSITIVE CONTROL. A real fill of the vault's own write still records, so the fix did not simply
    ///         switch recording off. If this goes red, every refusal below is vacuous.
    function test_realFillOfTheVaultsOwnWriteRecordsTheShort() public {
        _fundVault();
        assertFalse(earn.hasOpenShort(), "precondition: flat before the write");
        _vaultWritesAPut(10);
        assertGt(ch.balanceOf(address(earn), _short(putId)), 0, "the fill minted the vault a short");
        assertTrue(earn.hasOpenShort(), "the mint reached the tracker and the vault knows it is short");
    }

    /// @notice T-298, THE DEFECT. A zero-value transfer of a short id, from an account that holds none of it,
    ///         reaches the hook (OpenZeppelin's `fromBalance < value` is `0 < 0`) and must record nothing.
    /// @dev Remove the `from == address(0) && value != 0` clause from {EarnVault._noteIncoming} and this goes red
    ///      on the first assertion: {_recordShort} writes the array length, the element and the index mapping.
    function test_zeroValueTransferOfAShortIdRecordsNothing() public {
        uint256 shortId = _short(putId);
        assertEq(ch.balanceOf(carol, shortId), 0, "precondition: carol holds none of the series");

        vm.record();
        vm.prank(carol);
        ch.safeTransferFrom(carol, address(earn), shortId, 0, "");
        assertEq(_vaultWrites(), 0, "a zero-value transfer wrote the short tracker (_openShorts)");
        assertFalse(earn.hasOpenShort(), "and the vault does not think it is short");
    }

    /// @notice The unbounded half: one batch of zero values over many distinct short ids. Before T-298 each id was
    ///         a new {_openShorts} entry that the next {deposit}, {redeem} or {processQueue} had to walk.
    function test_zeroValueBatchOverManySeriesRecordsNothing() public {
        uint256 n = 64;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory values = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            // Any id with the low bit set is a short id to V2Ids; the series need not exist for a zero transfer.
            ids[i] = (uint256(keccak256(abi.encode("T-298", i))) & ~uint256(1)) | 1;
        }

        vm.record();
        vm.prank(carol);
        ch.safeBatchTransferFrom(carol, address(earn), ids, values, "");
        assertEq(_vaultWrites(), 0, "a zero-value batch appended series to the short tracker (_openShorts)");
    }

    /// @notice A REAL short arriving by TRANSFER is someone else's write and is deliberately not recorded, single
    ///         or batch. It did not debit the vault's collateral, so it does not understate {totalAssets}; recording
    ///         it would let any holder of one unit hold deposits, exits and the queue shut until that series settles
    ///         and is redeemed.
    /// @dev This is the behaviour T-257's transfer-based cases used to assert the opposite of. The deposit at the
    ///      end is the consequence that matters: it is priced and minted, not queued.
    function test_aRealShortDeliveredByTransferIsNotRecorded() public {
        (uint256 shortId, uint256 amount) = _mmHoldsAShort(5);
        assertGe(amount, 2, "precondition: enough units to send one singly and one in a batch");

        vm.record();
        vm.prank(mm);
        ch.safeTransferFrom(mm, address(earn), shortId, 1, "");
        assertEq(_vaultWrites(), 0, "a transferred short was recorded by the single hook");

        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        (ids[0], values[0]) = (shortId, amount - 1);
        vm.record();
        vm.prank(mm);
        ch.safeBatchTransferFrom(mm, address(earn), ids, values, "");
        assertEq(_vaultWrites(), 0, "a transferred short was recorded by the batch hook");

        assertEq(ch.balanceOf(address(earn), shortId), amount, "both deliveries were accepted, not reverted");
        assertFalse(earn.hasOpenShort(), "a gifted short is not an open write of the vault's");
        assertGt(_deposit(alice, DEP), 0, "and a deposit is priced and minted rather than queued behind it");
    }

    /// @notice ONE RULE, BOTH HOOKS. Called as the Clearinghouse directly, each hook records exactly when the
    ///         delivery is a mint of a non-zero amount of a short id, and in no other cell of the table.
    function test_bothHooksRecordOnlyANonZeroMint() public {
        uint256 shortId = _short(putId);
        address[2] memory froms = [address(0), carol];
        uint256[2] memory amounts = [uint256(1), 0];
        for (uint256 f; f < 2; ++f) {
            for (uint256 a; a < 2; ++a) {
                bool expectRecord = froms[f] == address(0) && amounts[a] != 0;
                for (uint256 viaBatch; viaBatch < 2; ++viaBatch) {
                    // A fresh vault per cell, so an earlier cell's entry cannot make a later one return early.
                    _deployEarn();
                    vm.record();
                    vm.prank(address(ch));
                    if (viaBatch == 1) {
                        uint256[] memory ids = new uint256[](1);
                        uint256[] memory values = new uint256[](1);
                        (ids[0], values[0]) = (shortId, amounts[a]);
                        earn.onERC1155BatchReceived(address(book), froms[f], ids, values, "");
                    } else {
                        earn.onERC1155Received(address(book), froms[f], shortId, amounts[a], "");
                    }
                    assertEq(_vaultWrites() != 0, expectRecord, "hook recorded outside the mint-only rule");
                }
            }
        }
        // A long id is never a write. T-433 records a long only when the BOOK delivers it (a fill of the vault's
        // Bid or a return of its resale escrow; see {EarnVaultHeldLongBoundaryTest}), so one minted with any other
        // operator records nothing at all -- and in particular is never recorded as a short.
        _deployEarn();
        vm.record();
        vm.prank(address(ch));
        earn.onERC1155Received(carol, address(0), putId, 1, "");
        assertEq(_vaultWrites(), 0, "a long not delivered by the book was recorded");
    }

    /// @notice Repeated ids in one batch, and a second mint of a series already tracked, change nothing:
    ///         {_recordShort} returns early. The second delivery is observed writing zero slots.
    function test_repeatedMintsOfOneSeriesAreIdempotent() public {
        uint256 shortId = _short(putId);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory values = new uint256[](2);
        (ids[0], ids[1]) = (shortId, shortId);
        (values[0], values[1]) = (1, 1);

        vm.record();
        vm.prank(address(ch));
        earn.onERC1155BatchReceived(address(book), address(0), ids, values, "");
        assertGt(_vaultWrites(), 0, "precondition: the first mint of the series recorded it");

        vm.record();
        vm.prank(address(ch));
        earn.onERC1155Received(address(book), address(0), shortId, 1, "");
        assertEq(_vaultWrites(), 0, "a series already tracked was appended again");
    }

    /// @notice End to end: two real fills of the same series, then settle and redeem -- the vault must report flat,
    ///         which a duplicate entry that pruning missed would not allow.
    function test_twoFillsOfOneSeriesPruneBackToFlat() public {
        _fundVault();
        _vaultWritesAPut(5);
        _vaultWritesAPut(5);
        assertTrue(earn.hasOpenShort(), "both fills are open");

        vm.warp(FRI_2026_09_18 + V2Constants.FINALIZE_DELAY);
        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 240_000_000);
        vm.prank(keeper);
        ch.settle(putId);
        vm.prank(address(earn));
        ch.redeem(_short(putId), address(earn));
        assertEq(ch.balanceOf(address(earn), _short(putId)), 0, "the short left the vault");
        assertFalse(earn.hasOpenShort(), "no duplicate entry keeps the vault looking short");
    }

    function test_bothHooksRefuseACallerThatIsNotTheClearinghouse() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = _short(callId);
        values[0] = 1;

        vm.startPrank(carol);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.onERC1155BatchReceived(carol, address(0), ids, values, "");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.onERC1155Received(carol, address(0), ids[0], 1, "");
        vm.stopPrank();
    }
}

contract EarnVaultPriceGuardTest is EarnVaultTestBase {
    // WRITE and BID come from MakerTestBase; redeclaring them shadows the base and will not compile.

    /// @dev THE HOLE THIS CLOSED. place() forwarded price straight to the book, and the book's entire price check
    ///      is `_checkPriceAndUnits` - declared `private pure`, so it cannot consult an oracle even in principle:
    ///      units non-zero, price non-zero, price on the tick grid. A QUOTER key could therefore rest an AskWrite
    ///      at one wei against depositor collateral. This asserts the PROTECTED FACT, not the presence of a
    ///      modifier, so it goes red however the guard is removed.
    /// @dev ONE TICK, NOT ONE WEI, and that distinction is the test. A one-wei price is off the tick grid, so
    ///      `OrderBook._checkPriceAndUnits` refuses it regardless - an earlier draft of this test passed with the
    ///      guard REMOVED for exactly that reason, which is the same "passes because it cannot see its subject"
    ///      shape this fix exists to close. V2Constants.PRICE_TICK is 100, so 100 is the smallest price the book
    ///      itself accepts, and only the guard can refuse it.
    function test_place_askWriteAtTheSmallestLegalPriceIsRefused() public {
        _setSpot(address(nvda), 240_000_000);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        earn.place(callId, WRITE, uint128(V2Constants.PRICE_TICK), 100, 0);
    }

    /// @dev The floor is the series' intrinsic value grossed for the seller fee the book will take, read live from
    ///      IOrderBook.feeParams - never a compiled copy. Spot 240 against the call strike gives a non-zero
    ///      intrinsic, so a write a single tick under the floor must be refused and the floor itself must not be.
    function test_place_askWriteBelowIntrinsicFloorIsRefused() public {
        _setSpot(address(nvda), 240_000_000);
        uint256 intrinsic = 240_000_000 - CALL_STRIKE;
        uint256 feeBps = book.feeParams().premiumFeeBps;
        uint256 floor = (intrinsic * V2Constants.BPS + (V2Constants.BPS - feeBps) - 1) / (V2Constants.BPS - feeBps);

        // Tick-aligned and strictly below the floor, so the book cannot be the one refusing it.
        uint256 justUnder = ((floor - 1) / V2Constants.PRICE_TICK) * V2Constants.PRICE_TICK;
        vm.startPrank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        earn.place(callId, WRITE, uint128(justUnder), 100, 0);
        vm.stopPrank();
    }

    /// @dev A bid above spot is refused. UNCHANGED BY SEC-05 except that it is now refused by a far tighter
    ///      bound: before, this price was the LAST legal one; now it is many times the bound.
    function test_place_bidAboveSpotIsRefused() public {
        _setSpot(address(nvda), 240_000_000);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        // One TICK above spot, not one wei: an off-grid price would be refused by the book instead.
        earn.place(callId, BID, uint128(240_000_000 + V2Constants.PRICE_TICK), 100, 0);
    }

    /// @dev THE SEC-05 PROTECTED FACT, AND THE ONE THIS SUITE PREVIOUSLY ASSERTED THE OPPOSITE OF. A bid AT SPOT
    ///      used to be legal - `MAX_BID_BPS_OF_SPOT` was `uint16(V2Constants.BPS)`, so the bound was 100 % of the
    ///      UNDERLYING share price while `price` is an option premium. It must now be refused. If this case goes
    ///      green by any route other than BadPrice, the bound is not the thing refusing it.
    function test_place_bidAtSpotIsNowRefused() public {
        _setSpot(address(nvda), 240_000_000);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        earn.place(callId, BID, 240_000_000, 100, 0);
    }

    /// @dev THE GUARD AUTHORISES, IT DOES NOT DISABLE. Spot 240 against CALL_STRIKE 230 gives intrinsic 10; the
    ///      band is 240 * MAX_BID_BPS_OF_SPOT / BPS = 24; so 34 is the last legal bid and must not be BadPrice -
    ///      otherwise the fix would have closed the hole by closing the vault. Derived from the constants rather
    ///      than typed, so a change to either moves this case with it.
    /// @dev UINT256 OPERANDS, as {EarnVault._checkPrice} computes the bound. The earlier form,
    ///      `240_000_000 * earn.MAX_BID_BPS_OF_SPOT()`, multiplied in uint32 - the literal's mobile type is the
    ///      smallest that holds it, and uint32 is wider than the uint16 getter, so uint32 is the common type. At
    ///      1_000 bps that is 2.4e11 against a uint32 ceiling of ~4.29e9, so it panicked 0x11 in the TEST body,
    ///      before `place` was ever called: the trace shows the MAX_BID_BPS_OF_SPOT staticcall and then the revert,
    ///      with no EarnVault frame. The guard itself was never the failing side.
    /// @dev THIS CASE AND ITS PAIR WERE RED FROM BIRTH. Both the cases and the overflowing arithmetic arrived in
    ///      one commit, 9037653192d6578e3f2d687aa50d1976235be889 (SEC-05); no later commit changed the contract
    ///      out from under them. A width bug in a test's own setup cannot be read as a regression in the subject.
    function test_place_bidAtIntrinsicPlusBandPassesTheGuard() public {
        uint256 spot = 240_000_000;
        _setSpot(address(nvda), spot);
        uint256 bound = (spot - CALL_STRIKE) + spot * earn.MAX_BID_BPS_OF_SPOT() / V2Constants.BPS;
        assertEq(bound % V2Constants.PRICE_TICK, 0, "bound must be tick-aligned or the book, not the guard, decides");
        // THE VAULT MUST BE ABLE TO PAY, OR THIS CASE NEVER REACHES THE GUARD. A Bid escrows premium at
        // placement, and {EarnVault.place} checks `_unescrowed()` against it BEFORE the book is called. With an
        // unfunded vault this case died on `InsufficientCollateral(0, ...)` at that check -- never reaching
        // {EarnVault._checkPrice} at all -- and the old catch arm accepted it because it is not BadPrice. So the
        // case reported green on a revert that had nothing to do with the bound it exists to pin. The deposit is
        // asserted rather than assumed: a queued deposit belongs to its depositor and would not fund the bid.
        assertGt(_deposit(alice, DEP), 0, "the fixture must fund the vault or this case cannot reach the guard");
        vm.prank(quoter);
        // THE ACCEPT SIDE MUST REQUIRE ACCEPTANCE. The earlier form caught every revert and asserted only
        // `bytes4(err) != V2Errors.BadPrice.selector`, so a fixture fault, a role change, an arithmetic panic or
        // anything else that broke `place` outright satisfied it and this case reported GREEN while proving
        // nothing about the bound. Its pair asserts that one TICK above the bound is refused; that argument pins
        // the bound only if this side actually requires the bound to be taken.
        try earn.place(callId, BID, uint128(bound), 100, 0) returns (uint256 orderId) {
            // {OrderBook._store} allocates `orderId = ++lastOrderId`, so a resting order is never id 0. This is
            // an assertion about a real effect rather than a restatement of "it did not revert".
            assertGt(orderId, 0, "the bound was accepted but nothing rests: place returned order id 0");
        } catch (bytes memory err) {
            // Any revert at all is a failure of this case. Name the revert data so the next reader does not have
            // to re-run it to find out which one it was.
            fail(string.concat("the bound must be ACCEPTED outright; place reverted with ", vm.toString(err)));
        }
    }

    /// @dev One TICK above the bound is refused. Pairs with the case above: together they pin the bound exactly,
    ///      so a guard that merely moved would fail one of them.
    function test_place_bidOneTickAboveIntrinsicPlusBandIsRefused() public {
        uint256 spot = 240_000_000;
        _setSpot(address(nvda), spot);
        // uint256 operands, for the reason given on the case above.
        uint256 bound = (spot - CALL_STRIKE) + spot * earn.MAX_BID_BPS_OF_SPOT() / V2Constants.BPS;
        vm.prank(quoter);
        vm.expectRevert(V2Errors.BadPrice.selector);
        earn.place(callId, BID, uint128(bound + V2Constants.PRICE_TICK), 100, 0);
    }

    /// @dev The band is MIRRORED, not chosen here: 1_000 bps is the `maxBidBpsOfSpot` the siblings are deployed
    ///      with (`script/v2/DevDeploy.s.sol:868`, MM_MAX_BID_BPS_OF_SPOT default). Pinned so a silent edit to the
    ///      constant is a failing test rather than a quiet loosening.
    function test_bidBandMirrorsTheDeployedSiblingValue() public view {
        assertEq(earn.MAX_BID_BPS_OF_SPOT(), 1_000, "mirrored from DevDeploy.s.sol:868");
        assertLt(earn.MAX_BID_BPS_OF_SPOT(), V2Constants.BPS, "100 % of spot is the bound SEC-05 removed");
    }

    /// @dev A dead oracle is fail-closed, not fail-open: no spot means no price bound, so no order rests.
    function test_place_noSpotIsRefused() public {
        _setSpot(address(nvda), 0);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.NoSource.selector);
        earn.place(callId, WRITE, 8_000_000, 100, 0);
    }
}

/*//////////////////////////////////////////////////////////////
    T-241: a disabled StockVenueAdapter must not distort NAV
//////////////////////////////////////////////////////////////*/

/// @notice The vault-level consequences of {StockVenueAdapter.enabled}.
/// @dev The other EarnVault suites use {MockEarnVenue}, which has no enable flag. These use the REAL
///      {StockVenueAdapter} over a {Mock4626Vault}, because the defect is the interaction between that
///      adapter's flag and {EarnVault.totalAssets} -- neither contract is wrong on its own.
///
///      Each test funds the adapter, flips `enabled` off, and asserts the vault's arithmetic is unchanged.
///      Before the fix all four went the other way: `totalAssets()` lost the venue balance the instant the
///      flag flipped, so a redemption priced lower, a deposit minted more, and {setAdapter}'s stranding
///      guard saw an empty adapter.
contract EarnVaultDisabledAdapterNavTest is EarnVaultTestBase {
    StockVenueAdapter internal stockAdapter;
    Mock4626Vault internal erc4626;

    uint256 internal constant SWEPT = 4_000e6;

    function setUp() public override {
        super.setUp();
        erc4626 = new Mock4626Vault(IERC20(address(usdg)));
        stockAdapter = new StockVenueAdapter(address(manager), address(usdg), address(erc4626), address(earn));
        vm.label(address(stockAdapter), "StockVenueAdapter");
        vm.prank(admin);
        earn.setAdapter(address(stockAdapter));
        stockAdapter.setEnabled(true);
    }

    /// Deposit, push part of it into the venue, then turn the adapter off.
    function _fundVenueThenDisable() internal returns (uint256 navBefore) {
        _deposit(alice, DEP);
        _sweep(SWEPT);
        assertGt(stockAdapter.totalAssets(), 0, "precondition: the venue holds assets");
        navBefore = earn.totalAssets();
        stockAdapter.setEnabled(false);
    }

    function test_disablingTheAdapterDoesNotChangeVaultNav() public {
        uint256 navBefore = _fundVenueThenDisable();
        assertEq(earn.totalAssets(), navBefore, "NAV must not move because an admin flipped a flag");
    }

    /// @dev {MockEarnVenue.nominalBlind} deliberately reproduces the old adapter's lie without moving a token.
    ///      The first half is the production invariant: disabling the real adapter must not produce that lie.
    ///      The second half proves the double can express it, so a future regression cannot hide behind a mock
    ///      whose nominal report is always honest.
    function test_mockBlindModeReproducesTheNavCollapseTheAdapterMustAvoid() public {
        uint256 navBeforeDisable = _fundVenueThenDisable();
        uint256 heldByStockAdapter = stockAdapter.totalAssets();

        assertEq(navBeforeDisable, DEP, "concrete pre-disable NAV");
        assertEq(earn.totalAssets(), DEP, "disabled adapter keeps the concrete 10,000 USDG NAV");
        assertEq(heldByStockAdapter, SWEPT, "the disabled adapter still reports its 4,000 USDG position");

        // Re-enable only to keep this setup valid against the historical implementation, whose disabled exit was
        // also blinded. The invariant above has already caught that implementation before this transition.
        stockAdapter.setEnabled(true);
        vm.prank(admin);
        earn.setAdapter(address(venue));
        _sweep(SWEPT);

        uint256 navBeforeBlind = earn.totalAssets();
        uint256 heldByMock = venue.held();
        uint256 tokensAtMock = usdg.balanceOf(address(venue));
        venue.setNominalBlind(true);

        assertEq(heldByMock, SWEPT, "mock holds the same 4,000 USDG position");
        assertEq(venue.held(), heldByMock, "blinding is not a loss");
        assertEq(usdg.balanceOf(address(venue)), tokensAtMock, "blinding moves no tokens");
        assertEq(venue.withdrawable(), heldByMock, "nominal reporting is independent from liquidity");
        assertEq(venue.totalAssets(), 0, "the mock can now express a blinded nominal report");
        assertEq(earn.totalAssets(), navBeforeBlind - heldByMock, "the double reproduces the old 4,000 USDG drop");

        venue.setNominalBlind(false);
        assertEq(earn.totalAssets(), navBeforeBlind, "revealing the report restores the concrete 10,000 USDG NAV");
    }

    /// @dev `owed = mulDiv(shares, totalAssets(), supply)` (EarnVault.sol:283). A NAV short by the venue
    ///      balance pays the redeemer less than their share of what the vault actually owns.
    function test_redemptionDoesNotUnderpayAfterTheAdapterIsDisabled() public {
        uint256 shares = _deposit(alice, DEP);
        _sweep(SWEPT);
        uint256 navBefore = earn.totalAssets();

        stockAdapter.setEnabled(false);

        // Price the redemption the vault WOULD quote now, against the supply and NAV it can see.
        uint256 supply = earn.totalSupply();
        uint256 quotedNow = (shares / 2) * earn.totalAssets() / supply;
        uint256 quotedHonest = (shares / 2) * navBefore / supply;
        assertEq(quotedNow, quotedHonest, "a redeemer must not be priced against a NAV missing the venue");
    }

    /// @dev `shares = mulDiv(received, supply, before)` (EarnVault.sol:262). A smaller `before` mints MORE
    ///      shares for the same money, diluting everyone already in.
    function test_depositDoesNotOverMintAfterTheAdapterIsDisabled() public {
        _deposit(alice, DEP);
        _sweep(SWEPT);
        uint256 supplyBefore = earn.totalSupply();
        uint256 navBefore = earn.totalAssets();

        stockAdapter.setEnabled(false);

        uint256 got = _deposit(bob, DEP);
        uint256 honest = DEP * supplyBefore / navBefore;
        assertEq(got, honest, "bob must not be minted extra shares because the venue went invisible");
    }

    /// @dev THE CONSUMER NOBODY HAD NAMED. {processQueue} prices each entry AT SERVICE off
    ///      `assetsNow = totalAssets()` (`EarnVault.sol:321-322`), so a NAV short by the venue underpays
    ///      holders who are already queued and cannot see or refuse the price they will be given. Same
    ///      shape as the :283 underpay, one step further from the user.
    function test_queuedRedemptionIsNotUnderpaidWhileTheAdapterIsDisabled() public {
        _deposit(alice, DEP);
        _sweep(SWEPT);

        // Queue alice by freezing the venue so the vault cannot cover her redeem from the wallet.
        erc4626.setWithdrawCap(0);
        uint256 shares = earn.balanceOf(alice);
        vm.prank(alice);
        (, uint256 id) = earn.redeem(shares, alice);
        assertGt(id, 0, "precondition: alice is queued, not paid");

        uint256 navQueued = earn.totalAssets();
        stockAdapter.setEnabled(false);
        assertEq(earn.totalAssets(), navQueued, "the price alice will be served at must not move");

        // And she is actually served the honest amount once the venue reopens, still disabled.
        erc4626.setWithdrawCap(type(uint256).max);
        uint256 before = usdg.balanceOf(alice);
        uint256 supply = earn.totalSupply();
        uint256 honest = shares * earn.totalAssets() / supply;
        earn.processQueue(1);
        assertApproxEqAbs(usdg.balanceOf(alice) - before, honest, 2, "queued holder paid against the full NAV");
    }

    /// @dev THE WORST OF THE THREE, because it is irreversible. {setAdapter} pulls `old.withdrawable()` and
    ///      then refuses to continue while `old.totalAssets()` is non-zero (EarnVault.sol:511-514). With both
    ///      blinded the guard passed and the vault re-pointed away from a venue still holding depositor
    ///      assets, losing its only reference to them. The guard is a real revert; it just could not see.
    function test_setAdapterStillDrainsAndGuardsADisabledAdapter() public {
        _fundVenueThenDisable();
        uint256 inVenue = stockAdapter.totalAssets();
        assertGt(inVenue, 0, "precondition: the disabled adapter is funded");

        MockEarnVenue replacement = new MockEarnVenue(IERC20(address(usdg)));
        vm.prank(admin);
        earn.setAdapter(address(replacement));

        // It did not silently abandon them: the swap only succeeds because the pull emptied the old adapter.
        assertEq(stockAdapter.totalAssets(), 0, "the old adapter was drained, not orphaned");
        assertEq(earn.adapter(), address(replacement));
    }
}

/// @notice T-184, THE FLAT BOUNDARY. The owner's ruling of 2026-09-20: the Earn vault keeps writing options, and
///         while a written series is outstanding deposits and redemptions DO NOT REVERT and DO NOT PRICE -- they
///         QUEUE, and they settle when the vault is flat.
///
/// @dev WHY A PUT AND NOT THE CALL EVERY OTHER TEST IN THIS FILE USES, because the choice IS the test.
///      `IClearinghouse.collateralAsset` is "USDG for puts, the underlying for calls". This vault's asset is USDG and
///      {EarnVault.totalAssets} is three USDG terms: wallet + `clearinghouse.free` + venue. So writing a CALL locks
///      NVDA, which none of the three ever counted, and the share price does not move at the fill at all -- that is a
///      SEPARATE defect (collateral invisible to NAV) carried out of this row into
///      T-SEC-INVARIANT-NAV-REDEMPTION-COVERAGE. Writing a PUT locks USDG, which term two DID count and the FREE
///      ledger excludes, so the dislocation is visible here and only here. THE SAME CASE WRITTEN AGAINST `callId`
///      WOULD HAVE PASSED ON THE BROKEN CONTRACT AND PROVED NOTHING.
///
/// @dev THE RED HALF RAN, AC-6, and these are the numbers it produced on the UNFIXED contract at base 69cdf747:
///      `test_RED_totalAssetsDropsWhenAWrittenPutFills` PASSED (gas 959370) and
///      `test_RED_depositWhileAWrittenPutIsOpenOverMints` PASSED (gas 1005033) -- i.e. the over-mint was real and
///      measured before a line of the fix existed. Those two cases cannot survive the fix, because the behaviour
///      they assert is the behaviour that was removed: the over-mint case is now
///      {test_depositWhileAWrittenPutIsOpenQueuesInsteadOfMinting}. The CAUSE assertion does survive and is kept
///      below as {test_theCauseIsUnchanged_totalAssetsStillDropsWhenAWrittenPutFills}, because the fix does not
///      correct the NAV -- nothing can, without a mark -- it stops pricing against it.
contract EarnVaultFlatBoundaryQueueTest is EarnVaultTestBase {
    /// @dev Spot 240 against PUT_STRIKE 210 leaves the put out of the money, so the intrinsic floor in
    ///      {EarnVault._checkPrice} is zero and any tick-aligned price clears it. That keeps the price guard out of
    ///      these cases: a refusal here would be the guard talking, not the boundary.
    uint128 internal constant WRITE_PRICE = uint128(V2Constants.PRICE_TICK * 10);
    uint64 internal constant WRITE_UNITS = 100;

    function setUp() public override {
        super.setUp();
        _setSpot(address(nvda), 240_000_000);
    }

    /// @dev Fills one AskWrite of the vault's own on `putId`, so USDG collateral leaves the vault's FREE ledger.
    function _vaultWritesAPutAndItFills() internal {
        vm.prank(quoter);
        uint256 orderId = earn.place(putId, WRITE, WRITE_PRICE, WRITE_UNITS, 0);
        _take(carol, _buy(putId, _ids(orderId), WRITE_UNITS, WRITE_PRICE, carol));
    }

    /// @dev Takes the vault back to flat: finalize the settlement price, settle the series, and let the vault redeem
    ///      its own short so the collateral actually unlocks. SETTLING IS NOT ENOUGH ON ITS OWN -- the vault keeps
    ///      the short token, and therefore the locked collateral, until it is redeemed, which is exactly why
    ///      {EarnVault.hasOpenShort} prunes against the vault's own ERC-1155 balance rather than against settlement.
    function _backToFlat() internal {
        vm.warp(FRI_2026_09_18 + V2Constants.FINALIZE_DELAY);
        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 240_000_000);
        vm.prank(keeper);
        ch.settle(putId);
        vm.prank(address(earn));
        ch.redeem(_short(putId), address(earn));
    }

    function _seedAndWrite() internal returns (uint256 aliceShares) {
        aliceShares = _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP);
        _vaultWritesAPutAndItFills();
    }

    /// @dev THE CAUSE, UNCHANGED BY THE FIX AND KEPT ON PURPOSE. `clearinghouse.free` excludes locked collateral by
    ///      construction, so the mint still moves `units * collateralPerUnit` out of the measurement while only the
    ///      premium comes back. The fix does not repair this number -- no continuous correction exists that is not a
    ///      mark -- it stops deposits and redemptions being priced against it. If this case ever goes green by the
    ///      NAV no longer dropping, the boundary has become untestable through this path and the queue cases below
    ///      would be passing over a subject they can no longer see.
    function test_theCauseIsUnchanged_totalAssetsStillDropsWhenAWrittenPutFills() public {
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP);
        assertGt(ch.collateralPerUnit(putId), 0, "a put locks USDG per unit, or this case measures nothing");

        uint256 navFlat = earn.totalAssets();
        _vaultWritesAPutAndItFills();
        assertLt(earn.totalAssets(), navFlat, "locked collateral still leaves totalAssets; only the premium returns");
        assertTrue(earn.hasOpenShort(), "and the vault now knows it is not flat");
    }

    /// @dev AC-2. THE OVER-MINT IS GONE BECAUSE NOTHING IS PRICED. The RED half of this case over-minted; it now
    ///      returns zero shares and a request id, and mints nothing at all.
    function test_depositWhileAWrittenPutIsOpenQueuesInsteadOfMinting() public {
        uint256 aliceShares = _seedAndWrite();
        uint256 supplyBefore = earn.totalSupply();

        (uint256 shares, uint256 id) = _depositFull(bob, DEP);
        assertEq(shares, 0, "nothing is minted while the vault is not flat");
        assertGt(id, 0, "and the depositor is given a queue id instead");
        assertEq(earn.balanceOf(bob), 0, "bob holds no shares yet");
        assertEq(earn.totalSupply(), supplyBefore, "supply did not move, so no holder was diluted");
        assertEq(earn.escrowedAssets(), DEP, "bob's assets are escrowed, not the vault's");
        // Alice is untouched: the whole point is that an arriving depositor cannot take a step from her.
        assertEq(earn.balanceOf(alice), aliceShares, "the existing holder is unaffected");
    }

    /// @dev THE MIRROR-IMAGE TRAP, and the one I would check first. Escrowed assets sit in this vault's wallet, which
    ///      {totalAssets} counts. If they were not subtracted, a queued deposit would RAISE the share price for every
    ///      existing holder the moment it arrived and drop it again on service -- the same defect as the over-mint,
    ///      pointing the other way, and introduced by the fix rather than found by it.
    function test_escrowedAssetsAreExcludedFromTotalAssets() public {
        _seedAndWrite();
        uint256 navBefore = earn.totalAssets();
        _depositFull(bob, DEP);
        assertEq(earn.escrowedAssets(), DEP, "escrow recorded");
        assertEq(earn.totalAssets(), navBefore, "NAV is UNMOVED by an escrowed deposit");
    }

    /// @dev T-299. Queued deposits and Bid escrow are both USDG, but they must never be the same USDG: the queue
    ///      owner can reclaim its assets at any time. The book pulls the raw wallet, so EarnVault must enforce its
    ///      own `_unescrowed` boundary before granting the pull.
    function test_bidCannotSpendQueuedDepositEscrow() public {
        _seedAndWrite();
        uint256 bobAfterQueue;
        uint256 id;
        (, id) = _depositFull(bob, DEP);
        bobAfterQueue = usdg.balanceOf(bob);

        uint128 bidPrice = 34_000_000;
        uint64 bidUnits = 1_000;
        uint256 needed = uint256(bidPrice) * bidUnits / V2Constants.UNITS_PER_SHARE;
        uint256 wallet = usdg.balanceOf(address(earn));
        uint256 spendable = wallet - earn.escrowedAssets();
        assertLt(spendable, needed, "positive control: only queued USDG could fund this Bid");

        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, spendable, needed));
        earn.place(callId, BID, bidPrice, bidUnits, 0);

        vm.prank(bob);
        earn.cancelQueued(id);
        assertEq(usdg.balanceOf(bob), bobAfterQueue + DEP, "the queued depositor can still reclaim every asset");
    }

    /// @dev AC-2, the other direction. Pricing an exit against an understated NAV underpays the redeemer and hands
    ///      the difference to whoever stays, so the exit queues too rather than reverting.
    function test_redeemWhileAWrittenPutIsOpenQueuesInsteadOfPricing() public {
        uint256 aliceShares = _seedAndWrite();
        uint256 balBefore = usdg.balanceOf(alice);

        vm.prank(alice);
        (uint256 assets, uint256 id) = earn.redeem(aliceShares, alice);
        assertEq(assets, 0, "nothing is paid while the vault is not flat");
        assertGt(id, 0, "the exit is queued");
        assertEq(usdg.balanceOf(alice), balBefore, "and no assets moved");
    }

    /// @dev AC-2 AND THE LOAD-BEARING HALF. Queueing only DEFERS the pricing: serving the queue while the series is
    ///      still written would price every waiting entry at exactly the understated NAV the queue exists to avoid.
    function test_processQueueServesNothingWhileTheShortIsOpen() public {
        _seedAndWrite();
        _depositFull(bob, DEP);
        assertEq(earn.processQueue(10), 0, "the queue does not move while the vault has a written series");
        assertEq(earn.balanceOf(bob), 0, "and bob is still not minted");
        assertEq(earn.escrowedAssets(), DEP, "his assets are still escrowed");
    }

    /// @dev AC-3. Once the vault is flat the queue processes at an exact NAV. The share price is measurable again
    ///      because no collateral is locked, so bob's mint is the fair one -- and strictly LESS than the over-mint
    ///      the RED half measured, which is the entire point of the row.
    function test_processQueueServesTheQueuedDepositOnceFlat() public {
        uint256 aliceShares = _seedAndWrite();
        (, uint256 id) = _depositFull(bob, DEP);

        _backToFlat();
        assertFalse(earn.hasOpenShort(), "the vault is flat once the short is redeemed");

        uint256 served = earn.processQueue(10);
        assertEq(served, 1, "the queued deposit is served");
        assertGt(earn.balanceOf(bob), 0, "bob is minted at the exact NAV");
        assertEq(earn.escrowedAssets(), 0, "escrow released");
        assertEq(earn.request(id).assets, 0, "the entry is spent");
        // THE PROTECTED PROPERTY IS "NO OVER-MINT", WHICH IS <=, NOT <. This is the exact negation of the RED
        // half's `assertGt(bobShares, aliceShares)`, and nothing stronger is true: the premium at this fixture's
        // size is 1000 base units before fees (price 1000 * 100 units / UNITS_PER_SHARE 100), which against a
        // 10_000e6 NAV rounds the two to equal. An earlier draft of this line asserted strictly-less and FAILED
        // `10000000000 >= 10000000000` -- the assertion was over-claiming, not the code misbehaving. Writing <
        // here would make this case depend on the fixture's premium being large enough to move a division, which
        // is not the property under test.
        assertLe(earn.balanceOf(bob), aliceShares, "no over-mint: equal assets never buy MORE shares than alice got");
    }

    /// @dev WHERE THE PREMIUM ACTUALLY GOES, MEASURED -- and this case exists because I got it wrong first.
    ///      Reading that {MakerVault.claimOwed} (MakerVault.sol:511) and {HouseVault.claimOwed}
    ///      (HouseVault.sol:751) both exist while EarnVault had neither, I concluded the vault's premium was
    ///      stranded in `OrderBook.owed` and invisible to {EarnVault.totalAssets}. IT IS NOT.
    ///      `OrderBook._payOrOwe` (OrderBook.sol:1211) tries a direct transfer FIRST and credits `owed` only if
    ///      that fails, so a plain-ERC20 USDG premium lands in this vault's WALLET, which is term one of
    ///      {EarnVault.totalAssets}. An earlier draft of this case asserted `owed > 0` after a fill and failed
    ///      `0 <= 0` -- the test disproved the theory, which is the only reason it is not still in the ledger as a
    ///      P1. THIS CASE PINS THE TRUE BEHAVIOUR so the wrong reading cannot be made twice.
    ///
    ///      WHAT DOES SURVIVE, and it is why {EarnVault._claimOwed} is kept: `owed` is a real FALLBACK, and
    ///      EarnVault has no other drain for it. It is defensive, not corrective.
    function test_thePremiumIsPaidStraightToTheWalletAndOwedIsOnlyTheFallback() public {
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP);

        uint256 walletBefore = usdg.balanceOf(address(earn));
        _vaultWritesAPutAndItFills();

        assertEq(book.owed(address(earn)), 0, "nothing is OWED: the book paid the premium directly");
        assertGt(
            usdg.balanceOf(address(earn)), walletBefore, "the premium arrived in the wallet, which totalAssets counts"
        );
    }

    /// @dev AC-3, the cancel half. A queued DEPOSITOR gets assets back, not shares -- they were never minted
    ///      against, so returning them moves nobody else's share price.
    function test_cancelQueuedReturnsTheEscrowedAssetsToTheDepositor() public {
        _seedAndWrite();
        uint256 balBefore = usdg.balanceOf(bob);
        (, uint256 id) = _depositFull(bob, DEP);
        assertEq(usdg.balanceOf(bob), balBefore - DEP, "assets left bob on the way into escrow");

        vm.prank(bob);
        earn.cancelQueued(id);
        assertEq(usdg.balanceOf(bob), balBefore, "and came back in full");
        assertEq(earn.escrowedAssets(), 0, "escrow released");
        assertEq(earn.balanceOf(bob), 0, "no shares were ever minted");
    }

    /// @dev Only the owner may cancel, same rule as a queued redemption.
    function test_cancelQueuedDepositIsOwnerOnly() public {
        _seedAndWrite();
        (, uint256 id) = _depositFull(bob, DEP);
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.cancelQueued(id);
    }

    /// @dev SEC-17, the queue's copy of the reopening. {processQueue} priced a deposit entry at `dBefore == 0` with
    ///      shares outstanding at the fixed 1:1 rate, exactly as {deposit} did. It must REFUND instead -- not revert,
    ///      because a revert would wedge the FIFO behind this entry for every redemption queued after it.
    ///
    ///      THE WIPE IS A CHEAT, deliberately: the row calls SEC-17 latent, so the vault is emptied by hand after it
    ///      is flat -- its free ledger withdrawn to a sink and every unescrowed wallet unit burned -- leaving only
    ///      bob's escrow, which {totalAssets} excludes.
    ///
    ///      RED ON THE OLD CODE: `minted = dBefore == 0 ? queuedAssets : ...` mints bob DEP shares and keeps his
    ///      assets, so both the share and the refund assertions fail.
    function test_processQueueRefundsAQueuedDepositAtTotalLoss() public {
        _seedAndWrite();
        (, uint256 id) = _depositFull(bob, DEP);
        _backToFlat();
        assertFalse(earn.hasOpenShort(), "premise: the vault is flat, so the queue will be served");

        // Total loss. Every amount is read into a local first so no argument expression consumes a prank.
        address sink = makeAddr("sink");
        uint256 free = ch.free(address(earn), address(usdg));
        vm.prank(address(earn));
        ch.withdraw(address(usdg), free, sink);
        uint256 unescrowed = usdg.balanceOf(address(earn)) - earn.escrowedAssets();
        vm.prank(address(earn));
        usdg.burn(unescrowed);
        assertEq(earn.totalAssets(), 0, "premise: total loss");
        uint256 supply = earn.totalSupply();
        assertGt(supply, 0, "premise: shares are outstanding");

        uint256 bobBefore = usdg.balanceOf(bob);
        earn.processQueue(10);

        assertEq(earn.balanceOf(bob), 0, "a queued deposit was minted against a wiped-out supply");
        assertEq(earn.totalSupply(), supply, "supply moved");
        assertEq(usdg.balanceOf(bob) - bobBefore, DEP, "the escrowed assets were not returned in full");
        assertEq(earn.escrowedAssets(), 0, "escrow was not released");
        assertEq(earn.request(id).assets, 0, "the entry was not spent");
    }
}

/*//////////////////////////////////////////////////////////////
    SEC-05: the quoting rails EarnVault was missing
//////////////////////////////////////////////////////////////*/

/// @notice The outflow bucket and the per-order size cap.
/// @dev WHY THIS SUITE EXISTS. The price check bounds ONE order. It does not bound how many, so a QUOTER key
///      could rest a legally-priced bid, have it filled, and rest another, moving depositor assets out without
///      limit. MakerVault bounds exactly this with `Limits.maxDailyOutflow` and a leaky bucket
///      (src/v2/mm/MakerVault.sol:214, :658); EarnVault had neither. These cases assert the PROTECTED FACT - that
///      the money stops moving - rather than the presence of a modifier.
contract EarnVaultQuotingRailsTest is EarnVaultTestBase {
    /// @dev Spot 240 against CALL_STRIKE 230: intrinsic 10, band 24, so 34 USDG is the highest legal bid. At
    ///      10_000 units that escrows 34 * 10_000 / 100 = 3_400 USDG, comfortably over the 2_500 USDG cap; at
    ///      5_000 units it escrows 1_700, comfortably under it. Both numbers are derived here, not typed.
    uint128 internal constant BID_PRICE = 34_000_000;

    /// @dev USDG is deliberately SPLIT between the wallet and the Clearinghouse, and getting this wrong is how
    ///      this suite nearly tested nothing. `OrderBook._place` escrows a Bid through `_pullUsdg`, which is
    ///      `usdg.safeTransferFrom(maker, ...)` - it pulls from the maker's WALLET by ERC-20 approval, NOT from
    ///      `clearinghouse.free`. An earlier draft of this setUp moved the whole balance with
    ///      `depositToClearinghouse(usdg, DEP)`, which leaves the wallet at zero: every bid below would have
    ///      reverted on insufficient balance instead of on the outflow cap, and the cap would have looked
    ///      enforced while never being reached. So the wallet keeps enough to fund the bids, and the
    ///      Clearinghouse keeps enough USDG collateral for the one AskWrite case.
    uint256 internal constant TO_CLEARINGHOUSE = 4_000e6;

    function setUp() public override {
        super.setUp();
        _setSpot(address(nvda), 240_000_000);
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), TO_CLEARINGHOUSE);
        assertGt(
            usdg.balanceOf(address(earn)), _escrowOf(10_000), "the wallet must fund the largest bid this suite places"
        );
    }

    function _bid(uint64 units) internal returns (uint256 orderId) {
        vm.prank(quoter);
        orderId = earn.place(callId, BID, BID_PRICE, units, 0);
    }

    /// @dev The escrow a bid of `units` takes, in asset base units: the book's own premium formula.
    function _escrowOf(uint64 units) internal pure returns (uint256) {
        return uint256(BID_PRICE) * units / V2Constants.UNITS_PER_SHARE;
    }

    /// @dev THE SUBJECT IS REAL, CHECKED FIRST. If a bid did not actually move assets out of the vault's
    ///      measurable cash, every case below would pass over nothing - the "passes because it cannot see its
    ///      subject" shape. So this asserts the escrow happens before anything asserts it is bounded.
    function test_aBidActuallyMovesAssetsOutOfTheVault() public {
        uint256 walletBefore = usdg.balanceOf(address(earn));
        _bid(1_000);
        uint256 walletAfter = usdg.balanceOf(address(earn));
        assertLt(walletAfter, walletBefore, "a bid must escrow, or the outflow cases measure nothing");
        assertEq(walletBefore - walletAfter, _escrowOf(1_000), "and it escrows exactly the book's premium formula");
        // The Clearinghouse balance is NOT the account a bid is drawn from; asserted so a future change that
        // moved the escrow there would fail here rather than silently drain a term the bucket cannot see.
        assertEq(ch.free(address(earn), address(usdg)), TO_CLEARINGHOUSE, "a bid does not touch the ledger balance");
    }

    /// @dev T-299. A Bid moves custody to the book, not ownership away from the vault. Pricing the same deposit on
    ///      otherwise identical state must therefore mint the same shares with or without that refundable escrow.
    function test_depositDuringLiveBidMintsTheSameSharesAsWithoutTheBid() public {
        uint256 snap = vm.snapshotState();
        uint256 sharesWithoutBid = _deposit(bob, DEP);
        vm.revertToState(snap);

        uint256 bookBefore = usdg.balanceOf(address(book));
        _bid(1_000);
        assertEq(
            usdg.balanceOf(address(book)) - bookBefore,
            _escrowOf(1_000),
            "positive control: the live Bid holds refundable escrow"
        );

        uint256 sharesWithBid = _deposit(bob, DEP);
        assertEq(
            sharesWithBid, sharesWithoutBid, "refundable Bid escrow must remain in totalAssets while pricing deposits"
        );
    }

    /// @dev T-299. An EXPIRED Bid nobody has pruned still holds its escrow in the book and is still refundable, so
    ///      it stays in NAV; and when {EarnVault.place} compacts the series it PRUNES that order before forgetting
    ///      its id, so the escrow comes home rather than vanishing from the vault's sight while the book holds it.
    function test_expiredUnprunedBidStaysInNavAndIsPrunedBeforeItsIdIsDropped() public {
        uint256 navFlat = earn.totalAssets();
        vm.prank(quoter);
        uint256 stale = earn.place(callId, BID, BID_PRICE, 1_000, uint40(block.timestamp + 1 hours));
        assertEq(earn.totalAssets(), navFlat, "a live Bid leaves NAV unmoved");

        vm.warp(block.timestamp + 2 hours);
        _setSpot(address(nvda), 240_000_000);
        V2Types.Order[] memory o = book.getOrders(_ids(stale));
        assertFalse(o[0].cancelled, "precondition: expired but NOT pruned, so the book still holds the escrow");
        assertEq(earn.totalAssets(), navFlat, "an expired, unpruned Bid is still refundable and still in NAV");

        uint256 walletBefore = usdg.balanceOf(address(earn));
        _bid(100);
        o = book.getOrders(_ids(stale));
        assertTrue(o[0].cancelled, "place pruned the expired Bid before dropping its id");
        assertEq(
            usdg.balanceOf(address(earn)) + _escrowOf(100), walletBefore + _escrowOf(1_000), "its escrow came home"
        );
        assertEq(earn.totalAssets(), navFlat, "and NAV never stepped: the escrow was never out of sight");
    }

    /// @dev T-299. THE BOUND ON THE NAV WALK. {EarnVault._bookEscrow} runs inside {EarnVault.totalAssets}, so the
    ///      number of series it walks is capped at {EarnVault.MAX_ORDER_SERIES}. A series whose orders are all dead
    ///      is dropped to make room; a full set of live series refuses the next one.
    /// @dev THE PER-SERIES LIVE-ORDER CAP, WHICH NOTHING TESTED. `place` refuses at
    ///      {EarnVault.MAX_LIVE_ORDERS_PER_SERIES} (src/v2/periphery/earn/EarnVault.sol:906), and that bound is
    ///      load-bearing: with {MAX_ORDER_SERIES} it is what holds `getOrders` to at most 8 x 16 = 128 ids in one
    ///      call (:173), and `hasOpenShort`, `_bookEscrow` and `_resaleEscrowOpen` all walk that list on the
    ///      deposit, redeem and processQueue paths.
    ///
    ///      MEASURED, NOT ASSUMED: deleting the refusal at :906 left this file at 72/72 and
    ///      `EarnVaultFunding.t.sol` at 11/11. The cap could be removed and NOTHING in the tree noticed. The
    ///      OrderBook does not enforce it either - every `CeilingExceeded` in `OrderBook.sol` is a FEE ceiling
    ///      (:590, :1248-1255) - so this check is the only thing holding the bound.
    ///
    ///      Both sibling vaults already have this case and EarnVault did not: `HouseVaultGuards.t.sol:234-241`
    ///      and `MakerVaultGuards.t.sol:475`. This is that test, in the same shape.
    ///
    ///      THE PRICE IS 1 USDG ON PURPOSE. At 100 units each bid escrows 1 USDG, so sixteen of them total 16
    ///      against a {MAX_DAILY_OUTFLOW} of 2_500 - the outflow bucket cannot be what refuses the seventeenth.
    ///      Getting that wrong is how the size-cap case above nearly proved nothing: two guards overlap here and
    ///      only the named error tells them apart.
    function test_liveOrdersPerSeriesAreCappedAndTheNextIsRefused() public {
        uint256 cap = earn.MAX_LIVE_ORDERS_PER_SERIES();
        uint128 price = uint128(V2Constants.PRICE_TICK * 10_000); // 1 USDG, as the series-cap case below
        uint256 id = ch.createSeries(address(nvda), false, 250_000_000, FRI_2026_09_18);

        for (uint256 i; i < cap; ++i) {
            vm.prank(quoter);
            earn.place(id, BID, price, 100, 0);
        }
        (uint256 used,) = earn.outflow();
        assertLt(used, earn.MAX_DAILY_OUTFLOW(), "the bucket must not be what refuses the next one");

        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        earn.place(id, BID, price, 100, 0);
    }

    function test_orderSeriesAreBoundedAndADeadSeriesMakesRoom() public {
        uint256 max = earn.MAX_ORDER_SERIES();
        uint128 price = uint128(V2Constants.PRICE_TICK * 10_000); // 1 USDG: legal for any OTM call here
        uint256[] memory firstOrder = new uint256[](1);
        for (uint256 i; i < max; ++i) {
            uint256 id = ch.createSeries(address(nvda), false, uint128(250_000_000 + i * 10_000_000), FRI_2026_09_18);
            vm.prank(quoter);
            uint256 orderId = earn.place(id, BID, price, 100, 0);
            if (i == 0) firstOrder[0] = orderId;
        }
        uint256 extra = ch.createSeries(address(nvda), false, 400_000_000, FRI_2026_09_18);
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        earn.place(extra, BID, price, 100, 0);

        uint256 navBefore = earn.totalAssets();
        vm.prank(quoter);
        earn.cancel(firstOrder);
        assertEq(earn.totalAssets(), navBefore, "a cancel moves escrow home without moving NAV");
        vm.prank(quoter);
        earn.place(extra, BID, price, 100, 0);
        assertEq(earn.totalAssets(), navBefore, "the freed slot is reused and NAV still counts every Bid");
    }

    /// @dev THE AGGREGATE BOUND, WHICH IS THE POINT OF THIS ROW. Each bid alone is under the cap; together they
    ///      cross it, and the second one reverts. A per-order bound could never catch this.
    function test_theBucketBlocksTheSecondBidThatCrossesTheCap() public {
        assertLt(_escrowOf(5_000), earn.MAX_DAILY_OUTFLOW(), "each bid alone must be legal or this proves nothing");
        assertGt(_escrowOf(10_000), earn.MAX_DAILY_OUTFLOW(), "but together they must cross the cap");

        _bid(5_000);
        (uint256 used, uint256 available) = earn.outflow();
        assertEq(used, _escrowOf(5_000), "the first bid is charged in full");
        assertEq(available, earn.MAX_DAILY_OUTFLOW() - used, "and available is the remainder");

        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, available, _escrowOf(5_000)));
        earn.place(callId, BID, BID_PRICE, 5_000, 0);
    }

    /// @dev A single bid over the cap is refused outright, with the bucket still empty.
    function test_oneOversizedBidIsRefused() public {
        (, uint256 available) = earn.outflow();
        assertEq(available, earn.MAX_DAILY_OUTFLOW(), "the bucket starts empty");
        vm.prank(quoter);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, available, _escrowOf(10_000)));
        earn.place(callId, BID, BID_PRICE, 10_000, 0);
    }

    /// @dev A BOUND THAT CAN BLOCK UNWINDING IS A BOUND THAT CAN TRAP THE VAULT'S MONEY. `cancel` books with
    ///      `enforce` false, so it credits the bucket and can never revert OutflowCapExceeded - and after the
    ///      credit the same bid that was refused a moment ago is legal again.
    function test_cancelCreditsTheBucketAndIsNeverBlocked() public {
        uint256 orderId = _bid(5_000);
        (uint256 usedBefore,) = earn.outflow();
        assertGt(usedBefore, 0, "the bucket must hold the charge, or the credit below proves nothing");

        vm.prank(quoter);
        earn.cancel(_ids(orderId));

        (uint256 usedAfter,) = earn.outflow();
        assertEq(usedAfter, 0, "returning the escrow empties the bucket again");
        _bid(5_000); // must not revert
    }

    /// @dev The bucket refills linearly over OUTFLOW_WINDOW, so a cap reached today does not freeze the vault
    ///      forever. Half a window refills half the cap.
    function test_theBucketRefillsOverTheWindow() public {
        _bid(5_000);
        (uint256 used,) = earn.outflow();
        assertGt(used, 0, "charged");

        vm.warp(block.timestamp + earn.OUTFLOW_WINDOW() / 2);
        (uint256 halfway, uint256 availableHalfway) = earn.outflow();
        assertLt(halfway, used, "half a window must have refilled something");
        assertGt(availableHalfway, 0, "and left room to quote");

        vm.warp(block.timestamp + earn.OUTFLOW_WINDOW());
        (uint256 after_, uint256 availableAfter) = earn.outflow();
        assertEq(after_, 0, "a full window empties the bucket");
        assertEq(availableAfter, earn.MAX_DAILY_OUTFLOW(), "and restores the whole cap");
    }

    /// @dev The cap is mirrored from the siblings' deployed value, pinned so a silent edit fails here.
    function test_outflowCapAndWindowMirrorTheSiblings() public view {
        assertEq(earn.MAX_DAILY_OUTFLOW(), 2_500e6, "mirrored from DevDeploy.s.sol:871");
        assertEq(earn.OUTFLOW_WINDOW(), 1 days, "mirrored from MakerVault.OUTFLOW_WINDOW");
    }

    /// @dev Per-order units cap. MAX_SERIES_UNITS itself must pass and one unit more must not, so the bound is
    ///      pinned exactly rather than merely present.
    function test_unitsAtTheCapPassAndOneMoreIsRefused() public {
        uint64 cap = uint64(earn.MAX_SERIES_UNITS());
        vm.prank(quoter);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        earn.place(callId, BID, BID_PRICE, cap + 1, 0);

        // At the cap the size guard passes; the outflow cap is what stops this one, which is the correct order.
        // The expected-error data is built BEFORE the prank on purpose: `earn.MAX_DAILY_OUTFLOW()` is an external
        // call, and building it after `vm.prank` consumed the prank, so `place` ran as this test contract and was
        // refused `NotAuthorized` by the QUOTER gate instead of by the outflow cap. The test then reported a
        // failure that named neither its subject nor its cause. Found while running this suite for T-SEC-P4-EARNVAULT.
        bytes memory expected =
            abi.encodeWithSelector(V2Errors.OutflowCapExceeded.selector, earn.MAX_DAILY_OUTFLOW(), _escrowOf(cap));
        vm.expectRevert(expected);
        vm.prank(quoter);
        earn.place(callId, BID, BID_PRICE, cap, 0);
    }

    /// @dev AN HONEST LIMIT OF THIS FIX, ASSERTED RATHER THAN LEFT FOR SOMEONE TO DISCOVER. MAX_ORDER_NOTIONAL is
    ///      `units * strike / UNITS_PER_SHARE`, so with MAX_SERIES_UNITS already bounding `units` it can only bind
    ///      when the strike exceeds MAX_ORDER_NOTIONAL * UNITS_PER_SHARE / MAX_SERIES_UNITS. At the tier-1 strikes
    ///      in this fixture (CALL_STRIKE 230 USDG) it is UNREACHABLE: the units cap always trips first. This case
    ///      states that in numbers so the launch pass reads it as a known shortfall, not as coverage.
    function test_theNotionalCapIsUnreachableAtTierOneStrikes() public view {
        uint256 bindingStrike = earn.MAX_ORDER_NOTIONAL() * V2Constants.UNITS_PER_SHARE / earn.MAX_SERIES_UNITS();
        assertGt(bindingStrike, CALL_STRIKE, "at this strike the units cap binds first and the notional cap is dead");
        assertEq(bindingStrike, 2_500_000_000, "the notional cap only bites above a strike of 2_500 USDG per share");
    }

    /// @dev An ASK is not an outflow and must not be charged: it escrows option tokens or mints against
    ///      collateral, it does not pay assets out on the quoting path. Charging it would let a vault that only
    ///      sells run itself out of quoting room.
    /// @dev Written on `putId`, not `callId`, and that is not arbitrary: a put is USDG-collateralised so the
    ///      Clearinghouse balance this fixture holds can back it, while a call would need the underlying the vault
    ///      does not own - the order would revert for a reason that has nothing to do with the bucket. Spot 240 is
    ///      above PUT_STRIKE 210, so intrinsic is zero and `_checkPrice` returns before the ask floor, leaving the
    ///      bucket as the only thing this case can be measuring.
    function test_anAskDoesNotChargeTheBucket() public {
        uint256 walletBefore = usdg.balanceOf(address(earn));
        vm.prank(quoter);
        earn.place(putId, WRITE, 8_000_000, 100, 0);

        (uint256 used,) = earn.outflow();
        assertEq(used, 0, "an ask is not an outflow");
        assertEq(usdg.balanceOf(address(earn)), walletBefore, "and it does not move the account a bid is drawn from");
    }
}

/// @notice T-433: a Bid fill turns the vault's escrow into LONGS that {EarnVault.totalAssets} cannot value, so the
///         T-184 boundary must close for held longs exactly as it does for an open short.
/// @dev T-299 made NAV continuous while a Bid is LIVE (escrow counted). The moment it fills that escrow leaves
///      NAV as longs, and without this row a deposit priced at once against the NAV that dropped at the fill. The
///      decision is option (2): queue, keep NAV cash-only. No trusted option mark exists to take option (1).
contract EarnVaultHeldLongBoundaryTest is EarnVaultTestBase {
    /// @dev Spot 240 against CALL_STRIKE 230: intrinsic 10 USDG, band 24, so 20 USDG is a legal bid AND a legal
    ///      resale ask (above intrinsic grossed up for the seller fee).
    uint128 internal constant PX = 20_000_000;
    uint64 internal constant UNITS = 100;

    function setUp() public override {
        super.setUp();
        _setSpot(address(nvda), 240_000_000);
        _deposit(alice, DEP);
    }

    /// @dev `carol` buys longs off `mm`'s write, so she has inventory to sell into the vault's Bid.
    function _carolHoldsLongs(uint64 units) private {
        uint256 orderId = _place(mm, callId, V2Types.OrderKind.AskWrite, P2_50, units);
        _take(carol, _buy(callId, _ids(orderId), units, P2_50, carol));
        assertEq(ch.balanceOf(carol, callId), units, "precondition: carol holds the longs she will sell");
    }

    /// @dev The vault bids and `carol` sells into it from inventory: the book transfers the longs to the vault.
    function _vaultBidFills(uint64 units) private {
        vm.prank(quoter);
        uint256 orderId = earn.place(callId, BID, PX, units, 0);
        _take(carol, _sell(callId, _ids(orderId), units, PX, false, carol));
        assertEq(ch.balanceOf(address(earn), callId), units, "positive control: the vault's Bid filled into longs");
    }

    /// @notice THE ROW. Bid placed, bid filled, then a deposit: it must queue, never price against the NAV that
    ///         dropped at the fill.
    /// @dev Remove `_holdsLongs()` from {EarnVault._positionOpen} and this goes red at `hasOpenPosition` (measured);
    ///      the redeem case below then shows the price effect: the exit is paid against the dropped NAV.
    function test_depositAfterTheVaultsBidFillsQueuesInsteadOfPricingADroppedNav() public {
        _carolHoldsLongs(UNITS);
        uint256 navBefore = earn.totalAssets();
        _vaultBidFills(UNITS);
        // THE CAUSE, UNCHANGED ON PURPOSE: the fill still takes the escrow out of NAV and nothing values the longs.
        // If this ever stops dropping, the boundary below is testing a subject it can no longer see.
        assertLt(earn.totalAssets(), navBefore, "the fill drops NAV: the longs are in no term");
        assertFalse(earn.hasOpenShort(), "a held long is not a short");
        assertTrue(earn.hasOpenPosition(), "but it is an open position");

        uint256 supplyBefore = earn.totalSupply();
        (uint256 shares, uint256 id) = _depositFull(bob, DEP);
        assertEq(shares, 0, "a deposit after the fill priced against the NAV that dropped at the fill (held longs)");
        assertGt(id, 0, "it is queued instead");
        assertEq(earn.totalSupply(), supplyBefore, "and no holder was diluted");
    }

    /// @notice The exit and the queue wait too: pricing either against the dropped NAV underpays the leaver.
    function test_redeemAndProcessQueueWaitWhileLongsAreHeld() public {
        _carolHoldsLongs(UNITS);
        _vaultBidFills(UNITS);
        _depositFull(bob, DEP);

        uint256 aliceShares = earn.balanceOf(alice);
        vm.prank(alice);
        (uint256 assets, uint256 id) = earn.redeem(aliceShares, alice);
        assertEq(assets, 0, "nothing is paid against a NAV missing the longs");
        assertGt(id, 0, "the exit is queued");
        assertEq(earn.processQueue(10), 0, "and the queue serves nothing while the longs are held");
    }

    /// @notice Longs moved into the vault's own AskResale escrow are still the vault's: the boundary stays shut
    ///         until they SELL, then the queue serves.
    /// @dev Remove `_resaleEscrowOpen()` from {EarnVault._positionOpen} and this goes red on the first assertion
    ///      after the resale is placed.
    function test_longsInResaleEscrowKeepTheBoundaryShutUntilTheySell() public {
        _carolHoldsLongs(UNITS);
        _vaultBidFills(UNITS);
        vm.prank(quoter);
        uint256 ask = earn.place(callId, V2Types.OrderKind.AskResale, PX, UNITS, 0);
        assertEq(ch.balanceOf(address(earn), callId), 0, "precondition: the longs left the wallet for the book");
        assertTrue(earn.hasOpenPosition(), "longs in the vault's resale escrow are still an open position");
        (uint256 shares,) = _depositFull(bob, DEP);
        assertEq(shares, 0, "so a deposit still queues");

        _take(carol, _buy(callId, _ids(ask), UNITS, PX, carol));
        assertFalse(earn.hasOpenPosition(), "once the resale fills the vault is flat");
        assertEq(earn.processQueue(10), 1, "and the queued deposit is served");
        assertGt(earn.balanceOf(bob), 0, "bob is minted against a complete, cash-only NAV");
    }

    /// @notice A long TRANSFERRED in by anyone but the book is not the vault's purchase and does not close the
    ///         boundary -- one gifted unit must not freeze deposits and exits.
    /// @dev Remove the `operator == address(orderBook)` condition from {EarnVault._noteIncoming} and this goes red.
    function test_aLongTransferredInDirectlyDoesNotCloseTheBoundary() public {
        _carolHoldsLongs(UNITS);
        vm.prank(carol);
        ch.safeTransferFrom(carol, address(earn), callId, 1, "");
        assertEq(ch.balanceOf(address(earn), callId), 1, "the gift was accepted, not reverted");
        assertFalse(earn.hasOpenPosition(), "a gifted long is not a position the vault took");
        assertGt(_deposit(bob, DEP), 0, "and a deposit is priced and minted rather than queued behind it");
    }
}

/// @notice T-440. The escrow clamp on both ledger paths (F4) and the funding gate that asks about OWED
///         WITHDRAWALS rather than about any queue entry (F5).
/// @dev THE TWO FINDINGS INTERACT, AND THAT IS WHY THEY ARE TESTED TOGETHER. Before F5, {fund} was reachable
///      only when the queue was empty; escrow exists only while a deposit is queued; so the old `_queueOpen()`
///      gate hid the fact that {fund} sized its delivery off the RAW wallet balance. Narrowing the gate to owed
///      withdrawals is what makes {fund}'s own clamp load-bearing, so `test_fund_cannotMoveEscrowIntoTheLedger`
///      is a guard on the F5 fix as much as on F4.
contract EarnVaultEscrowAndFundingGateTest is EarnVaultTestBase {
    uint128 internal constant WRITE_PRICE = uint128(V2Constants.PRICE_TICK * 10);

    function setUp() public override {
        super.setUp();
        _setSpot(address(nvda), 240_000_000);
    }

    /// @dev Gives the vault free USDG collateral on the Clearinghouse so its own AskWrite can fill. Runs BEFORE
    ///      anything is escrowed, so the clamp is not what limits it.
    function _fundVault() private {
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP);
    }

    function _vaultWritesAPut(uint64 units) private {
        vm.prank(quoter);
        uint256 orderId = earn.place(putId, WRITE, WRITE_PRICE, units, 0);
        _take(carol, _buy(putId, _ids(orderId), units, WRITE_PRICE, carol));
    }

    /// @dev Leaves the vault short (so deposits queue) with `bob`'s deposit escrowed in the wallet.
    ///      Returns bob's queue id.
    function _shortWithAnEscrowedDeposit() private returns (uint256 id) {
        _fundVault();
        _vaultWritesAPut(10);
        assertTrue(earn.hasOpenShort(), "premise: the vault is short, so a deposit queues");
        (, uint256 before) = earn.queue();
        _deposit(bob, DEP);
        (, id) = earn.queue();
        assertEq(id, before + 1, "premise: bob's deposit queued rather than minting");
        assertEq(earn.escrowedAssets(), DEP, "premise: bob's assets are escrowed in the wallet");
    }

    /*//////////////////////////////////////////////////////////////
                    F4 - depositToClearinghouse clamp
    //////////////////////////////////////////////////////////////*/

    /// @notice F4. A QUOTER cannot move a queued depositor's escrow into the Clearinghouse ledger, so the
    ///         depositor's cancel is never waiting on a ledger withdrawal.
    /// @dev RED WITHOUT THE CLAMP: `depositToClearinghouse` moves the whole wallet, and {cancelQueued}'s bare
    ///      `_asset.safeTransfer` then reverts for want of balance.
    function test_depositToClearinghouse_cannotMoveEscrowedDeposits() public {
        uint256 id = _shortWithAnEscrowedDeposit();
        uint256 wallet = usdg.balanceOf(address(earn));
        assertGe(wallet, DEP, "premise: the wallet holds at least the escrow");

        // Ask for the whole wallet. The clamp must cut it to the unescrowed part.
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), wallet);

        assertGe(usdg.balanceOf(address(earn)), DEP, "escrow left the wallet");

        uint256 bobBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        earn.cancelQueued(id);
        assertEq(usdg.balanceOf(bob) - bobBefore, DEP, "the cancelling depositor was not paid in full");
    }

    /// @notice POSITIVE CONTROL for the clamp: it limits the amount, it does not switch the function off.
    ///         With nothing escrowed, the QUOTER still moves the whole wallet.
    function test_depositToClearinghouse_stillMovesEverythingWhenNothingIsEscrowed() public {
        _deposit(alice, DEP);
        assertEq(earn.escrowedAssets(), 0, "premise: nothing is escrowed");
        uint256 wallet = usdg.balanceOf(address(earn));
        assertGt(wallet, 0, "premise: there is something to move");

        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), wallet);
        assertEq(usdg.balanceOf(address(earn)), 0, "the clamp refused an unescrowed move");
    }

    /// @notice The clamp is only for this vault's OWN asset. Escrow is denominated in `_asset`, so clamping a
    ///         Stock Token deposit would refuse ordinary quoting collateral and protect nothing.
    function test_depositToClearinghouse_doesNotClampAForeignAsset() public {
        _shortWithAnEscrowedDeposit();
        uint256 amount = 5e18;
        deal(address(nvda), address(earn), amount);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(nvda), amount);
        assertEq(nvda.balanceOf(address(earn)), 0, "a Stock Token deposit was clamped by USDG escrow");
    }

    /*//////////////////////////////////////////////////////////////
                              F4b - fund()
    //////////////////////////////////////////////////////////////*/

    /// @notice F4, SECOND PATH, and the one the source report does not name. {fund} sized its delivery off the
    ///         RAW wallet balance. Under the F5 gate below it is now reachable while a DEPOSIT is escrowed, so
    ///         without its own clamp a taker's fill would move a queued depositor's money into the ledger.
    /// @dev RED WITHOUT THE CLAMP IN {fund}: `delivered` comes back as the full wallet and {cancelQueued} reverts.
    function test_fund_cannotMoveEscrowIntoTheLedger() public {
        uint256 id = _shortWithAnEscrowedDeposit();
        _enableFunding();
        assertGt(earn.fundable(address(usdg)), 0, "premise: F5 lets funding stay on with only a deposit queued");

        uint256 wallet = usdg.balanceOf(address(earn));
        vm.prank(address(book));
        earn.fund(address(usdg), wallet);

        assertGe(usdg.balanceOf(address(earn)), DEP, "a fill moved escrow into the ledger");

        uint256 bobBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        earn.cancelQueued(id);
        assertEq(usdg.balanceOf(bob) - bobBefore, DEP, "the cancelling depositor was not paid in full");
    }

    /*//////////////////////////////////////////////////////////////
                        F5 - the funding gate
    //////////////////////////////////////////////////////////////*/

    /// @notice F5, THE DEFECT. Anyone could queue one base unit and cancel it, leaving a spent entry that held
    ///         the queue open and made the vault's venue liquidity invisible to the book for the rest of the
    ///         written period.
    /// @dev RED ON THE OLD GATE: `_queueOpen()` is `_head <= _tail` and a cancelled entry is still counted, so
    ///      both assertions below returned 0.
    function test_aCancelledDepositDoesNotSwitchOffFunding() public {
        uint256 id = _shortWithAnEscrowedDeposit();
        _enableFunding();

        vm.prank(bob);
        earn.cancelQueued(id);

        (uint256 head, uint256 tail) = earn.queue();
        assertLe(head, tail, "premise: the spent entry is still in the queue, which is the defect's mechanism");
        assertGt(earn.fundable(address(usdg)), 0, "a cancelled deposit switched funding off");

        uint256 freeBefore = ch.free(address(earn), address(usdg));
        vm.prank(address(book));
        earn.fund(address(usdg), 1_000e6);
        assertGt(ch.free(address(earn), address(usdg)) - freeBefore, 0, "fund delivered nothing while merely queued");
    }

    /// @notice THE HALF THAT MUST STILL REFUSE, and the guard on forbidden fix (a). Removing the gate entirely
    ///         would pass the test above and break this one: while the vault OWES a withdrawal it must stay
    ///         invisible to the book, because queued redeemers are paid before takers are quoted.
    function test_anOwedWithdrawalStillSwitchesOffFunding() public {
        _setAdapter();
        _enableFunding();
        uint256 bobShares = _deposit(bob, DEP);
        _sweep(DEP);

        venue.setFrozen(true);
        vm.prank(bob);
        (, uint256 id) = earn.redeem(bobShares, bob);
        assertGt(id, 0, "premise: bob is queued, not paid");

        // Cash arrives while bob is still owed. Without it the wallet is empty and the venue frozen, so
        // {fundable} would read 0 with the gate or without it and the assertion below could not see the gate.
        deal(address(usdg), address(earn), DEP);
        assertEq(earn.fundable(address(usdg)), 0, "the vault offered funding while it owed a withdrawal");

        // And cancelling the withdrawal puts it back: the gate tracks what is OWED, not what was ever queued.
        vm.prank(bob);
        earn.cancelQueued(id);
        venue.setFrozen(false);
        assertGt(earn.fundable(address(usdg)), 0, "funding stayed off after the withdrawal was withdrawn");
    }

    /// @notice The gate's counter must follow EVERY way a withdrawal leaves the queue, including the one SEC-41
    ///         added: after a total venue loss an entry that prices to nothing is released the way a cancel
    ///         releases it, and it must stop holding funding shut. This row was rebased onto SEC-41, whose arm
    ///         predates the counter and did not decrement it.
    /// @dev RED WITHOUT THE DECREMENT IN THE SEC-41 ARM: both released entries stay counted, and {fundable}
    ///      answers 0 with an empty queue and cash in the wallet -- for good, since nothing else would ever
    ///      decrement them.
    function test_anEntryReleasedAtZeroPriceStopsHoldingFundingShut() public {
        _setAdapter();
        _enableFunding();
        uint256 aliceShares = _deposit(alice, DEP);
        uint256 bobShares = _deposit(bob, DEP);
        _sweep(DEP * 2);

        venue.setFrozen(true);
        vm.prank(alice);
        earn.redeem(aliceShares, alice);
        vm.prank(bob);
        earn.redeem(bobShares, bob);

        venue.setFrozen(false);
        venue.loseAssets(DEP * 2);
        assertEq(earn.totalAssets(), 0, "premise: a total loss, so both entries price to nothing");
        earn.processQueue(2);
        (uint256 head, uint256 tail) = earn.queue();
        assertGt(head, tail, "premise: SEC-41 released both entries and the queue is empty");
        assertEq(earn.balanceOf(alice), aliceShares, "premise: released as a cancel releases, shares returned");

        deal(address(usdg), address(earn), DEP);
        assertEq(venue.withdrawable(), 0, "premise: the venue kept nothing");
        assertEq(earn.fundable(address(usdg)), DEP, "entries released at zero price kept funding switched off");
    }
}

/// @notice T-OP-042. `fundable` and `fund` derive from ONE rule, `EarnVault._deliverable`: the unescrowed wallet
///         plus the venue. Until this row `fundable` returned the RAW wallet plus the venue while `fund` (T-440/F5)
///         clamped its delivery to the unescrowed part, so with a deposit queued the book was quoted `escrow` more
///         than it could be given, `_preFund` asked for it, got a short delivery, and `quoteTake` promised units
///         `take` did not fill (T-OP-019 F-1). And `fund` sized its venue pull against the raw wallet too, so even
///         a venue that could cover the gap was asked for `escrow` too little.
contract EarnVaultFundableBoundTest is EarnVaultTestBase {
    uint128 internal constant WRITE_PRICE = uint128(V2Constants.PRICE_TICK * 10);
    /// @dev Asks for more collateral than the vault's ledger holds (4,979 USDG after the seed below backs 4,500 x
    ///      2.10 = 9,450 USDG only with the venue's 5,000), so the book must pre-fund from the vault, and the
    ///      venue must be drawn to do it. The book reserves a maker's collateral WHOLE OR NOTHING per fill
    ///      (`OrderBook._reserveCollateral`), so a budget that is short fills 0, not fewer units -- the first draft
    ///      of this case asked for 8,000 and read a 0 fill as "the take filled something" failing.
    uint64 internal constant BIG_WRITE = 4_500;

    function setUp() public override {
        super.setUp();
        // Spot 240 against PUT_STRIKE 210: the put is out of the money, so the ask floor is zero and the price
        // guard stays out of these cases.
        _setSpot(address(nvda), 240_000_000);
    }

    /// @dev The vault writes `units` of the put and carol takes them, so the vault is short and a deposit queues.
    function _vaultWritesAPut(uint64 units) private returns (uint256 orderId) {
        vm.prank(quoter);
        orderId = earn.place(putId, WRITE, WRITE_PRICE, units, 0);
        _take(carol, _buy(putId, _ids(orderId), units, WRITE_PRICE, carol));
    }

    /// @dev Leaves bob's deposit escrowed in the wallet while the vault is short. Returns his queue id.
    function _queueBob() private returns (uint256 id) {
        assertTrue(earn.hasOpenShort(), "premise: the vault is short, so a deposit queues");
        (, uint256 before) = earn.queue();
        _deposit(bob, DEP);
        (, id) = earn.queue();
        assertEq(id, before + 1, "premise: bob's deposit queued rather than minting");
        assertEq(earn.escrowedAssets(), DEP, "premise: bob's assets are escrowed in the wallet");
    }

    /*//////////////////////////////////////////////////////////////
                 AC2: fundable == what fund(fundable) delivers
    //////////////////////////////////////////////////////////////*/

    /// @dev THE ROW'S EQUALITY, with escrow AND a venue, which is the state where the old code was wrong twice: the
    ///      view over-reported by the escrow, and `fund` sized its venue pull without it. RED ON THE OLD CODE at the
    ///      first assertion (`fundable` was wallet + venue) and again at the event (delivered was `escrow` short).
    function test_fundable_isTheUnescrowedWalletPlusTheVenueAndFundDeliversExactlyIt() public {
        _setAdapter();
        _enableFunding();
        _deposit(alice, DEP);
        _sweep(DEP / 2);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), 1_000e6);
        _vaultWritesAPut(10);
        uint256 bobId = _queueBob();

        uint256 wallet = usdg.balanceOf(address(earn));
        uint256 venueCash = venue.withdrawable();
        uint256 escrow = earn.escrowedAssets();
        assertGt(venueCash, 0, "premise: the venue holds cash the vault can pull");
        assertGt(wallet, escrow, "premise: the wallet holds more than the escrow");

        uint256 quoted = earn.fundable(address(usdg));
        assertEq(quoted, wallet + venueCash - escrow, "fundable is the UNESCROWED wallet plus the venue");
        assertLt(quoted, wallet + venueCash, "and strictly less than the raw wallet plus the venue, by the escrow");

        uint256 freeBefore = ch.free(address(earn), address(usdg));
        vm.expectEmit(true, false, false, true, address(earn));
        emit IEarnVault.Funded(address(usdg), quoted, quoted);
        vm.prank(address(book));
        earn.fund(address(usdg), quoted);

        assertEq(ch.free(address(earn), address(usdg)) - freeBefore, quoted, "the ledger received exactly the quote");
        // AC3: {fund} DOES draw from the venue (`EarnVault.sol`, the `a.withdraw` inside `fund`), so the venue term
        // in {fundable} is legitimate. The whole venue was needed here: the unescrowed wallet alone was short of
        // the quote by exactly the venue's cash.
        assertEq(venue.withdrawable(), 0, "the venue was drawn down to cover the quote");
        assertEq(usdg.balanceOf(address(earn)), escrow, "the wallet keeps exactly the escrow, nothing more");

        uint256 bobBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        earn.cancelQueued(bobId);
        assertEq(usdg.balanceOf(bob) - bobBefore, DEP, "the queued depositor can still take every base unit back");
    }

    /// @dev THE CONTROL: with nothing escrowed the bound is invisible, and both sides are the raw wallet plus the
    ///      venue exactly as before this row. Guards the wrong fix (b), dropping the venue term.
    function test_fundable_control_withNothingEscrowedItIsTheWalletPlusTheVenueAndFundDeliversIt() public {
        _setAdapter();
        _enableFunding();
        _deposit(alice, DEP);
        _sweep(DEP / 2);
        assertEq(earn.escrowedAssets(), 0, "premise: nothing is escrowed");

        uint256 wallet = usdg.balanceOf(address(earn));
        uint256 venueCash = venue.withdrawable();
        uint256 quoted = earn.fundable(address(usdg));
        assertEq(quoted, wallet + venueCash, "no escrow: the wallet plus the venue");

        uint256 freeBefore = ch.free(address(earn), address(usdg));
        vm.expectEmit(true, false, false, true, address(earn));
        emit IEarnVault.Funded(address(usdg), quoted, quoted);
        vm.prank(address(book));
        earn.fund(address(usdg), quoted);
        assertEq(ch.free(address(earn), address(usdg)) - freeBefore, quoted, "delivered in full");
    }

    /// @dev The escrow bound alone, no venue: `fund` asked for the whole wallet delivers the unescrowed part and
    ///      `fundable` said so beforehand. The existing `test_fund_cannotMoveEscrowIntoTheLedger` pins the clamp;
    ///      this pins that the VIEW now agrees with it.
    function test_fundable_withoutAVenueIsTheUnescrowedWallet() public {
        _enableFunding();
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP);
        _vaultWritesAPut(10);
        _queueBob();

        uint256 wallet = usdg.balanceOf(address(earn));
        uint256 quoted = earn.fundable(address(usdg));
        assertEq(quoted, wallet - DEP, "the view is the wallet minus the escrow");

        uint256 freeBefore = ch.free(address(earn), address(usdg));
        vm.prank(address(book));
        earn.fund(address(usdg), wallet);
        assertEq(ch.free(address(earn), address(usdg)) - freeBefore, quoted, "asked for the wallet, given the quote");
    }

    /*//////////////////////////////////////////////////////////////
                    AC6: quoteTake == take (T-OP-019 F-1)
    //////////////////////////////////////////////////////////////*/

    /// @dev THE CONSEQUENCE THE VIEW'S LIE HAD, through the book. With funding on, the vault short, and bob's deposit
    ///      escrowed in the wallet, the vault rests an AskWrite bigger than its ledger can back. `quoteTake` budgets
    ///      the maker its `fundable` answer; `take` pre-funds, gets what `fund` actually delivers, and re-plans on
    ///      that. RED ON THE OLD CODE: the quote counted bob's escrow as fundable collateral and promised 8,000
    ///      units; `fund` refused the escrow and the take filled what the ledger alone could back.
    function test_quoteTakeEqualsTakeWithAnOpenShortAQueuedDepositAndFundingOn() public {
        _setAdapter();
        _enableFunding();
        vm.prank(admin);
        book.setFundingAllowed(address(earn), true);
        vm.prank(admin);
        earn.setBookFunding(true);

        _deposit(alice, DEP);
        _sweep(DEP / 2);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP / 2);
        _vaultWritesAPut(10);
        _queueBob();

        // The ask needs more collateral than the ledger holds and no more than the ledger plus the venue, so the
        // fill is decided by what the book can pre-fund from the vault -- the number under test. The wallet holds
        // only bob's escrow and the premium, so the old view quoted the escrow as fundable and the old `fund`,
        // sizing its pull against the raw wallet, never asked the venue for it.
        uint256 need = uint256(BIG_WRITE) * ch.collateralPerUnit(putId);
        uint256 ledger = ch.free(address(earn), address(usdg));
        assertLt(ledger, need, "premise: the ledger cannot back the ask alone");
        assertGe(ledger + earn.fundable(address(usdg)), need, "premise: the ledger plus the honest quote can");
        uint256 venueBefore = venue.withdrawable();
        vm.prank(quoter);
        uint256 orderId = earn.place(putId, WRITE, WRITE_PRICE, BIG_WRITE, 0);
        V2Types.TakeParams memory p = _buy(putId, _ids(orderId), BIG_WRITE, WRITE_PRICE, carol);

        vm.prank(carol);
        (uint64 quoted,,,) = book.quoteTake(p);
        uint64 filled = _take(carol, p);

        assertEq(quoted, filled, "the quote promised units the take did not fill");
        // Positive controls: the fill happened, it happened BECAUSE the venue was drawn, and the escrow stayed put.
        assertEq(filled, BIG_WRITE, "the whole ask filled once the venue covered the ledger's shortfall");
        assertLt(venue.withdrawable(), venueBefore, "the venue was drawn to fund the fill");
        assertEq(earn.escrowedAssets(), DEP, "and the escrow never moved");
        assertGe(usdg.balanceOf(address(earn)), DEP, "the wallet still holds every escrowed base unit");
    }

    /// @dev THE OTHER HALF OF F-1, and the case that reddens on the OLD VIEW ALONE. The ask above fits inside the
    ///      honest capacity, so a `fund` that pulls correctly delivers it whatever the view said. This ask needs
    ///      more than the ledger plus the honest quote and less than the ledger plus the RAW wallet plus the venue:
    ///      the old view quoted it in full, and the book -- which reserves collateral whole or nothing -- filled
    ///      nothing. Both sides must now agree, and what they agree on is zero.
    function test_quoteTakeEqualsTake_whenTheAskExceedsWhatIsHonestlyFundable() public {
        _setAdapter();
        _enableFunding();
        vm.prank(admin);
        book.setFundingAllowed(address(earn), true);
        vm.prank(admin);
        earn.setBookFunding(true);

        _deposit(alice, DEP);
        _sweep(DEP / 2);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP / 2);
        _vaultWritesAPut(10);
        _queueBob();

        uint64 tooBig = 6_000;
        uint256 need = uint256(tooBig) * ch.collateralPerUnit(putId);
        uint256 ledger = ch.free(address(earn), address(usdg));
        uint256 raw = usdg.balanceOf(address(earn)) + venue.withdrawable();
        // The honest capacity is computed HERE, not read from `fundable`, so a view that lies fails the assertion
        // below on the quote rather than on this premise.
        uint256 honest = raw - earn.escrowedAssets();
        assertGt(need, ledger + honest, "premise: beyond what is honestly fundable");
        assertLe(need, ledger + raw, "premise: within what the raw wallet plus the venue would have promised");
        vm.prank(quoter);
        uint256 orderId = earn.place(putId, WRITE, WRITE_PRICE, tooBig, 0);
        V2Types.TakeParams memory p = _buy(putId, _ids(orderId), tooBig, WRITE_PRICE, carol);

        vm.prank(carol);
        (uint64 quoted,,,) = book.quoteTake(p);
        uint64 filled = _take(carol, p);
        assertEq(quoted, filled, "the quote promised units the take did not fill");
        assertEq(filled, 0, "positive control: the book reserves whole or nothing, and this could not be backed");
        assertEq(earn.escrowedAssets(), DEP, "and the escrow never moved");
    }

    /*//////////////////////////////////////////////////////////////
                AC5: the outflow bucket ignores the ledger (F-3)
    //////////////////////////////////////////////////////////////*/

    /// @dev `_cash` no longer counts `clearinghouse.free`. A Bid is charged exactly its escrow with a large ledger
    ///      balance present, and moving assets between the wallet and the ledger -- which is not a booked call in
    ///      either direction -- neither charges nor credits the bucket. NOT RED ON THE OLD CODE, and said so: no
    ///      booked call ({place}, {cancel}) moves `free`, which is why the term was inert; this pins the rule for
    ///      the day one does, so the sibling's loop (MakerVault.sol:119-122) cannot be reintroduced silently.
    function test_outflowCap_chargesNetWalletOutflowAndIgnoresTheClearinghouseLedger() public {
        _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), DEP / 2);
        (uint256 used,) = earn.outflow();
        assertEq(used, 0, "premise: nothing charged yet");

        // A Bid on the CALL: spot 240 against strike 230 leaves 10 USDG of intrinsic, so a 2.00 bid is under the
        // guard's cap; the put is out of the money and its bid cap is the band alone.
        uint128 bidPrice = 2_000_000;
        uint64 bidUnits = 1_000;
        uint256 escrow = uint256(bidPrice) * bidUnits / V2Constants.UNITS_PER_SHARE;
        vm.prank(quoter);
        uint256 bidId = earn.place(callId, BID, bidPrice, bidUnits, 0);
        (used,) = earn.outflow();
        assertEq(used, escrow, "a Bid is charged exactly its escrow, with half the NAV sitting on the ledger");

        vm.prank(quoter);
        earn.withdrawFromClearinghouse(address(usdg), 1_000e6);
        (used,) = earn.outflow();
        assertEq(used, escrow, "ledger to wallet is not an outflow and not a credit");
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), 2_000e6);
        (used,) = earn.outflow();
        assertEq(used, escrow, "wallet to ledger is not an outflow either");

        vm.prank(quoter);
        earn.cancel(_ids(bidId));
        (used,) = earn.outflow();
        assertEq(used, 0, "the cancel credits the escrow back, and only the escrow");
    }
}
