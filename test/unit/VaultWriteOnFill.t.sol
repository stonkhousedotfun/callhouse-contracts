// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";
import {ValoremLib} from "../../src/lib/ValoremLib.sol";
import {MockSeaport} from "../../src/mocks/MockSeaport.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {IERC1155Minimal} from "../../src/interfaces/IERC1155Minimal.sol";
import {
    ISeaport,
    IZone,
    Order,
    OrderComponents,
    OrderParameters,
    OrderType,
    SpentItem,
    ReceivedItem,
    ZoneParameters
} from "../../src/interfaces/ISeaport.sol";

/// @dev A buyer that is a contract and misbehaves inside its ERC-1155 receive hook, which Seaport
///      runs BETWEEN the vault's `authorizeOrder` and `validateOrder`. Every attempt is caught and
///      recorded so the fill itself completes and the test can read what was refused.
contract ReentrantBuyer {
    Vault internal immutable vault;
    IERC1155Minimal internal immutable clear;
    ISeaport internal immutable seaport;

    bool public tryHooks;
    bool public tryDonation;
    bool public tryDeposit;
    bool public tryRedeem;

    bytes public authorizeRevert;
    bytes public validateRevert;
    bytes public donationRevert;
    bytes public redeemRevert;
    bool public depositSucceeded;
    uint256 public hookCalls;

    constructor(Vault vault_, IERC1155Minimal clear_, ISeaport seaport_) {
        vault = vault_;
        clear = clear_;
        seaport = seaport_;
    }

    function arm(bool hooks, bool donation, bool deposit_, bool redeem_) external {
        tryHooks = hooks;
        tryDonation = donation;
        tryDeposit = deposit_;
        tryRedeem = redeem_;
    }

    function onERC1155Received(address, address, uint256 id, uint256 amount, bytes calldata) external returns (bytes4) {
        hookCalls++;
        if (tryHooks) {
            // Forge a zone-parameters struct and call the vault's hooks directly, as a stranger.
            ZoneParameters memory zp;
            zp.orderHash = vault.listingHash();
            zp.offerer = address(vault);
            zp.offer = new SpentItem[](1);
            zp.offer[0].amount = 1;
            zp.consideration = new ReceivedItem[](1);
            (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(IZone.authorizeOrder, (zp)));
            if (!ok) authorizeRevert = ret;
            (ok, ret) = address(vault).call(abi.encodeCall(IZone.validateOrder, (zp)));
            if (!ok) validateRevert = ret;
        }
        if (tryDonation) {
            // Push the tokens just received straight back into the vault mid-fill.
            (bool ok, bytes memory ret) = address(clear)
                .call(abi.encodeCall(IERC1155Minimal.safeTransferFrom, (address(this), address(vault), id, amount, "")));
            if (!ok) donationRevert = ret;
        }
        if (tryRedeem) {
            (bool ok, bytes memory ret) =
                address(vault).call(abi.encodeCall(Vault.redeem, (1, address(this), address(this))));
            if (!ok) redeemRevert = ret;
        }
        if (tryDeposit) {
            // A deposit mid-fill is a legitimate operation; it must neither revert nor break the fill.
            depositSucceeded = _depositOne();
        }
        return this.onERC1155Received.selector;
    }

    function _depositOne() internal returns (bool) {
        (bool ok,) = address(vault).call(abi.encodeCall(Vault.deposit, (1e18, address(this))));
        return ok;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function approveAll(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok);
    }
}

/// @notice WRITE ON FILL, on the mock Seaport with the verified 1.6 hook order. What the vault does
///         inside `authorizeOrder` and `validateOrder`, and every reason a fill is refused.
/// @dev The mock calls the hooks in the sequence the real runtime does (test/unit/Fixtures.t.sol proves
///      the parity): `authorizeOrder` before the status update and any transfer, `validateOrder` after
///      every transfer. The genuine fulfilment paths (basic, advanced, available, match, duplicates) run
///      against the real Seaport 1.6 bytecode in test/unit/VaultRealSeaport.t.sol.
///
///      THE FIXTURE: alice deposits 30e18 (capacity 28 at 95%), the keeper arms the 231 rung at a 220
///      spot and lists N at $1.90. Nothing is written until a fill.
contract VaultWriteOnFillTest is BaseTest {
    uint112 internal constant N = 10;
    address internal mallory = makeAddr("mallory");

    event CallsWritten(uint256 indexed optionId, uint256 indexed claimKey, uint112 contractsCount, uint256 collateral);

    function _listed() internal returns (uint256 optionId, OrderComponents memory c) {
        _deposit(alice, 30e18);
        optionId = _rollOpen();
        c = _approveListing(optionId, N, _okUnitPrice());
    }

    /// @dev Fill `k` as the buyer and require the whole fill to revert with exactly `err`. The mock
    ///      Seaport lets a hook revert bubble, as the real single-order paths do.
    function _fillRejects(OrderComponents memory c, uint256 k, bytes memory err) internal {
        vm.startPrank(buyer);
        usdg.approve(address(seaport), type(uint256).max);
        vm.expectRevert(err);
        mockSeaport.fulfil(c, k);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       THE WRITE HAPPENS IN THE FILL
    //////////////////////////////////////////////////////////////*/

    /// @dev The first fill opens the cycle's claim with exactly the filled amount, the collateral
    ///      moves at that instant and not before, and the buyer walks away with every token minted.
    function test_firstFill_opensTheClaimForExactlyTheFilledAmount() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        assertEq(vault.claimKey(), 0, "no claim before the first fill");
        assertEq(nvda.balanceOf(address(clear)), 0, "no collateral in the clearinghouse");

        vm.prank(buyer);
        usdg.approve(address(seaport), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CallsWritten(optionId, 0, 4, 4e18); // claimKey is checked below: the mock allocates it
        vm.prank(buyer);
        mockSeaport.fulfil(c, 4);

        uint256 key = vault.claimKey();
        assertTrue(key != 0 && key != optionId, "a claim was opened");
        assertEq(clear.balanceOf(address(vault), key), 1, "the vault owns the claim NFT");
        assertEq(vault.contractsWritten(), 4, "written == filled");
        assertEq(clear.balanceOf(buyer, optionId), 4, "the buyer holds every token minted");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "the vault holds none");
        assertEq(nvda.balanceOf(address(clear)), 4e18, "four lots of collateral, at the fill");
        assertEq(nvda.balanceOf(address(vault)), 26e18);
        assertEq(vault.lockedAssets(), 4e18);
        assertEq(vault.totalAssets(), 30e18, "the fill moved collateral, it did not lose it");
        assertEq(usdg.balanceOf(address(vault)), 4 * _okUnitPrice(), "and the premium landed");
        assertEq(clear.claim(key).amountWritten, 4e18, "Valorem agrees");
    }

    /// @dev Later fills top up the SAME claim: one claim per cycle, `contractsWritten` accumulates,
    ///      written == sold after every fill, and the vault's option balance is zero after each one.
    function test_laterFills_topUpTheSameClaim_writtenEqualsSoldAfterEveryFill() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        _fill(c, 3);
        uint256 key = vault.claimKey();

        uint256[3] memory fills = [uint256(2), 4, 1];
        uint256 sold = 3;
        for (uint256 i; i < fills.length; i++) {
            _fill(c, fills[i]);
            sold += fills[i];
            assertEq(vault.claimKey(), key, "the same claim, topped up");
            assertEq(vault.contractsWritten(), sold, "written == sold after every fill");
            assertEq(clear.balanceOf(buyer, optionId), sold, "the buyer holds everything sold");
            assertEq(clear.balanceOf(address(vault), optionId), 0, "vault option balance is zero outside a fill");
            assertEq(clear.claim(key).amountWritten, sold * 1e18, "Valorem sums the claim");
            assertEq(vault.lockedAssets(), sold * 1e18);
            assertEq(usdg.balanceOf(address(vault)), sold * _okUnitPrice());
        }
        assertEq(sold, N, "the order filled completely");
        assertEq(clear.balanceOf(address(vault), key), 1, "still one claim NFT");
    }

    /// @dev A top-up that came back with any other claim id would mean collateral the vault cannot
    ///      redeem. The library refuses it. Reached by handing the vault a claim id it does not own
    ///      as `claimKey` through a mock that returns a different id: since MockClear is faithful, the
    ///      refusal is pinned at the library level with a stub clearinghouse instead.
    function test_topUp_revertsIfTheClearinghouseReturnsAnotherClaim() public {
        WrongClaimClear stub = new WrongClaimClear();
        ValoremLib.Fill memory f = ValoremLib.Fill({
            feed: IChainlinkFeed(address(feed)),
            asset: nvda,
            optionId: 1 << 96,
            claimId: 7,
            strikeUsdg: 231_000_000,
            sizingAssets: 30e18,
            reserved: 0,
            grossUsdg: 1_900_000,
            written: 1,
            n: 1,
            cycleExerciseTs: exerciseTs,
            maxPriceAge: MAX_PRICE_AGE,
            feeAccepted: false
        });
        nvda.mint(address(this), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ValoremLib.WriteReturnedWrongClaim.selector, 7, 8));
        ValoremLib.writeOnFill(IValoremClear(address(stub)), f, Policy.launchDefaults());
    }

    /*//////////////////////////////////////////////////////////////
                              THE CLOCK
    //////////////////////////////////////////////////////////////*/

    /// @dev A fill one second before the exercise window is a covered call; a fill ON the tick could
    ///      be assigned in the block it was sold. The hook enforces the edge itself, whatever the
    ///      order's `endTime` says (Seaport's own `endTime` is exclusive and agrees).
    function test_fill_atExerciseTsMinusOneWrites_atExerciseTsIsRefused() public {
        (, OrderComponents memory c) = _listed();

        vm.warp(uint256(exerciseTs) - 1);
        feed.setAnswer(SPOT_FEED); // a live feed keeps ticking
        _fill(c, 2);
        assertEq(vault.contractsWritten(), 2, "one second before the window: sold and written");

        vm.warp(exerciseTs);
        feed.setAnswer(SPOT_FEED);
        _fillRejects(c, 1, abi.encodeWithSelector(Vault.WriteWindowClosed.selector, exerciseTs));
        assertEq(vault.contractsWritten(), 2, "nothing written on the tick");
    }

    /*//////////////////////////////////////////////////////////////
                      THE FLOORS, AT THE FILL'S OWN SPOT
    //////////////////////////////////////////////////////////////*/

    /// @dev A rally since the listing pulls the 231 strike inside the 3% band floor (at $225 the
    ///      floor is 231.75). The listing was fine on Monday; the fill is refused on Friday.
    function test_fill_refusesAStrikeInsideTheLiveBandFloorAfterARally() public {
        (, OrderComponents memory c) = _listed();
        feed.setAnswer(225_00000000);
        _fillRejects(
            c, 2, abi.encodeWithSelector(Policy.StrikeBelowBand.selector, uint256(231_000_000), uint256(231_750_000))
        );
        assertEq(vault.contractsWritten(), 0, "the stale-priced fill wrote nothing");

        // The rally fades: the same listing fills again.
        feed.setAnswer(SPOT_FEED);
        _fill(c, 2);
        assertEq(vault.contractsWritten(), 2);
    }

    /// @dev FLOOR ONLY (decision D9). A sell-off to $200 puts the 231 strike 15.5% out, above the
    ///      12% ceiling that only the ARM checks: the call is safer to sell, and the fill goes through.
    function test_fill_doesNotReCheckTheBandCeilingAfterASellOff() public {
        (, OrderComponents memory c) = _listed();
        feed.setAnswer(200_00000000);
        _fill(c, 3);
        assertEq(vault.contractsWritten(), 3, "a sell-off never blocks a sale");
    }

    /// @dev The premium floor is re-derived at the fill's spot. A listing priced exactly on the $220
    ///      floor (880_000 a contract) is under the floor at $221 (884_000) and refused; a listing
    ///      well above it still clears.
    function test_fill_refusesAPremiumUnderTheLiveFloor_rallyRejectsSellOffDoesNot() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        OrderComponents memory onTheFloor = _approveListing(optionId, N, 880_000);

        feed.setAnswer(221_00000000); // band floor 227.63 still admits 231; only the premium is stale
        _fillRejects(
            onTheFloor, 5, abi.encodeWithSelector(Vault.PremiumBelowFloorAtFill.selector, 5 * 880_000, 5 * 884_000)
        );
        assertEq(vault.contractsWritten(), 0);

        feed.setAnswer(210_00000000); // sell-off: the floor falls to 840_000, the listing clears it
        _fill(onTheFloor, 5);
        assertEq(vault.contractsWritten(), 5, "a sell-off does not reject");
    }

    /*//////////////////////////////////////////////////////////////
                    SIZE: CAP AND UTILISATION ON THE TOTAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Every fill is sized on `written + k` against `Policy.maxContracts(totalAssets())` AT THAT
    ///      MOMENT. A listing approved at the full capacity of 28 is refused at the margin once an
    ///      issuer burn has shrunk NAV: 20e18 admits 19, so 20 is refused and 19 fills.
    function test_fill_sizesOnTheTotalAtFillTime_utilisation() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        OrderComponents memory c = _approveListing(optionId, 28, _okUnitPrice());
        _fund(buyer, 0, 100_000_000);

        nvda.adminBurn(address(vault), 10e18); // NAV 20e18 -> 95% is 19 lots
        _fillRejects(c, 20, abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, 20, 19));
        _fill(c, 19);
        assertEq(vault.contractsWritten(), 19);
        // And the 20th is refused as a top-up too: the total binds, fill by fill.
        _fillRejects(c, 1, abi.encodeWithSelector(Policy.ContractsAboveUtilization.selector, 20, 19));
    }

    /// @dev The absolute cap binds the TOTAL of the cycle. Governance lowers the cap to 5 mid-week:
    ///      a fill of 6 is refused, 3 then 3 is refused on the second, 3 then 2 goes through.
    function test_fill_sizesOnTheTotalAtFillTime_cap() public {
        (, OrderComponents memory c) = _listed();
        PolicyParams memory p = Policy.launchDefaults();
        p.maxContractsCap = 5;
        vm.prank(admin);
        vault.setPolicy(p);

        _fillRejects(c, 6, abi.encodeWithSelector(Policy.ContractsAboveCap.selector, 6, 5));
        _fill(c, 3);
        _fillRejects(c, 3, abi.encodeWithSelector(Policy.ContractsAboveCap.selector, 6, 5));
        _fill(c, 2);
        assertEq(vault.contractsWritten(), 5, "exactly the cap, across two fills");
    }

    /// @dev `n == 0` cannot come from Seaport (it refuses zero-amount 1155 transfers), but the gate
    ///      refuses it on its own so `written + 0` can never sail through the size check.
    function test_fill_refusesZero() public {
        (, OrderComponents memory c) = _listed();
        _fillRejects(c, 0, abi.encodeWithSelector(Policy.ContractsZero.selector));
    }

    /*//////////////////////////////////////////////////////////////
                            VALOREM'S FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev The engine fee switched on mid-week, unaccepted: every fill refuses, the listing stands.
    function test_fill_refusesWhenTheEngineFeeIsOnAndNotAccepted() public {
        (, OrderComponents memory c) = _listed();
        mockClear.setFeesEnabled(true);
        _fillRejects(c, 2, abi.encodeWithSelector(Vault.ValoremFeeNotAccepted.selector, uint8(15)));
        assertEq(vault.contractsWritten(), 0);
        mockClear.setFeesEnabled(false);
        _fill(c, 2);
        assertEq(vault.contractsWritten(), 2, "off again: fills resume");
    }

    /// @dev Accepted, the fee RAISES THE FLOOR by fee x spot and is PULLED on top of the collateral,
    ///      and the approval is scrubbed afterwards. 15 bps of 1e18 is 0.0015 NVDA a contract, worth
    ///      $0.33 at $220, so the floor for one contract is 0.88 + 0.33 = 1.21 USDG: a $1.20 listing
    ///      is refused at the fill, a $1.90 one clears and pays 1.0015 NVDA per contract into Valorem.
    function test_fill_acceptedFeeRaisesTheFloorPullsTheFeeAndScrubsTheApproval() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        OrderComponents memory cheap = _approveListing(optionId, N, 1_200_000);

        mockClear.setFeesEnabled(true);
        vm.prank(admin);
        vault.acceptValoremFee(true);

        // floor = minPremium(220, 2) + fee(2 x 0.0015e18) x 220 / 1e18 = 1_760_000 + 660_000
        _fillRejects(cheap, 2, abi.encodeWithSelector(Vault.PremiumBelowFloorAtFill.selector, 2_400_000, 2_420_000));

        vm.prank(keeper);
        vault.cancelListing(cheap);
        OrderComponents memory fine = _approveListing(optionId, N, _okUnitPrice());
        _fill(fine, 2);

        assertEq(vault.contractsWritten(), 2);
        assertEq(nvda.balanceOf(address(clear)), 2e18 + 2 * 0.0015e18, "collateral plus 15 bps pulled");
        assertEq(nvda.balanceOf(address(vault)), 30e18 - 2e18 - 2 * 0.0015e18, "the fee left the vault");
        assertEq(nvda.allowance(address(vault), address(clear)), 0, "no standing approval to the clearinghouse");
        assertEq(mockClear.feeBalance(address(nvda)), 2 * 0.0015e18, "Valorem booked the fee");
        assertEq(vault.totalAssets(), 30e18 - 2 * 0.0015e18, "NAV bears exactly the fee");
    }

    /// @dev The second line of defence behind the 99.85% ceiling, `ReserveBreached` after the write, is
    ///      reached on this same fill path in test/regression/AF04_FeeSizing.t.sol
    ///      (`test_reserveBreachIsCaughtAfterTheWrite`): a fee rate the ceiling was not built for, a
    ///      reserve carved out for a settled redeemer, and the whole fill rolls back.

    /*//////////////////////////////////////////////////////////////
                              THE HALT
    //////////////////////////////////////////////////////////////*/

    /// @dev The guardian's brake stops SALES instantly: the hook refuses while halted, without any
    ///      Seaport call. Unhalted, the same listing fills again.
    function test_fill_isBlockedByHaltWrites() public {
        (, OrderComponents memory c) = _listed();
        vm.prank(guardian);
        vault.haltWrites();
        _fillRejects(c, 2, abi.encodeWithSelector(Vault.WritesAreHalted.selector));
        assertEq(vault.contractsWritten(), 0);
        assertTrue(vault.listingHash() != bytes32(0), "the listing itself is untouched");

        vm.prank(admin);
        vault.unhaltWrites();
        _fill(c, 2);
        assertEq(vault.contractsWritten(), 2);
    }

    /// @dev Outside Listed nothing fills, whatever Seaport thinks of the order: after `lockBook` the
    ///      listing is dead on Seaport too, but the hook is its own line of defence.
    function test_fill_refusesOutsideListed() public {
        (, OrderComponents memory c) = _listed();
        _warpToExercise();
        feed.setAnswer(SPOT_FEED);
        vault.lockBook();
        // The mock does not model the counter re-keying, so the hook's phase check is what refuses.
        _fillRejects(c, 1, abi.encodeWithSelector(Vault.NotLiveListing.selector, mockSeaport.getOrderHash(c)));
    }

    /*//////////////////////////////////////////////////////////////
                    THE HOOKS THEMSELVES, CALLED DIRECTLY
    //////////////////////////////////////////////////////////////*/

    /// @dev Nobody but Seaport may call either hook. A stranger calling `authorizeOrder` would make the
    ///      vault write collateral against nothing.
    function test_hooks_acceptOnlySeaport() public {
        (, OrderComponents memory c) = _listed();
        ZoneParameters memory zp = _zoneParams(c, 1);
        vm.prank(mallory);
        vm.expectRevert(Vault.NotSeaport.selector);
        vault.authorizeOrder(zp);
        vm.prank(mallory);
        vm.expectRevert(Vault.NotSeaport.selector);
        vault.validateOrder(zp);
        vm.prank(keeper);
        vm.expectRevert(Vault.NotSeaport.selector);
        vault.authorizeOrder(zp);
    }

    /// @dev THE POST-CONDITION HAS TEETH. Drive the hooks as Seaport would but WITHOUT the transfer in
    ///      between: `authorizeOrder` writes, the tokens sit in the vault, and `validateOrder` reverts
    ///      `InventoryLeftBehind`, which on the real runtime reverts the whole fill and with it the write.
    function test_validateOrder_catchesInventoryLeftBehind() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        ZoneParameters memory zp = _zoneParams(c, 3);

        vm.prank(address(seaport));
        bytes4 ok = vault.authorizeOrder(zp);
        assertEq(ok, IZone.authorizeOrder.selector);
        assertEq(clear.balanceOf(address(vault), optionId), 3, "minted, not yet moved");

        vm.prank(address(seaport));
        vm.expectRevert(abi.encodeWithSelector(Vault.InventoryLeftBehind.selector, 3, 0));
        vault.validateOrder(zp);
    }

    /// @dev A restricted order that names the vault as zone but is not the vault's live listing is
    ///      refused before any state moves: the hash commits to zone, type, items, salt and counter.
    function test_authorizeOrder_refusesAForeignOrderNamingTheVaultAsZone() public {
        (uint256 optionId, OrderComponents memory live) = _listed();

        // Mallory holds real option tokens and lists them with the VAULT as zone.
        _fund(mallory, 5e18, 0);
        vm.startPrank(mallory);
        nvda.approve(address(clear), type(uint256).max);
        clear.write(optionId, 5);
        clear.setApprovalForAll(address(seaport), true);
        vm.stopPrank();
        OrderComponents memory foreign = _buildOrder(optionId, 5, _okUnitPrice());
        foreign.offerer = mallory;
        foreign.consideration[0].recipient = payable(mallory);
        foreign.counter = seaport.getCounter(mallory);
        Order[] memory orders = new Order[](1);
        orders[0] = Order({parameters: _params(foreign), signature: ""});
        vm.prank(mallory);
        mockSeaport.validate(orders);

        bytes32 h = mockSeaport.getOrderHash(foreign);
        assertTrue(h != vault.listingHash(), "a different order");
        _fillRejects(foreign, 1, abi.encodeWithSelector(Vault.NotLiveListing.selector, h));
        assertEq(vault.contractsWritten(), 0, "the vault wrote nothing for a stranger's order");

        // A forged zone call with the live hash but the wrong offerer is refused the same way.
        ZoneParameters memory zp = _zoneParams(live, 1);
        zp.offerer = mallory;
        vm.prank(address(seaport));
        vm.expectRevert(abi.encodeWithSelector(Vault.NotLiveListing.selector, zp.orderHash));
        vault.authorizeOrder(zp);
    }

    /// @dev Neither hook ever calls Seaport: the vault never fulfils, validates, cancels or bumps a
    ///      counter from inside a fill. On the real runtime any such call would revert
    ///      `NoReentrantCalls`; here it is pinned as an absence.
    function test_hooks_neverCallSeaport() public {
        (, OrderComponents memory c) = _listed();
        vm.expectCall(address(seaport), abi.encodeWithSelector(ISeaport.validate.selector), 0);
        vm.expectCall(address(seaport), abi.encodeWithSelector(ISeaport.cancel.selector), 0);
        vm.expectCall(address(seaport), abi.encodeWithSelector(ISeaport.incrementCounter.selector), 0);
        _fill(c, 2);
        assertEq(vault.contractsWritten(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                        A HOSTILE BUYER, MID-FILL
    //////////////////////////////////////////////////////////////*/

    /// @dev The buyer's `onERC1155Received` runs between the two hooks. Everything it can try against
    ///      the vault from there is refused (the hooks: `NotSeaport`; a donation of the tokens it just
    ///      received: the receiver hook refuses; an instant redeem: `UseQueue`), a legitimate deposit
    ///      goes through, and the fill completes with the post-condition intact.
    function test_buyerReenteringTheVaultMidFillIsBlocked() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        ReentrantBuyer evil = new ReentrantBuyer(vault, IERC1155Minimal(address(clear)), seaport);
        _fund(address(evil), 1e18, 100_000_000);
        evil.approveAll(address(usdg), address(seaport));
        evil.approveAll(address(nvda), address(vault));
        evil.arm(true, true, true, true);

        vm.prank(address(evil));
        mockSeaport.fulfil(c, 3);

        assertEq(evil.hookCalls(), 1, "the receive hook ran once, mid-fill");
        assertEq(bytes4(evil.authorizeRevert()), Vault.NotSeaport.selector, "authorizeOrder refused the buyer");
        assertEq(bytes4(evil.validateRevert()), Vault.NotSeaport.selector, "validateOrder refused the buyer");
        assertEq(bytes4(evil.donationRevert()), MockClear.UnsafeRecipient.selector, "the donation was refused");
        assertEq(bytes4(evil.redeemRevert()), Vault.UseQueue.selector, "no instant redeem while a call is open");
        assertTrue(evil.depositSucceeded(), "a deposit mid-fill is legitimate and works");

        assertEq(vault.contractsWritten(), 3, "the fill completed");
        assertEq(clear.balanceOf(address(evil), optionId), 3, "the hostile buyer still got what it paid for");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "and left nothing in the vault");
        assertEq(vault.balanceOf(address(evil)), 1e18, "its deposit minted shares at par");
    }

    /*//////////////////////////////////////////////////////////////
                     THE RECEIVER HOOK: MINTS ONLY
    //////////////////////////////////////////////////////////////*/

    /// @dev Third-party donations of option tokens or of a claim NFT are refused: the receiver returns
    ///      the wrong selector, so the donor's own transfer reverts and nothing arrives. Only mints
    ///      (`from == address(0)`) from the clearinghouse are accepted, and those only ever come from
    ///      the vault's own `write` inside a fill.
    function test_receiverHook_refusesThirdPartyDonationsOfOptionsAndClaims() public {
        (uint256 optionId,) = _listed();
        _fund(mallory, 5e18, 0);
        vm.startPrank(mallory);
        nvda.approve(address(clear), type(uint256).max);
        uint256 malloryClaim = clear.write(optionId, 5);

        vm.expectRevert(MockClear.UnsafeRecipient.selector);
        clear.safeTransferFrom(mallory, address(vault), optionId, 2, "");

        vm.expectRevert(MockClear.UnsafeRecipient.selector);
        clear.safeTransferFrom(mallory, address(vault), malloryClaim, 1, "");
        vm.stopPrank();

        assertEq(clear.balanceOf(address(vault), optionId), 0, "no option tokens arrived");
        assertEq(clear.balanceOf(address(vault), malloryClaim), 0, "no claim arrived");
        assertEq(clear.balanceOf(mallory, optionId), 5, "mallory keeps her tokens");

        // The hooks answer the interface exactly: mint accepted, anything else refused.
        assertEq(
            vault.onERC1155Received(address(0), address(0), optionId, 1, ""),
            bytes4(0),
            "a caller other than the clearinghouse is refused"
        );
        vm.prank(address(clear));
        assertEq(
            vault.onERC1155Received(address(clear), mallory, optionId, 1, ""), bytes4(0), "a transfer in is refused"
        );
        vm.prank(address(clear));
        assertEq(
            vault.onERC1155Received(address(clear), address(0), optionId, 1, ""),
            vault.onERC1155Received.selector,
            "a mint is accepted"
        );
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amts = new uint256[](2);
        vm.prank(address(clear));
        assertEq(
            vault.onERC1155BatchReceived(address(clear), address(0), ids, amts, ""),
            vault.onERC1155BatchReceived.selector,
            "a batch mint (first write) is accepted"
        );
        vm.prank(address(clear));
        assertEq(
            vault.onERC1155BatchReceived(address(clear), mallory, ids, amts, ""),
            bytes4(0),
            "a batch transfer in is not"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The fraction-applied view Seaport would hand the zone for a fill of `k` of `c`.
    function _zoneParams(OrderComponents memory c, uint256 k) internal view returns (ZoneParameters memory zp) {
        SpentItem[] memory offer = new SpentItem[](1);
        offer[0] = SpentItem({
            itemType: c.offer[0].itemType,
            token: c.offer[0].token,
            identifier: c.offer[0].identifierOrCriteria,
            amount: k
        });
        ReceivedItem[] memory consid = new ReceivedItem[](1);
        consid[0] = ReceivedItem({
            itemType: c.consideration[0].itemType,
            token: c.consideration[0].token,
            identifier: 0,
            amount: (c.consideration[0].startAmount * k) / c.offer[0].startAmount,
            recipient: c.consideration[0].recipient
        });
        zp = ZoneParameters({
            orderHash: mockSeaport.getOrderHash(c),
            fulfiller: buyer,
            offerer: c.offerer,
            offer: offer,
            consideration: consid,
            extraData: "",
            orderHashes: new bytes32[](0),
            startTime: c.startTime,
            endTime: c.endTime,
            zoneHash: c.zoneHash
        });
    }

    function _params(OrderComponents memory c) internal pure returns (OrderParameters memory p) {
        p = OrderParameters({
            offerer: c.offerer,
            zone: c.zone,
            offer: c.offer,
            consideration: c.consideration,
            orderType: c.orderType,
            startTime: c.startTime,
            endTime: c.endTime,
            zoneHash: c.zoneHash,
            salt: c.salt,
            conduitKey: c.conduitKey,
            totalOriginalConsiderationItems: c.consideration.length
        });
    }
}

/// @dev A clearinghouse stub whose `write` returns a claim id other than the one it was asked to top up.
contract WrongClaimClear {
    function feesEnabled() external pure returns (bool) {
        return false;
    }

    function write(uint256, uint112) external pure returns (uint256) {
        return 8;
    }
}
