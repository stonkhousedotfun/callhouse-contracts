// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2IntegrationBase} from "../integration/V2IntegrationBase.t.sol";
import {V2Handler} from "./V2Handler.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockOraclePriceSource} from "../../../src/v2/mocks/MockOraclePriceSource.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";

/// @notice An oracle that went down right after its series were created: {pin} (which createSeries needs) is a no-op,
///         {SETTLEMENT_WINDOW} mirrors the real oracle so the Clearinghouse accepts its shape, and every price call
///         reverts. The handler points NEW series at it to show that a series whose oracle never answers still closes,
///         and that nothing else depends on it.
contract RevertingOracle {
    error OracleDown();

    uint32 public constant SETTLEMENT_WINDOW = V2Constants.SETTLEMENT_WINDOW;

    function pin(address, uint40) external pure {}

    fallback() external {
        revert OracleDown();
    }
}

/// @notice Stateful invariants of the v2 core (task C2-08): architecture §3.5 invariants 1-5 of the Clearinghouse and
///         the §3.6 invariants of the OrderBook, asserted after every call of {V2Handler} on the real contracts.
/// @dev CONFIG. runs = 256, depth = 64, set inline here so nothing else changes: the v1 Vault suite keeps its own inline
///      64 runs x depth 600 (test/invariant/VaultInvariant.t.sol) and foundry.toml has no invariant section. Every
///      invariant_* function is its own campaign; each asserts one invariant after every call of its campaign.
///      fail-on-revert is on: the handler never reverts, it predicts and counts the protocol's reverts instead.
///
///      THE INVARIANTS, as stated in architecture §3.5 / §3.6 and C2-05 / C2-06:
///        1. Unsettled series: long supply == short supply, locked == long supply x collateral per unit; and the
///           Clearinghouse's openInterest of an expiry is the sum of its series' long supply.
///        2. Per asset: sum of free + sum of locked + accrued fees == the Clearinghouse's token balance (the spec asks
///           <=; equality holds), and that balance == ghost deposits - ghost withdrawals, payouts and sweeps. `locked`
///           is derived in the contract (C2-05), so the independent side of this identity is the token balance and the
///           ghost flows measured at the receivers.
///        3. Settled series: long + fee + short == collateral per unit; what redemptions paid (payouts + fees) never
///           exceeds what the series held at settlement, and locked == held at settlement - paid; every redemption paid
///           exactly balance x per-unit amount.
///        4. close, redeem, withdraw and cancel (and prune, settle, snapshot, finalize, transfers, sweeps, claims)
///           never revert where they are allowed, under every pause flag, with the feed or the pool reverting, the
///           issuer's oracle paused, the sources removed or a reverting oracle pinned; and every gate (pauses, cutoff,
///           expiry, opt-out) does revert where it must.
///        5. No call moves another account's wallet, ledger or tokens, except a take spending exactly the collateral of
///           that account's filled write-on-fill asks (the book is its operator) and a redemption, which only pays it.
///        B1. The book's USDG == open bid escrow + sum of owed, EXACTLY (fees leave the book on every take).
///        B2. The book's long tokens per id == open resale escrow EXACTLY; it never holds a short.
///        B3. Per take: rebates <= taker fee, the fills add up to the take, and the book pays out exactly what it
///            pulls in (plus the bid escrow a sale consumes): a fill never pays out more than it takes in.
///        6. (owner decision 2026-09-17) An expiry settles on the configuration pinned by its first series, whatever
///           the admin changed since: the oracle reports it pinned with exactly the source list, deviation and delay
///           the handler had set then, its captured sources and deviation are those, and an expiry pinned while market,
///           feed and pool were all honest never settles near the 400 USDG every evil configuration prices at. Pinning
///           fails closed under the admin's attacks (oracle revoked on a source, pre-pins through the Clearinghouse
///           pointer or a source allow-list): every series on the real oracle has its expiry pinned on the oracle AND
///           on every real source of the pinned list, the pins are exactly the model's (so a pre-pin never changed
///           what a created series settles on), and an expiry is pinned only when the model pinned it.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract V2InvariantTest is V2IntegrationBase {
    V2Handler internal handler;
    address[4] internal traders;

    /// @dev The world starts 3 hours before the first daily expiry (Thursday 2026-09-10 16:00 New York), so a 64-call run
    ///      reaches expiry, snapshot, finalization, settlement and redemption, and later runs still see the next ones.
    uint256 internal constant WORLD_START = THU_2026_09_10 - 3 hours;

    /// @dev NVDA's collateral-rent rate for the campaign (INTERFACE_VERSION 7), the design's §5.1 launch value:
    ///      80 millionths of the locked collateral per MINT_FEE_PERIOD of remaining life.
    uint32 internal constant MINT_FEE_PPM = 80;

    /// @dev What {V2Handler.reconfigure} points the configuration at: a feed with two rounds of history and a pool, both
    ///      at 400 USDG, and a scripted source answering 400 USDG for every window.
    MockRoundFeed internal evilFeed;
    MockUniV3Pool internal evilPool;
    MockOraclePriceSource internal evilSource;

    /// @dev Honest NVDA settles inside 200-240 USDG (the handler's grid; a resolve at the middle of its band stays inside:
    ///      the 150 bps band, or 1.025 x a lone vetoed price from expiry + 7 days).
    uint256 internal constant HONEST_LO = 190_000_000;
    uint256 internal constant HONEST_HI = 250_000_000;

    function setUp() public override {
        super.setUp();
        evilFeed = new MockRoundFeed(8, "RHNVDA / USD");
        evilFeed.push(400_00000000, WORLD_START - 2 hours);
        evilFeed.push(400_00000000, WORLD_START - 1 hours);
        evilPool = new MockUniV3Pool(address(usdg), address(nvda), 500);
        // casting to 'uint40' is safe because WORLD_START is a 2026 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        evilPool.pushState(uint40(WORLD_START - 2 hours), 216407, POOL_LIQUIDITY);
        evilSource = new MockOraclePriceSource();
        evilSource.setWindow(true, 400_000_000);
        vm.warp(WORLD_START);
        _registerNvda();
        // INTERFACE_VERSION 7: the campaign runs WITH collateral rent on, so invariants 2' and 7 have something to
        // hold. The rate is the design's §5.1 launch value for NVDA; the base fixture stays at 0 (design §3.8) so the
        // lifecycle, gas and docs suites keep their numbers.
        V2Types.MarketConfig memory cfg = _nvdaMarket();
        cfg.mintFeePpm = MINT_FEE_PPM;
        vm.prank(admin);
        _reconfigure(ch, address(nvda), cfg);
        traders = [alice, bob, carol, mm];
        for (uint256 i; i < 4; ++i) {
            _onboard(traders[i]);
        }
        handler = new V2Handler(
            V2Handler.Deps({
                ch: ch,
                book: book,
                oracle: oracle,
                calendar: calendar,
                rewards: rewards,
                feed: feed,
                pool: pool,
                usdg: usdg,
                nvda: nvda,
                clSource: address(clSource),
                poolSource: address(poolSource),
                badOracle: address(new RevertingOracle()),
                evilFeed: evilFeed,
                evilPool: evilPool,
                evilSource: evilSource,
                admin: admin,
                guardian: guardian,
                keeper: keeper,
                treasury: treasury,
                chFees: chFees,
                actors: traders,
                start: WORLD_START
            })
        );
        vm.label(address(handler), "V2Handler");

        // Every trader starts with collateral on the ledger, and a first ladder exists on the first three expiries.
        for (uint8 i; i < 4; ++i) {
            handler.deposit(i, true, 50_000e6, 0);
            handler.deposit(i, false, 50e18, 0);
        }
        handler.createSeries(0, 2, false, 0); // Thu 09-10 call 220
        handler.createSeries(0, 2, true, 0); // Thu 09-10 put 220
        handler.createSeries(1, 3, false, 0); // Fri 09-11 call 230
        handler.createSeries(2, 1, true, 0); // Mon 09-14 put 210
        // Resting orders so takes have something to hit from the first call (odd series seeds pick series[seed >> 1]).
        handler.place(0, 1, 2, 199, 200, 0, 0); // alice AskWrite, Thu call 220 at 2.00
        handler.place(0, 3, 2, 299, 200, 0, 0); // alice AskWrite, Thu put 220 at 3.00
        handler.place(2, 5, 2, 99, 200, 0, 0); // carol AskWrite, Fri call 230 at 1.00
        handler.place(1, 1, 0, 149, 100, 0, 0); // bob Bid, Thu call 220 at 1.50
        handler.place(3, 7, 0, 49, 100, 0, 0); // mm Bid, Mon put 210 at 0.50
        // mm writes 50 Fri calls 230 and ALICE buys them: `to = 3` is odd, so the buyer is actor (3 + 1) % 4 = alice
        // (the v7 comment said "to itself"; the book cannot mint a pair to its own writer). Pinned by
        // {test_fixture_everyMintGoesThroughTheBookAndBothGatesAreLive}: alice holds the 50 longs, mm the 50 shorts.
        handler.mint(3, 5, 50, 3, 0);
        // T-OP-016: this line is a NO-OP and always was. It asks mm to rest an AskResale of the 50 longs, but mm holds
        // none -- alice does -- so {V2Handler.place} returns at its `have == 0` check before any call is made. No resting
        // AskResale exists when a campaign starts; resale fills come only from asks the campaign itself places (the walk
        // still reaches them: 14 fills at c851f8f3). Left as it was rather than re-seeded as `place(0, ...)`, because
        // changing the starting world changes every campaign's trajectory and that is a decision for a full run, not
        // for a row about the mint gate.
        handler.place(3, 5, 1, 119, 50, 0, 0);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](29);
        selectors[0] = V2Handler.deposit.selector;
        selectors[1] = V2Handler.withdraw.selector;
        selectors[2] = V2Handler.createSeries.selector;
        selectors[3] = V2Handler.mint.selector;
        selectors[4] = V2Handler.close.selector;
        selectors[5] = V2Handler.transfer.selector;
        selectors[6] = V2Handler.place.selector;
        selectors[7] = V2Handler.cancel.selector;
        selectors[8] = V2Handler.replace.selector;
        selectors[9] = V2Handler.takeBuy.selector;
        selectors[10] = V2Handler.takeSell.selector;
        selectors[11] = V2Handler.claimOwed.selector;
        selectors[12] = V2Handler.prune.selector;
        selectors[13] = V2Handler.snapshot.selector;
        selectors[14] = V2Handler.finalize.selector;
        selectors[15] = V2Handler.settle.selector;
        selectors[16] = V2Handler.redeem.selector;
        selectors[17] = V2Handler.redeemBatch.selector;
        selectors[18] = V2Handler.sweepFees.selector;
        selectors[19] = V2Handler.pushPrice.selector;
        selectors[20] = V2Handler.warp.selector;
        selectors[21] = V2Handler.togglePause.selector;
        selectors[22] = V2Handler.toggleOracleFault.selector;
        selectors[23] = V2Handler.toggleUsdg.selector;
        selectors[24] = V2Handler.setPrefs.selector;
        selectors[25] = V2Handler.governSettlement.selector;
        selectors[26] = V2Handler.attack.selector;
        selectors[27] = V2Handler.reconfigure.selector;
        selectors[28] = V2Handler.pinningAttack.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                         CLEARINGHOUSE (§3.5)
    //////////////////////////////////////////////////////////////*/

    function invariant_1_unsettledSeriesAreFullyBacked() public view {
        _assertBacked();
    }

    function invariant_2_clearinghouseHoldsEveryClaim() public view {
        _assertSolvent();
    }

    function invariant_3_settledSeriesPayNoMoreThanTheyHeld() public view {
        _assertSettledConserve();
    }

    function invariant_4_exitsNeverBlockedAndGatesHold() public view {
        _assertPredictions();
    }

    function invariant_5_onlyTheOwnerMovesItsFunds() public view {
        assertEq(handler.inv5Violations(), 0, handler.lastInv5());
    }

    function invariant_6_expiriesSettleOnTheirPinnedConfiguration() public view {
        _assertPinned();
        _assertSeriesPinned();
    }

    function invariant_7_heldRentAlwaysCoversEveryRefundItOwes() public view {
        _assertRentCovered();
    }

    /*//////////////////////////////////////////////////////////////
                            ORDER BOOK (§3.6)
    //////////////////////////////////////////////////////////////*/

    function invariant_book_usdgIsBidEscrowPlusOwed() public view {
        _assertBookUsdg();
    }

    function invariant_book_longsAreResaleEscrow() public view {
        _assertBookLongs();
    }

    function invariant_book_takesConserveAndRebatesStayUnderTheFee() public view {
        assertEq(handler.takeViolations(), 0, handler.lastTake());
    }

    /*//////////////////////////////////////////////////////////////
                   INTERFACE_VERSION 8 (V8-DESIGN §12)
    //////////////////////////////////////////////////////////////*/

    /// @dev V8-DESIGN §12: no path moves LOCKED collateral except settle, redeem and close. The campaign's own
    ///      backing and solvency assertions are what prove it -- locked collateral that leaked would show up as a
    ///      series no longer fully backed -- so this names the design clause and delegates rather than inventing a
    ///      second, weaker measurement of the same thing.
    function invariant_v8_lockedCollateralMovesOnlyOnSettleRedeemOrClose() public view {
        _assertBacked();
        _assertSolvent();
    }

    /// @dev V8-DESIGN §12: protocol-owned funds exit only to `treasury`. In v8 the fee lanes do not pay an EOA at
    ///      all -- both the Clearinghouse and the book pay the FeeSplitter -- so the check is that no EOA fee
    ///      recipient of the v7 shape has been paid anything across the whole campaign. `chFees` is kept in the
    ///      fixture for exactly this assertion.
    function invariant_v8_noEoaIsAFeeRecipient() public view {
        assertEq(usdg.balanceOf(chFees), 0, "an EOA was paid a USDG fee");
        assertEq(nvda.balanceOf(chFees), 0, "an EOA was paid an NVDA fee");
        assertEq(ch.free(chFees, address(usdg)), 0, "an EOA holds a USDG fee credit");
        assertEq(ch.free(chFees, address(nvda)), 0, "an EOA holds an NVDA fee credit");
    }

    /// @dev V8-DESIGN §12: `mint` reverts for any caller outside the minter allowlist. The handler's {attack}
    ///      probe calls `ch.mint` directly as a non-minter on every campaign it runs, and invariant 5 requires every
    ///      one of those attempts to have reverted without moving the victim's balances.
    function invariant_v8_mintRevertsOutsideTheMinterAllowlist() public view {
        assertEq(handler.inv5Violations(), 0, handler.lastInv5());
        assertFalse(ch.isMinter(address(handler)), "the handler must never be a minter");
    }

    /// @dev V8-DESIGN §12: with no discount module and no payout adapter, behaviour is byte-identical to the base
    ///      path. The fixture starts with both seams empty. The handler may attach its own 10% {MockFeeDiscount}
    ///      (so the book-fee invariant can see a discounted take); any OTHER module, or any payout adapter, is a
    ///      violation -- that is the pin that the campaign has not quietly grown a second path.
    function invariant_v8_noDiscountModuleAndNoAdapterIsTheBasePath() public view {
        address dm = book.discountModule();
        assertTrue(dm == address(0) || dm == address(handler.discount()), "unknown fee-discount module");
        assertEq(ch.payoutAdapter(), address(0), "a payout adapter is configured");
    }

    /*//////////////////////////////////////////////////////////////
                         THE SUITE IS NOT VACUOUS
    //////////////////////////////////////////////////////////////*/

    /// T-OP-016. THE ONE ROUTE EVERY MINT IN THIS CAMPAIGN TAKES, AND THE TWO FIXTURE FACTS IT LIVES ON. The handler
    /// never calls `ch.mint` itself (its {V2Handler.attack} probe does, as a non-minter, to be refused): an actor rests
    /// an AskWrite, another takes it, and the BOOK calls `Clearinghouse.mint` -- which is gated twice, `isMinter[msg.sender]`
    /// at `Clearinghouse.sol:641` and `msg.sender == writer || isOperator[writer][msg.sender]` at `:642`. So the whole
    /// campaign mints only because `V2IntegrationBase.t.sol:172` put the book on the allowlist and `_onboard` had every
    /// actor name the book its operator, and neither fact is stated anywhere in this file.
    ///
    /// WHY THAT NEEDS A TEST OF ITS OWN, MEASURED RATHER THAN ARGUED: drop either grant and NOTHING IN THE CAMPAIGN
    /// REVERTS. The book delivers a mint inside `try`/`catch` (`OrderBook.sol:1171`), so a `NotMinter()` or
    /// `NotAuthorized()` from the Clearinghouse is swallowed, the fill is undone, and `take` returns normally having
    /// filled nothing; the handler's `_expect("mint", true, ok, ret)` sees `ok` and records no surprise. With
    /// `setMinter(book)` flipped to false at c851f8f3, ALL FOURTEEN invariant campaigns passed at 256 runs, 16384
    /// calls, `reverts: 0` -- backing, solvency, rent, settlement, the v8 mint-allowlist invariant included -- over a
    /// world that never minted once. The only thing that went red was {test_handler_walkReachesEveryStage}, and it went
    /// red at "fills: 0", four stages away from the gate that had moved. So a NotMinter in this suite is not a red to
    /// repair; it is structurally invisible, and the campaign's answer to it is fourteen greens. This pins both gates,
    /// in the order the contract checks them, so that rewiring reds HERE with the error's name and the fixture line,
    /// and pins that the setUp mint was a real mint and not a silent no-op.
    ///
    /// The row that produced this was cut on a phantom: a tree-wide log parse charged forge's closing recap to this suite
    /// and reported 35 `NotMinter()` reds in a file that has 16 tests. At c851f8f3 all 16 pass with `reverts: 0` on every
    /// campaign. There was never a NotMinter red here to repair; this is the guard that keeps it that way.
    function test_fixture_everyMintGoesThroughTheBookAndBothGatesAreLive() public {
        // Gate 1, `:641`: the book is a minter; no actor is, and the handler never is.
        assertTrue(ch.isMinter(address(book)), "the book must be a minter or the campaign cannot mint");
        assertFalse(ch.isMinter(address(handler)), "the handler must never be a minter");
        for (uint256 i; i < 4; ++i) {
            assertFalse(ch.isMinter(traders[i]), "no actor is a minter");
            // Gate 2, `:642`: every actor named the book its operator, in `_onboard`.
            assertTrue(ch.isOperator(traders[i], address(book)), "every actor must have named the book its operator");
        }

        // Both gates probed directly, in the order the contract checks them. An actor is refused at the FIRST gate before
        // the second is consulted. This test contract IS a minter (`V2IntegrationBase.t.sol:171`) and is refused at the
        // SECOND, because no actor ever named it. Swap the two expectations and both probes go red.
        uint256 longId = handler.seriesAt(2); // Fri 09-11 call 230, the series the setUp mint used
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotMinter.selector);
        ch.mint(longId, 1, alice, alice);
        assertFalse(ch.isOperator(alice, address(this)), "the second probe needs a minter alice has NOT authorised");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.mint(longId, 1, alice, alice);

        // And the route is live: the setUp's `handler.mint(3, 5, 50, 3, 0)` was a REAL book mint. mm (actor 3) wrote,
        // alice (actor (3 + 1) % 4) bought, and the book minted the pair out of mm's free collateral. A fixture that
        // silently stopped minting would leave `nMints` at 0 and both balances at 0 without a single revert.
        assertEq(handler.nMints(), 1, "the setUp mint did not mint");
        assertEq(handler.unexpectedReverts(), 0, handler.lastSurprise());
        assertEq(ch.balanceOf(alice, longId), 50, "the buyer holds the 50 longs the setUp minted");
        assertEq(ch.balanceOf(mm, V2Ids.shortIdOf(longId)), 50, "the writer holds the 50 shorts");
        assertEq(ch.balanceOf(mm, longId), 0, "the writer holds no longs, so the setUp's resale line rests nothing");
    }

    /// A fixed pseudo-random walk through the same selectors: 16 episodes of 64 calls, each from the setUp state like
    /// one fuzz run, with every invariant checked every 16 calls. It must reach every stage the invariants are
    /// about: fills, mints, closes, cancels, prunes, corroborated and uncorroborated finalizations, settlements, paid
    /// redemptions, and finalizations of an expiry pinned honest while the admin had the configuration changed. The
    /// fuzzed campaigns draw from the same handler, so this is a floor under what they reach.
    function test_handler_walkReachesEveryStage() public {
        uint256[10] memory reached;
        uint256 start = vm.snapshotState();
        for (uint256 episode; episode < 16; ++episode) {
            uint256 seed = uint256(keccak256(abi.encode("C2-08", episode)));
            for (uint256 i; i < 64; ++i) {
                seed = uint256(keccak256(abi.encode(seed, i)));
                _dispatch(seed);
                if (i % 16 == 15) _assertAll();
            }
            reached[0] += handler.nFills();
            reached[1] += handler.nMints();
            reached[2] += handler.nCloses();
            reached[3] += handler.nCancels();
            reached[4] += handler.nPrunes();
            reached[5] += handler.nCorroborated();
            reached[6] += handler.nUncorroborated();
            reached[7] += handler.nSettles();
            reached[8] += handler.nRedeemsPaid();
            reached[9] += handler.nPinnedFinalsUnderChange();
            vm.revertToState(start);
        }
        string[10] memory stage = [
            "fills",
            "mints",
            "closes",
            "cancels",
            "prunes",
            "corroborated finalizations",
            "uncorroborated finalizations",
            "settlements",
            "paid redemptions",
            "finalizations on a pinned configuration the admin had changed"
        ];
        for (uint256 k; k < 10; ++k) {
            emit log_named_uint(stage[k], reached[k]);
            assertGt(reached[k], 0, stage[k]);
        }
    }

    /// The admin's pinning attacks through the handler in a fixed order (the fuzzed campaigns draw them from
    /// {V2Handler.pinningAttack}; the walk above does not), with every invariant checked after each step, predictions
    /// included: with the oracle off the Chainlink or the pool source's allow-list the first series of a new expiry is
    /// refused; pre-pins through the Clearinghouse pointer (evil market), the Chainlink allow-list (evil feed) and the
    /// pool allow-list (evil pool) followed by the honest configuration refuse the series of those expiries; the same
    /// pre-pins under the honest configuration are confirmed by the first series.
    function test_handler_pinningAttacksArePredictedAndBlocked() public {
        // pinningAttack(4 x (5 x expiry index + kind)): kind 0 Chainlink allow-list, 1 pool allow-list, 2 pointer,
        // 3 Chainlink pre-pin, 4 pool pre-pin. reconfigure(0 | 4 | 8): market, feed, pool evil <-> honest.
        handler.pinningAttack(0);
        handler.createSeries(5, 0, false, 0);
        _assertAll();
        handler.pinningAttack(0);
        handler.pinningAttack(4);
        handler.createSeries(5, 0, false, 0);
        _assertAll();
        handler.pinningAttack(4);
        assertEq(handler.nPinRefusals(), 2, "refused while a listed source did not accept the oracle");

        uint8[3] memory toggles = [0, 4, 8];
        uint8[3] memory prePins = [4 * (5 * 5 + 2), 4 * (5 * 6 + 3), 4 * (5 * 7 + 4)];
        for (uint8 i; i < 3; ++i) {
            handler.reconfigure(toggles[i]);
            handler.pinningAttack(prePins[i]);
            handler.reconfigure(toggles[i]);
            handler.createSeries(5 + i, 0, false, 0);
            _assertAll();
        }
        assertEq(handler.nPinRefusals(), 5, "and on each expiry pre-pinned with a configuration no longer current");
        assertEq(handler.seriesCount(), 4, "no series created on a hidden pin");

        uint8[3] memory honest = [4 * (5 * 8 + 2), 4 * (5 * 9 + 3), 4 * (5 * 10 + 4)];
        for (uint8 i; i < 3; ++i) {
            handler.pinningAttack(honest[i]);
            handler.createSeries(8 + i, 0, false, 0);
            _assertAll();
        }
        assertEq(handler.nPrePins(), 6, "six pre-pins");
        assertEq(handler.nPinRefusals(), 5, "honest pre-pins are confirmed");
        assertEq(handler.seriesCount(), 7, "three series on confirmed pre-pins");
        assertEq(oracle.pinnedBy(address(nvda), handler.expiryAt(8)), address(ch), "the confirmation moved pinnedBy");
    }

    function _dispatch(uint256 seed) internal {
        uint256 w = seed % 28;
        // Truncation is the point: each argument takes its own bits of the seed.
        // forge-lint: disable-start(unsafe-typecast)
        uint8 a = uint8(seed >> 8);
        uint8 b = uint8(seed >> 16);
        uint8 c = uint8(seed >> 24);
        uint16 dt = uint16(seed >> 32);
        uint64 u = uint64(seed >> 48);
        uint32 p = uint32(seed >> 112);
        uint256 big = seed >> 144;
        bool f = (seed >> 7) & 1 == 1;
        if (w == 0) handler.deposit(a, f, big, dt);
        else if (w == 1) handler.withdraw(a, f, big, dt);
        else if (w == 2) handler.createSeries(a, b, f, dt);
        else if (w == 3) handler.mint(a, b, u, c, dt);
        else if (w == 4) handler.close(a, b, u, dt);
        else if (w == 5) handler.transfer(a, b, c, f, u, dt);
        else if (w == 6) handler.place(a, b, c, p, u, uint32(big), dt);
        // forge-lint: disable-end(unsafe-typecast)
        else if (w == 7) handler.cancel(big, dt);
        else if (w == 8) handler.replace(big, p, u, dt);
        else if (w == 9) handler.takeBuy(a, uint256(seed >> 200), u, big, p, c, dt);
        else if (w == 10) handler.takeSell(a, uint256(seed >> 200), u, big, p, f, c, dt);
        else if (w == 11) handler.claimOwed(a, dt);
        else if (w == 12) handler.prune(big, dt);
        else if (w == 13) handler.snapshot(a, dt);
        else if (w == 14) handler.finalize(a, dt);
        else if (w == 15) handler.settle(a, dt);
        else if (w == 16) handler.redeem(a, f, b, c, dt);
        else if (w == 17) handler.redeemBatch(a, f, b, dt);
        else if (w == 18) handler.sweepFees(f, dt);
        else if (w == 19) handler.pushPrice(a, b, dt);
        else if (w == 20) handler.warp(a, b, p);
        else if (w == 21) handler.togglePause(a);
        else if (w == 22) handler.toggleOracleFault(a);
        else if (w == 23) handler.toggleUsdg(a, b);
        else if (w == 24) handler.setPrefs(a, b);
        else if (w == 25) handler.governSettlement(a, b, dt);
        else if (w == 26) handler.attack(a, b, c, big, dt);
        else handler.reconfigure(a);
    }

    /*//////////////////////////////////////////////////////////////
                               ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    function _assertAll() internal view {
        _assertBacked();
        _assertSolvent();
        _assertSettledConserve();
        _assertPredictions();
        assertEq(handler.inv5Violations(), 0, handler.lastInv5());
        _assertBookUsdg();
        _assertBookLongs();
        assertEq(handler.takeViolations(), 0, handler.lastTake());
        _assertPinned();
        _assertSeriesPinned();
    }

    /// @dev Invariant 6 over every listed expiry and every series (see the contract NatSpec).
    function _assertPinned() internal view {
        uint256 m = handler.expiryCount();
        for (uint256 e; e < m; ++e) {
            uint40 expiry = handler.expiryAt(e);
            (bool pinned, address[] memory sources, uint16 dev, uint32 delay,) =
                oracle.settlementConfig(address(nvda), expiry);
            assertEq(pinned, handler.ghostOraclePinned(expiry), "6: pinned exactly when the model pinned it");
            assertEq(oracle.pinnedBy(address(nvda), expiry), handler.ghostPinnedBy(expiry), "6: pinnedBy");
            _assertSourcePins(expiry);
            if (!handler.ghostPinned(expiry)) continue;
            assertTrue(pinned, "6: the first series pinned its expiry");
            assertEq(keccak256(abi.encode(sources)), handler.ghostPinnedSources(expiry), "6: pinned source list");
            assertEq(dev, handler.ghostPinnedDeviation(expiry), "6: pinned deviation");
            assertEq(delay, handler.ghostPinnedDelay(expiry), "6: pinned delay");

            (address[] memory recorded,,, uint16 recordedDev) = oracle.recordedSources(address(nvda), expiry);
            if (recorded.length != 0) {
                assertEq(keccak256(abi.encode(recorded)), handler.ghostPinnedSources(expiry), "6: captured = pinned");
                assertEq(recordedDev, handler.ghostPinnedDeviation(expiry), "6: captured deviation = pinned");
            }
            (V2Types.SettlementStatus status, uint256 price) = oracle.settlementPrice(address(nvda), expiry);
            if (status == V2Types.SettlementStatus.Finalized && handler.ghostPinnedHonest(expiry)) {
                assertGe(price, HONEST_LO, "6: an honest pin settles honest (low)");
                assertLe(price, HONEST_HI, "6: an honest pin settles honest (high)");
            }
        }
    }

    /// @dev Each real source's pin of `expiry` is exactly the model's, and every series on the real oracle has the oracle
    ///      and every real source of its expiry's pinned list pinned (the revoke-then-repoint attack leaves one unpinned).
    function _assertSourcePins(uint40 expiry) internal view {
        (address pinnedFeed,,, bool feedPinned) = clSource.pinnedFeeds(address(nvda), expiry);
        uint8 wantFeed = handler.ghostFeedPin(expiry);
        assertEq(feedPinned, wantFeed != 0, "6: Chainlink pinned exactly when the model says");
        if (feedPinned) {
            assertEq(pinnedFeed, wantFeed == 2 ? address(evilFeed) : address(feed), "6: the feed the model pinned");
        }
        (address pinnedPool,,,, bool poolPinned,) = poolSource.pinnedPools(address(nvda), expiry);
        uint8 wantPool = handler.ghostPoolPin(expiry);
        assertEq(poolPinned, wantPool != 0, "6: the pool source pinned exactly when the model says");
        if (poolPinned) {
            assertEq(pinnedPool, wantPool == 2 ? address(evilPool) : address(pool), "6: the pool the model pinned");
        }
    }

    function _assertSeriesPinned() internal view {
        uint256 n = handler.seriesCount();
        for (uint256 i; i < n; ++i) {
            V2Types.Series memory sr = ch.series(handler.seriesAt(i));
            if (sr.oracle != address(oracle)) continue;
            (bool pinned, address[] memory sources,,,) = oracle.settlementConfig(address(nvda), sr.expiry);
            assertTrue(pinned, "6: a series exists only on a pinned expiry");
            assertTrue(handler.ghostPinned(sr.expiry), "6: and the model saw a series creation pin or confirm it");
            for (uint256 k; k < sources.length; ++k) {
                if (sources[k] == address(clSource)) {
                    (,,, bool feedPinned) = clSource.pinnedFeeds(address(nvda), sr.expiry);
                    assertTrue(feedPinned, "6: a series exists only with its Chainlink source pinned");
                } else if (sources[k] == address(poolSource)) {
                    (,,,, bool poolPinned,) = poolSource.pinnedPools(address(nvda), sr.expiry);
                    assertTrue(poolPinned, "6: a series exists only with its pool source pinned");
                }
            }
        }
    }

    function _assertBacked() internal view {
        uint256 n = handler.seriesCount();
        for (uint256 i; i < n; ++i) {
            uint256 longId = handler.seriesAt(i);
            V2Types.Series memory s = ch.series(longId);
            if (s.settled) continue;
            uint256 supply = ch.totalSupply(longId);
            assertEq(supply, ch.totalSupply(V2Ids.shortIdOf(longId)), "1: long supply == short supply");
            assertEq(ch.locked(longId), supply * ch.collateralPerUnit(longId), "1: locked == supply x per unit");
        }
        uint256 m = handler.expiryCount();
        for (uint256 e; e < m; ++e) {
            uint40 expiry = handler.expiryAt(e);
            uint256 longs;
            for (uint256 i; i < n; ++i) {
                uint256 longId = handler.seriesAt(i);
                if (ch.series(longId).expiry == expiry) longs += ch.totalSupply(longId);
            }
            assertEq(ch.openInterest(address(nvda), expiry), longs, "1: open interest == long supply of the expiry");
        }
    }

    function _assertSolvent() internal view {
        address[2] memory assets = [address(usdg), address(nvda)];
        address[8] memory accounts = [alice, bob, carol, mm, address(book), keeper, treasury, chFees];
        uint256 n = handler.seriesCount();
        for (uint256 k; k < 2; ++k) {
            address asset = assets[k];
            uint256 claims = ch.accruedFees(asset);
            for (uint256 i; i < accounts.length; ++i) {
                claims += ch.free(accounts[i], asset);
            }
            for (uint256 i; i < n; ++i) {
                uint256 longId = handler.seriesAt(i);
                if (ch.collateralAsset(longId) != asset) continue;
                claims += ch.locked(longId);
                // I2' (INTERFACE_VERSION 7): collateral rent an UNSETTLED series still holds is a claim of its own --
                // refundable by close, accruable by settle -- and is in neither `free`, `locked` nor `accruedFees`.
                // settle moves it into accruedFees, so counting it for a settled series would double-count.
                V2Types.Series memory s = ch.series(longId);
                if (!s.settled) claims += s.mintFeesHeld;
            }
            uint256 held = asset == address(usdg) ? usdg.balanceOf(address(ch)) : nvda.balanceOf(address(ch));
            assertLe(claims, held, "2': free + locked + held rent + fees <= balance");
            assertEq(claims, held, "2': and exactly equal (nothing is stranded)");
            assertEq(held, handler.ghostIn(asset) - handler.ghostOut(asset), "2: balance == deposits - outflows");
        }
    }

    /// @dev Invariant 7 (INTERFACE_VERSION 7, v7 design §4.3.6): for every UNSETTLED series the rent it holds covers
    ///      closing its whole supply right now, so the clamp in {Clearinghouse.close} can never bind and a close can
    ///      never be blocked by the refund arithmetic; for every SETTLED series it is 0, because {settle} moved it to
    ///      `accruedFees`. This is the campaign's half of the matching proof: rent falls with time and the rate is
    ///      fixed per series, so a unit closed now was charged at least what it is being paid back.
    function _assertRentCovered() internal view {
        uint256 n = handler.seriesCount();
        for (uint256 i; i < n; ++i) {
            uint256 longId = handler.seriesAt(i);
            V2Types.Series memory s = ch.series(longId);
            if (s.settled) {
                assertEq(s.mintFeesHeld, 0, "7: a settled series holds no rent");
                continue;
            }
            uint256 supply = ch.totalSupply(longId);
            if (supply == 0 || supply > type(uint64).max) continue;
            assertGe(
                uint256(s.mintFeesHeld),
                ch.closeRefund(longId, uint64(supply)),
                "7: held rent covers closing the whole supply"
            );
        }
    }

    function _assertSettledConserve() internal view {
        assertEq(handler.payoutViolations(), 0, handler.lastPayout());
        uint256 n = handler.seriesCount();
        for (uint256 i; i < n; ++i) {
            uint256 longId = handler.seriesAt(i);
            V2Types.Series memory s = ch.series(longId);
            if (!s.settled) continue;
            assertEq(
                uint256(s.longPayoutPerUnit) + s.feePerUnit + s.shortPayoutPerUnit,
                ch.collateralPerUnit(longId),
                "3: long + fee + short == collateral per unit"
            );
            assertTrue(handler.settleSeen(longId), "3: settled through the handler");
            uint256 held = handler.lockedAtSettle(longId);
            uint256 paid = handler.paidOut(longId);
            assertLe(paid, held, "3: paid out <= locked at settlement");
            assertEq(ch.locked(longId), held - paid, "3: locked == held at settlement - paid");
        }
    }

    function _assertPredictions() internal view {
        assertEq(handler.unexpectedReverts(), 0, handler.lastSurprise());
        assertEq(handler.unexpectedSuccesses(), 0, handler.lastSurprise());
    }

    function _assertBookUsdg() internal view {
        uint256 last = book.lastOrderId();
        uint256 escrow;
        if (last != 0) {
            uint256[] memory ids = new uint256[](last);
            for (uint256 i; i < last; ++i) {
                ids[i] = i + 1;
            }
            V2Types.Order[] memory orders = book.getOrders(ids);
            for (uint256 i; i < last; ++i) {
                V2Types.Order memory o = orders[i];
                if (o.kind == BID && !o.cancelled) escrow += uint256(o.price) * (o.units - o.filled) / 100;
            }
        }
        // WHO CAN HOLD `owed`, DERIVED FROM THE CONTRACT RATHER THAN LISTED FROM MEMORY. Every credit goes through
        // `OrderBook._payOrOwe` (src/v2/OrderBook.sol:1211-1213), and its callers pass exactly four kinds of
        // address: a maker (:323, :363, :395), `ex.payees[i]` which is also a maker (:471), the take's
        // `p.recipient` (:468), and `feeRecipient` (:473). The first three are always one of `traders`. The
        // FOURTH IS THE BOOK'S OWN FEE RECIPIENT AND THIS SUM DID NOT INCLUDE IT.
        //
        // T-INV5 FOUND THIS THE HARD WAY. Once the handler walk got past the mint stage it reached fills whose
        // protocol fee could not be transferred, and B1 failed 4433400 != 4272565 -- the book holding 160_835 base
        // units that this assertion could not attribute. The handler's own `_owedTotal` (V2Handler.sol:1516-1521)
        // ALREADY summed `ch.feeRecipient()` alongside the actors, so two checks over the same quantity disagreed
        // about who could hold it, and the shorter one was here.
        //
        // AND THE STRUCTURAL POINT, because this will happen again: `owed` is a plain mapping and is NOT
        // ENUMERABLE, so this assertion can only ever compare against a HAND-LISTED set of addresses. Anything
        // credited to an address missing from that list is invisible to it. That is the same "a check that cannot
        // see its subject" shape this suite exists to catch, sitting inside the check. It fails loudly rather than
        // silently only because the balance side of the equality is total. Any new payee address added to
        // `_payOrOwe`'s callers must be added here and to `_owedTotal` in the same change.
        uint256 owed = book.owed(treasury) + book.owed(keeper);
        for (uint256 i; i < 4; ++i) {
            owed += book.owed(traders[i]);
        }
        address bookFees = book.feeRecipient();
        if (bookFees != treasury && bookFees != keeper) owed += book.owed(bookFees);
        address houseFees = ch.feeRecipient();
        if (houseFees != treasury && houseFees != keeper && houseFees != bookFees) owed += book.owed(houseFees);
        assertEq(usdg.balanceOf(address(book)), escrow + owed, "B1: book USDG == bid escrow + owed");
    }

    function _assertBookLongs() internal view {
        uint256 n = handler.seriesCount();
        for (uint256 k; k < n; ++k) {
            uint256 longId = handler.seriesAt(k);
            (uint256[] memory ids,) = book.ordersOfSeries(longId, 0, type(uint256).max);
            V2Types.Order[] memory orders = book.getOrders(ids);
            uint256 escrow;
            for (uint256 i; i < orders.length; ++i) {
                V2Types.Order memory o = orders[i];
                if (o.kind == RESALE && !o.cancelled) escrow += o.units - o.filled;
            }
            assertEq(ch.balanceOf(address(book), longId), escrow, "B2: book longs == resale escrow");
            assertEq(ch.balanceOf(address(book), V2Ids.shortIdOf(longId)), 0, "B2: book holds no shorts");
        }
        assertEq(nvda.balanceOf(address(book)), 0, "B2: book holds no Stock Tokens");
    }
}
