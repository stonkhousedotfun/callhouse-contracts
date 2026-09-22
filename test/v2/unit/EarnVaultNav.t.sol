// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EarnVaultTestBase} from "./EarnVault.t.sol";
import {IEarnVault} from "../../../src/v2/interfaces/IEarnVault.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice T-OP-026 / SEC-19 / F-CP-03. `EarnVault.totalAssets` has NO TERM FOR AN OPEN SHORT, and this suite pins
///         that it does not need one: the number is allowed to be wrong while a series is written because NOTHING IS
///         SETTLED AT IT. Every share minted, every share burned and every fee charged across a written-then-settled
///         episode is priced at a flat NAV, and this file measures each of those prices exactly.
///
/// @dev THE FINDING AS RE-DERIVED AT 6b0a4e7c, file:line for every element:
///        - the defect: `EarnVault.sol:981-991` `totalAssets` = wallet + `clearinghouse.free` + `_bookEscrow` + venue
///          - `_escrowedAssets`. A fill of the vault's own AskWrite runs `Clearinghouse.mint` (`Clearinghouse.sol:640`),
///          which debits `free` by `need + fee` (`:657-659`) and credits a short; neither the locked collateral nor the
///          short's value is in any term, so NAV drops by ~locked notional and recovers only at redemption.
///        - reachability: the ask path is LIVE. `EarnVault.place` (`EarnVault.sol:900-928`) accepts `AskWrite` under
///          QUOTER (`script/v2/roles.v8.json:218`), `_checkPrice` bounds the price, not the kind, and no launch
///          config disables it (no ops service rests Earn asks; the QUOTER hot key can). So the row's bid-only arm
///          does not apply and the accepted-risk shortcut is NOT available.
///        - why the consequence does not follow: the FLAT BOUNDARY. `deposit` queues while `_positionOpen()`
///          (`:371-392`), `redeem` queues (`:431-433`), `processQueue` serves nothing (`:465`); `_positionOpen`
///          (`:1259-1260`) is `hasOpenShort || _holdsLongs || _resaleEscrowOpen`, and the short is recorded on the
///          mint by the ERC-1155 hook (T-298/T-433). `skim` (`:631-661`) is guarded by `_queueOpen` only, and the
///          understated price can only DEFER its fee, never inflate it -- measured below.
///        - the design, stated against the review's two options rather than assumed: a "conservative" term
///          (locked minus worst-case payout, capped at locked) is IDENTICALLY ZERO for a fully collateralised write,
///          which is the only kind this vault makes -- a cash-secured put's worst case is its whole strike
///          collateral, a covered call's is the whole stock -- so option (i) reduces to the current no-term. Option
///          (ii), the boundary, is what the code does. A mark would be the third design and it is the one
///          `IEarnVault.totalAssets` forbids. So there is no code change in this row: the deliverable is the pin.
///
///      WHAT THIS SUITE DOES NOT ESTABLISH: that every future pricing path honours the boundary (it pins the four
///      that exist at 6b0a4e7c), and liveness -- the queue stays shut until SOMEONE redeems the vault's short after
///      settlement. That is permissionless (`Clearinghouse.sol:1233` allows third-party redeem unless the holder
///      opted out, and the vault never does), so it is a keeper-bounty question and not a pricing one.
contract EarnVaultOpenShortNavTest is EarnVaultTestBase {
    /// @dev 2.00 USDG per share, 20,000 ticks; 2,000 units = 20 shares. Chosen so the locked collateral
    ///      (2,000 x 2.10 = 4,200 USDG) is 42 % of the 10,000 USDG NAV and the premium (40 USDG) is 0.4 %: the gap
    ///      then MOVES every division below, so an exact-price assertion cannot pass by rounding the way T-184's
    ///      1,000-base-unit premium did (`EarnVault.t.sol`, `test_processQueueServesTheQueuedDepositOnceFlat`).
    uint128 internal constant WRITE_PRICE = 2_000_000;
    uint64 internal constant WRITE_UNITS = 2_000;
    uint256 internal constant ONE_SHARE = 1e18;

    function setUp() public override {
        super.setUp();
        // Spot 240 against PUT_STRIKE 210: the put is out of the money, so the ask floor in `_checkPrice` is zero and
        // the settlement below leaves the short worthless, which is what lets the collateral come back in full.
        _setSpot(address(nvda), 240_000_000);
    }

    /// @dev Half of alice's deposit goes to the Clearinghouse ledger as writing collateral; HALF STAYS IN THE
    ///      WALLET, deliberately. `_raise` (`EarnVault.sol:1326-1335`) pays a redeemer from the wallet and the venue,
    ///      never from the ledger, so a vault whose whole NAV sat on the ledger could not pay ANY exit at once and
    ///      would queue it for liquidity -- and a boundary mutation that priced the exit at the depressed NAV would
    ///      then hide behind that liquidity queue. With 5,000 USDG in the wallet a half exit (~2,900 USDG at the
    ///      depressed price) is payable on the spot, so the only thing standing between alice and a bad price is the
    ///      boundary itself. Found by breaking: the first draft seeded the whole DEP onto the ledger and stayed green
    ///      with the redeem boundary deleted.
    uint256 internal constant LEDGER = DEP / 2;

    /// @dev Seeds the vault with alice's deposit, returns her shares and the flat NAV.
    function _seed() internal returns (uint256 aliceShares, uint256 navFlat) {
        aliceShares = _deposit(alice, DEP);
        vm.prank(quoter);
        earn.depositToClearinghouse(address(usdg), LEDGER);
        navFlat = earn.totalAssets();
        assertEq(navFlat, DEP, "precondition: moving assets to the ledger does not move NAV");
    }

    /// @dev The vault rests an AskWrite on the put and carol takes all of it. Returns the NET premium the book paid
    ///      the vault (its fee already taken), measured as the wallet delta -- `_payOrOwe` pays the maker directly and
    ///      `owed` stays 0, which `test_thePremiumIsPaidStraightToTheWalletAndOwedIsOnlyTheFallback` already pins.
    function _writeAndFill() internal returns (uint256 premiumNet) {
        uint256 walletBefore = usdg.balanceOf(address(earn));
        vm.prank(quoter);
        uint256 orderId = earn.place(putId, WRITE, WRITE_PRICE, WRITE_UNITS, 0);
        uint64 filled = _take(carol, _buy(putId, _ids(orderId), WRITE_UNITS, WRITE_PRICE, carol));
        assertEq(filled, WRITE_UNITS, "precondition: the whole ask filled, so the locked figure below is exact");
        premiumNet = usdg.balanceOf(address(earn)) - walletBefore;
        assertGt(premiumNet, 0, "precondition: the premium landed in the wallet");
        assertEq(book.owed(address(earn)), 0, "precondition: nothing is parked in owed, so the wallet delta is all of it");
    }

    /// @dev Settle the put worthless and redeem the vault's short so the collateral unlocks. MIRRORED from
    ///      `EarnVaultFlatBoundaryQueueTest._backToFlat`: settling alone is not enough, the short must be redeemed.
    function _settleAndRedeemTheShort() internal {
        vm.warp(FRI_2026_09_18 + V2Constants.FINALIZE_DELAY);
        oracle.setSettlement(address(nvda), FRI_2026_09_18, V2Types.SettlementStatus.Finalized, 240_000_000);
        vm.prank(keeper);
        ch.settle(putId);
        // ANY caller may redeem for the vault: `Clearinghouse.sol:1233` permits third-party redemption unless the
        // holder opted out, and the vault never sets that preference. bob does it here so the test does not lean on
        // the vault's own key for the liveness half of the boundary.
        vm.prank(bob);
        ch.redeem(_short(putId), address(earn));
    }

    /*//////////////////////////////////////////////////////////////
                     AC1: THE ASK PATH IS LIVE AT LAUNCH
    //////////////////////////////////////////////////////////////*/

    /// @dev Reachability, pinned rather than asserted in prose. The QUOTER can rest an AskWrite; nobody else can;
    ///      and nothing in the vault's configuration surface turns the kind off -- there is no such setter. If a
    ///      later change adds a bid-only switch, this is the case to retire, and `docs/V8-ACCEPTED-RISKS.md` SEC-19
    ///      is the entry to rewrite with it.
    function test_sec19_theAskPathIsLiveForTheQuoterAndForNobodyElse() public {
        _seed();
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        earn.place(putId, WRITE, WRITE_PRICE, WRITE_UNITS, 0);

        vm.prank(quoter);
        uint256 orderId = earn.place(putId, WRITE, WRITE_PRICE, WRITE_UNITS, 0);
        assertGt(orderId, 0, "the quoter rested an AskWrite against depositor collateral");
        assertEq(uint8(_order(orderId).kind), uint8(WRITE), "and it is a write, not a resale");
    }

    /*//////////////////////////////////////////////////////////////
                    THE GAP, TO THE BASE UNIT (SEC-19 ITSELF)
    //////////////////////////////////////////////////////////////*/

    /// @dev THE DEFECT'S ARITHMETIC, PINNED. NAV drops by exactly `units x collateralPerUnit + rent - premiumNet`:
    ///      the two debits `Clearinghouse.mint` makes to `free` (`Clearinghouse.sol:657-659`), less the one credit
    ///      the book pays to the wallet. T-184's case asserts only `<`; this one asserts the number, so a term added
    ///      to `totalAssets` later -- or a change in what the mint debits -- reds here rather than passing silently
    ///      as "still smaller". The rent is read from the Clearinghouse, not retyped: the base fixture's
    ///      `mintFeePpm` is 0 and the term is kept so a fixture with rent on still adds up.
    function test_sec19_theGapIsExactlyLockedCollateralPlusRentLessTheNetPremium() public {
        (, uint256 navFlat) = _seed();
        uint256 locked = uint256(WRITE_UNITS) * ch.collateralPerUnit(putId);
        uint256 rent = ch.mintFee(putId, WRITE_UNITS);
        assertGt(locked, 0, "precondition: a put locks USDG per unit");

        uint256 premiumNet = _writeAndFill();
        uint256 navDuring = earn.totalAssets();

        assertTrue(earn.hasOpenShort(), "the vault knows it is short");
        assertGt(locked, premiumNet, "positive control: the gap is collateral-sized, not premium-sized");
        assertEq(navFlat - navDuring, locked + rent - premiumNet, "NAV drop == locked + rent - net premium, exactly");
    }

    /*//////////////////////////////////////////////////////////////
              NOTHING IS SETTLED AT THE DEPRESSED NUMBER, EXACTLY
    //////////////////////////////////////////////////////////////*/

    /// @dev Shared shape for the two episodes below: the prices that must NOT be paid, computed exactly as
    ///      {deposit} and {redeem} would have computed them at the depressed number.
    struct Depressed {
        uint256 nav;
        uint256 supply;
        uint256 overMint;
        uint256 underPay;
    }

    function _depressed(uint256 half) internal returns (Depressed memory d) {
        d.nav = earn.totalAssets();
        d.supply = earn.totalSupply();
        d.overMint = Math.mulDiv(DEP, d.supply, d.nav);
        d.underPay = Math.mulDiv(half, d.nav, d.supply);
        // T-OP-065: the view no longer quotes the depressed rate meanwhile -- it refuses by name. The prices that
        // must not happen are computed above from totalAssets directly, exactly as {deposit} / {redeem} would.
        vm.expectRevert(IEarnVault.PositionOpen.selector);
        earn.convertToShares(DEP);
    }

    /// @dev EPISODE A, A DEPOSIT ARRIVES FIRST. The queue is empty when bob deposits, so the only thing that can queue
    ///      him is the position boundary in {deposit} itself (`EarnVault.sol:371-392`) -- delete that arm and he is
    ///      minted on the spot at the depressed rate. Alice's exit then joins behind him. Once flat, both are served
    ///      in FIFO order at the RECOVERED NAV, to the base unit, each priced off the supply and NAV the instant
    ///      before it is served. Then the two prices that did not happen are named, and shown strictly wrong-sided,
    ///      which is the positive control that the depressed number is materially different at this size.
    function test_sec19_aDepositArrivingWhileShortIsMintedOnlyAtTheRecoveredNav() public {
        (uint256 aliceShares, uint256 navFlat) = _seed();
        uint256 premiumNet = _writeAndFill();
        uint256 half = aliceShares / 2;
        Depressed memory d = _depressed(half);
        assertLt(d.nav, navFlat, "the number is depressed while the short is open");

        (uint256 bobShares, uint256 bobId) = _depositFull(bob, DEP);
        assertEq(bobShares, 0, "bob queued: the boundary, not the queue, stopped him");
        uint256 aliceUsdgBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        (uint256 paidNow, uint256 aliceId) = earn.redeem(half, alice);
        assertEq(paidNow, 0, "alice queued");
        assertGt(aliceId, bobId, "FIFO: bob's deposit is ahead of alice's exit");
        assertEq(earn.processQueue(10), 0, "nothing is served while the short is open");
        assertEq(earn.totalSupply(), d.supply, "supply did not move: no share was minted or burned meanwhile");

        _settleAndRedeemTheShort();
        assertFalse(earn.hasOpenShort(), "flat again");
        uint256 navRecovered = earn.totalAssets();
        assertEq(navRecovered, navFlat + premiumNet, "the collateral came back in full: NAV is flat NAV plus premium");

        // Served-at figures, read the instant before service, with the escrowed deposit still excluded.
        uint256 supplyAtBob = earn.totalSupply();
        uint256 expectBob = Math.mulDiv(DEP, supplyAtBob, navRecovered);
        // After bob is minted the NAV includes his assets and the supply his shares; alice is priced off both.
        uint256 expectAlice = Math.mulDiv(half, navRecovered + DEP, supplyAtBob + expectBob);

        assertEq(earn.processQueue(10), 2, "both entries served in one call");
        assertEq(earn.balanceOf(bob), expectBob, "bob minted at exactly the recovered NAV");
        assertEq(usdg.balanceOf(alice) - aliceUsdgBefore, expectAlice, "alice paid at exactly the recovered NAV");
        assertEq(earn.totalSupply(), supplyAtBob + expectBob - half, "her shares burned, his minted, nothing else");

        assertLt(expectBob, d.overMint, "the over-mint did not happen: fewer shares than the depressed quote");
        assertGt(expectAlice, d.underPay, "the under-payment did not happen: more assets than the depressed price");
        // Alice's remaining half is worth what it was plus her slice of the premium: nobody's value moved to anyone.
        assertGe(earn.convertToAssets(earn.balanceOf(alice)), DEP / 2, "the stayer lost nothing to the episode");
    }

    /// @dev EPISODE B, AN EXIT ARRIVES FIRST, and this is the one the redeem boundary is actually tested by. With the
    ///      queue empty and 5,000 USDG payable in the wallet, {redeem} (`EarnVault.sol:431-433`) has every reason
    ///      to pay alice NOW except the boundary -- delete that arm and she is paid on the spot at the depressed
    ///      price. (Episode A cannot see that mutation: bob's queued deposit is ahead of her, so the liquidity
    ///      branch queues her anyway and she is served at the recovered NAV regardless.) Bob's deposit then joins
    ///      behind her, and once flat she is paid first and he is minted off the NAV and supply her burn leaves.
    function test_sec19_anExitArrivingWhileShortIsPaidOnlyAtTheRecoveredNav() public {
        (uint256 aliceShares, uint256 navFlat) = _seed();
        uint256 premiumNet = _writeAndFill();
        uint256 half = aliceShares / 2;
        Depressed memory d = _depressed(half);
        assertGe(usdg.balanceOf(address(earn)), d.underPay, "precondition: the wallet could pay her now");

        uint256 aliceUsdgBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        (uint256 paidNow, uint256 aliceId) = earn.redeem(half, alice);
        assertEq(paidNow, 0, "alice queued: the boundary, not liquidity, stopped her");
        assertEq(usdg.balanceOf(alice), aliceUsdgBefore, "and nothing was paid");
        (uint256 bobShares, uint256 bobId) = _depositFull(bob, DEP);
        assertEq(bobShares, 0, "bob queued");
        assertGt(bobId, aliceId, "FIFO: alice's exit is ahead of bob's deposit");
        assertEq(earn.processQueue(10), 0, "nothing is served while the short is open");

        _settleAndRedeemTheShort();
        uint256 navRecovered = earn.totalAssets();
        assertEq(navRecovered, navFlat + premiumNet, "the collateral came back in full");

        uint256 supplyAtAlice = earn.totalSupply();
        uint256 expectAlice = Math.mulDiv(half, navRecovered, supplyAtAlice);
        // Bob is priced after her burn and her payout: smaller supply, smaller NAV, same share price.
        uint256 expectBob = Math.mulDiv(DEP, supplyAtAlice - half, navRecovered - expectAlice);

        assertEq(earn.processQueue(10), 2, "both entries served in one call");
        assertEq(usdg.balanceOf(alice) - aliceUsdgBefore, expectAlice, "alice paid at exactly the recovered NAV");
        assertEq(earn.balanceOf(bob), expectBob, "bob minted at exactly the recovered NAV");

        assertGt(expectAlice, d.underPay, "the under-payment did not happen");
        assertLt(expectBob, d.overMint, "the over-mint did not happen");
    }

    /*//////////////////////////////////////////////////////////////
                       THE SKIM CANNOT CHARGE THE RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @dev {skim} is the ONE pricing path not behind `_positionOpen` (`EarnVault.sol:631-661`: it refuses on
    ///      `_queueOpen` and on a flat-or-losing price). Under an open short the price is understated, so a real
    ///      gain can only look SMALLER than it is: the fee is deferred, and when the collateral returns the recovery
    ///      is charged only insofar as it carries the gain -- never on its own. Measured: the skim takes zero while
    ///      short (the mark is untouched), then takes `skimBps` of the PREMIUM once flat, and a second call takes
    ///      nothing. If a future change let the understated price move the mark DOWN, the recovery would be charged
    ///      as performance and the second assertion here would carry the collateral in its number.
    function test_sec19_skimChargesThePremiumOnceAndNeverTheCollateralRecovery() public {
        vm.prank(admin);
        earn.setSkimBps(1_000);
        (, uint256 navFlat) = _seed();
        uint256 mark = earn.highWaterMark();
        // Not exactly 1.0: the first deposit also credits MIN_SHARES to DEAD_SHARES, so the mark is a hair under.
        assertEq(mark, earn.convertToAssets(ONE_SHARE), "precondition: the first deposit set the mark at its price");

        uint256 premiumNet = _writeAndFill();
        assertLt(earn.totalAssets(), navFlat, "understated while short");
        assertEq(earn.skim(), 0, "a price below the mark takes nothing, even though a real gain was earned");
        assertEq(earn.highWaterMark(), mark, "and the mark did not move, so nothing is charged twice later");

        _settleAndRedeemTheShort();
        uint256 splitterBefore = usdg.balanceOf(splitter);
        // MIRRORED from {skim}: gain = (priceNow - mark) x supply / ONE_SHARE, fee = gain x skimBps / BPS. The
        // supply includes the dead shares, so this is the premium to within a few base units, not the premium.
        uint256 priceNow = earn.convertToAssets(ONE_SHARE);
        uint256 expectGain = Math.mulDiv(priceNow - mark, earn.totalSupply(), ONE_SHARE);
        uint256 expectFee = expectGain * 1_000 / V2Constants.BPS;
        assertApproxEqAbs(expectGain, premiumNet, 10, "positive control: the gain the skim sees IS the premium");
        uint256 fee = earn.skim();
        assertEq(fee, expectFee, "the fee is skimBps of the premium-sized gain and of nothing else");
        assertLt(fee, premiumNet, "positive control: a fraction of the premium cannot contain the collateral");
        assertEq(usdg.balanceOf(splitter) - splitterBefore, fee, "paid to the splitter");
        assertEq(earn.highWaterMark(), earn.convertToAssets(ONE_SHARE), "the mark is the price after the fee");
        assertEq(earn.skim(), 0, "a second skim on the same flat NAV takes nothing");
    }

    /*//////////////////////////////////////////////////////////////
          T-OP-065: THE VIEWS FAIL LOUD, THE INDICATIVE VIEW IS A MARK
    //////////////////////////////////////////////////////////////*/

    /// @dev (i). While the vault is short, `convertToShares` and `convertToAssets` revert PositionOpen -- the
    ///      ERC-4626-shaped quote of the understated NAV is gone, not relabelled -- and once the short is settled
    ///      and redeemed they answer the flat NAV again. `totalAssets` itself keeps answering throughout: the
    ///      boundary reads it.
    ///
    ///      PROVE-BY-BREAKING (authored): delete the `if (_positionOpen()) revert PositionOpen();` line in either
    ///      view and the matching `expectRevert` here fails "next call did not revert as expected".
    function test_t065_convertViewsRevertPositionOpenWhileShort_andAnswerTheFlatNavOnceRedeemed() public {
        (uint256 aliceShares, uint256 navFlat) = _seed();
        // Priced off the whole supply, which includes the dead shares the first batch minted (SEC-17), so alice's
        // shares are worth a hair under DEP; the point is that the view ANSWERS, at the flat NAV's rate.
        uint256 supply = earn.totalSupply();
        assertEq(earn.convertToAssets(aliceShares), Math.mulDiv(aliceShares, navFlat, supply), "flat: the view prices");
        assertEq(earn.convertToShares(DEP), Math.mulDiv(DEP, supply, navFlat), "flat: round trip");

        _writeAndFill();
        assertTrue(earn.hasOpenShort(), "precondition: the vault is short");
        uint256 navDuring = earn.totalAssets();
        assertLt(navDuring, navFlat, "precondition: totalAssets is understated by the locked collateral");

        vm.expectRevert(IEarnVault.PositionOpen.selector);
        earn.convertToShares(DEP);
        vm.expectRevert(IEarnVault.PositionOpen.selector);
        earn.convertToAssets(aliceShares);
        assertEq(earn.totalAssets(), navDuring, "totalAssets is unchanged and still answers: the boundary reads it");

        _settleAndRedeemTheShort();
        assertFalse(earn.hasOpenShort(), "the short is gone");
        uint256 navRecovered = earn.totalAssets();
        assertGt(navRecovered, navDuring, "the collateral came home");
        assertEq(
            earn.convertToAssets(aliceShares),
            Math.mulDiv(aliceShares, navRecovered, earn.totalSupply()),
            "flat again: the view prices at the recovered NAV"
        );
        assertEq(
            earn.convertToShares(DEP), Math.mulDiv(DEP, earn.totalSupply(), navRecovered), "flat again: round trip"
        );
    }

    /// @dev (ii). The indicative view equals `totalAssets + locked - intrinsic(spot)` with the intrinsic taken from
    ///      the same OptionMath settlement will use, at the series oracle's spot; equals `totalAssets` when flat;
    ///      never moves `totalAssets`. Three spots: OTM (intrinsic 0), ITM by 10 USDG per share (a known intrinsic),
    ///      and no usable spot (the whole collateral treated as intrinsic, so the view falls back to totalAssets).
    ///
    ///      PROVE-BY-BREAKING (authored): (a) drop the `- intrinsic` term and the ITM case fails by the intrinsic
    ///      amount; (b) drop the `!ok` guard and the no-spot case adds the collateral back for a spot of zero.
    function test_t065_indicativeTotalAssetsIsTotalAssetsPlusLockedLessIntrinsicAtSpot() public {
        (uint256 aliceShares, uint256 navFlat) = _seed();
        assertEq(earn.indicativeTotalAssets(), navFlat, "flat: the mark is the NAV");
        assertEq(earn.indicativeAssetsPerShare(), Math.mulDiv(navFlat, 1e18, earn.totalSupply()), "flat: per share");
        assertGt(aliceShares, 0, "precondition: alice holds shares");

        _writeAndFill();
        uint256 navDuring = earn.totalAssets();
        uint256 perUnit = ch.collateralPerUnit(putId);
        uint256 locked = uint256(WRITE_UNITS) * perUnit;
        assertEq(perUnit, OptionMath.collateralPerUnit(true, PUT_STRIKE), "precondition: the put locks strike/100");

        // Spot 240 against strike 210: out of the money, intrinsic 0, the whole collateral is added back.
        assertEq(OptionMath.grossPayoutPerUnit(true, PUT_STRIKE, 240_000_000), 0, "precondition: OTM");
        assertEq(earn.indicativeTotalAssets(), navDuring + locked, "OTM: totalAssets + locked");

        // Spot 200: in the money by 10 USDG per share, 0.10 USDG per unit -- a known intrinsic.
        _setSpot(address(nvda), 200_000_000);
        uint256 intrinsicPerUnit = OptionMath.grossPayoutPerUnit(true, PUT_STRIKE, 200_000_000);
        assertEq(intrinsicPerUnit, 100_000, "precondition: (210 - 200) / 100 per unit");
        uint256 intrinsic = uint256(WRITE_UNITS) * intrinsicPerUnit;
        assertEq(earn.indicativeTotalAssets(), navDuring + locked - intrinsic, "ITM: totalAssets + locked - intrinsic");
        assertEq(
            earn.indicativeAssetsPerShare(),
            Math.mulDiv(navDuring + locked - intrinsic, 1e18, earn.totalSupply()),
            "ITM: per share"
        );
        assertEq(earn.totalAssets(), navDuring, "the mark never moves totalAssets");

        // No usable spot (the oracle answers ok == false): conservative -- the collateral is treated as fully
        // intrinsic and nothing is added back. A zero price with ok == true takes the same branch.
        oracle.setSpot(address(nvda), false, 240_000_000, START);
        assertEq(earn.indicativeTotalAssets(), navDuring, "no spot: the mark falls back to totalAssets");
        _setSpot(address(nvda), 0);
        assertEq(earn.indicativeTotalAssets(), navDuring, "zero spot: the mark falls back to totalAssets");

        // Flat again: the mark is the NAV.
        _setSpot(address(nvda), 240_000_000);
        _settleAndRedeemTheShort();
        assertEq(earn.indicativeTotalAssets(), earn.totalAssets(), "flat again: the mark is the NAV");
    }

    /// @dev (iii), THE MUTATION THIS FILE'S OLDER TESTS CATCH, described rather than run: route {deposit}'s share
    ///      price through {indicativeTotalAssets} (replace `totalAssets()` with `indicativeTotalAssets()` in the
    ///      mint arithmetic, or drop the position boundary so bob is minted while short at that figure) and
    ///      {test_sec19_aDepositArrivingWhileShortIsMintedOnlyAtTheRecoveredNav} goes red by name: bob's shares no
    ///      longer equal the recovered-NAV price to the base unit. That test is the guard T-OP-026 built; this row
    ///      adds the view it protects against.
    function test_t065_theMutationIsNamed() public pure {
        // Documentation-only; the named test above is the one that goes red.
    }
}
