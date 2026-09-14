// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {
    RealSeaportBase,
    ISeaportFulfil,
    ISeaportErrors,
    AdvancedOrder,
    CriteriaResolver,
    FulfillmentComponent,
    Fulfillment,
    BasicOrderParameters,
    BasicOrderType,
    AdditionalRecipient
} from "../helpers/RealSeaportBase.sol";
import {RealClearBase} from "../helpers/RealClearBase.sol";
import {Vault} from "../../src/Vault.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {IERC1155Minimal} from "../../src/interfaces/IERC1155Minimal.sol";
import {
    ISeaport,
    IZone,
    Order,
    OrderComponents,
    OrderParameters,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType,
    SpentItem,
    ReceivedItem,
    ZoneParameters
} from "../../src/interfaces/ISeaport.sol";

/// @dev A contract buyer whose ERC-1155 receive hook, which the real Seaport runs between the vault's
///      two zone hooks, tries to re-enter Seaport and the vault. Everything is caught and recorded.
contract HostileBuyer {
    Vault internal immutable vault;
    ISeaport internal immutable seaport;
    IERC1155Minimal internal immutable clear;

    bytes public validateRevert;
    bytes public counterRevert;
    bytes public authorizeRevert;
    bytes public donationRevert;
    uint256 public hookCalls;

    constructor(Vault vault_, ISeaport seaport_, IERC1155Minimal clear_) {
        vault = vault_;
        seaport = seaport_;
        clear = clear_;
    }

    function onERC1155Received(address, address, uint256 id, uint256 amount, bytes calldata) external returns (bytes4) {
        hookCalls++;
        // Seaport: its transient reentrancy guard is set for the whole fill.
        (bool ok, bytes memory ret) = address(seaport).call(abi.encodeCall(ISeaport.validate, (new Order[](0))));
        if (!ok) validateRevert = ret;
        (ok, ret) = address(seaport).call(abi.encodeCall(ISeaport.incrementCounter, ()));
        if (!ok) counterRevert = ret;
        // The vault's hook, forged.
        ZoneParameters memory zp;
        zp.orderHash = vault.listingHash();
        zp.offerer = address(vault);
        zp.offer = new SpentItem[](1);
        zp.offer[0].amount = 1;
        zp.consideration = new ReceivedItem[](1);
        (ok, ret) = address(vault).call(abi.encodeCall(IZone.authorizeOrder, (zp)));
        if (!ok) authorizeRevert = ret;
        // A donation of the tokens just received, mid-fill.
        (ok, ret) = address(clear)
            .call(abi.encodeCall(IERC1155Minimal.safeTransferFrom, (address(this), address(vault), id, amount, "")));
        if (!ok) donationRevert = ret;
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function approve(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok);
    }
}

/// @notice WRITE ON FILL against the REAL Seaport 1.6 runtime (etched from chain 4663) and the REAL
///         Valorem Clear bytecode: every fulfilment path Seaport offers, driven by a buyer.
/// @dev The mock suite (test/unit/VaultWriteOnFill.t.sol) covers what the hooks do; this suite covers
///      what Seaport does around them, on the genuine code: `fulfillOrder`, `fulfillAdvancedOrder` in
///      fractions, `fulfillAvailableAdvancedOrders` with the same listing twice (within the remainder,
///      and overfilling it), `matchAdvancedOrders` against a buyer's mirror order, `fulfillBasicOrder`,
///      the skip-versus-revert rules, Seaport's own time edge, a hostile contract buyer, and a foreign
///      order that names the vault as zone. The vault never calls a fulfil function; the tests do.
contract VaultRealSeaportTest is BaseTest, RealSeaportBase, RealClearBase {
    uint112 internal constant N = 20;
    address internal mallory = makeAddr("mallory");
    address internal matcher = makeAddr("matcher");

    function _deployClear() internal override returns (IValoremClear) {
        return _deployRealClear();
    }

    function _deploySeaport() internal override returns (ISeaport) {
        _installRealSeaport();
        return realSeaport;
    }

    /// @dev Route the shared helper's fill through the real `fulfillAdvancedOrder`, as `k / size`.
    function _fill(OrderComponents memory c, uint256 fillAmount) internal override {
        vm.prank(buyer);
        usdg.approve(SEAPORT_16, type(uint256).max);
        assertTrue(_fulfillAdvanced(buyer, c, uint120(fillAmount), uint120(c.offer[0].startAmount)), "fill");
    }

    function setUp() public override {
        super.setUp();
        _fund(buyer, 0, 10_000_000_000);
        vm.prank(buyer);
        usdg.approve(SEAPORT_16, type(uint256).max);
    }

    function _listed() internal returns (uint256 optionId, OrderComponents memory c) {
        _deposit(alice, 30e18);
        optionId = _rollOpen();
        c = _approveListing(optionId, N, _okUnitPrice());
    }

    /*//////////////////////////////////////////////////////////////
                              SINGLE FILLS
    //////////////////////////////////////////////////////////////*/

    /// @dev The plain path: `fulfillOrder` takes the whole listing in one go. The hook writes all 20.
    function test_fulfillOrder_writesTheWholeListing() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        Order memory o = Order({parameters: _toParameters(c), signature: ""});
        vm.prank(buyer);
        assertTrue(realSeaportFulfil.fulfillOrder(o, bytes32(0)));

        assertEq(vault.contractsWritten(), N, "written == sold == 20");
        assertEq(clear.balanceOf(buyer, optionId), N);
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no inventory");
        assertEq(usdg.balanceOf(address(vault)), uint256(N) * _okUnitPrice());
        assertEq(clear.claim(vault.claimKey()).amountWritten, uint256(N) * 1e18, "real Clear agrees");
        (,, uint256 filled, uint256 size) = realSeaport.getOrderStatus(realSeaport.getOrderHash(c));
        assertEq(filled, size, "Seaport records the order as fully filled");
    }

    /// @dev `fulfillAdvancedOrder` in fractions: the first fill opens the claim, the second tops it up,
    ///      Seaport tracks the fraction, and the vault's balance is zero after each.
    function test_fulfillAdvancedOrder_firstFillOpensTheClaimLaterFillsTopItUp() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        assertEq(vault.contractsWritten(), 0, "nothing written at open/list");

        assertTrue(_fulfillAdvanced(buyer, c, 5, N));
        uint256 key = vault.claimKey();
        assertGt(key, 0, "first fill opened the claim");
        assertEq(vault.contractsWritten(), 5);
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no inventory after the first fill");
        assertEq(clear.balanceOf(buyer, optionId), 5);

        assertTrue(_fulfillAdvanced(buyer, c, 3, N));
        assertEq(vault.contractsWritten(), 8);
        assertEq(vault.claimKey(), key, "top-up keeps the claim");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no inventory after the top-up");
        assertEq(clear.balanceOf(buyer, optionId), 8);
        assertEq(usdg.balanceOf(address(vault)), 8 * _okUnitPrice());
        assertEq(clear.claim(key).amountWritten, 8e18);

        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            realSeaport.getOrderStatus(realSeaport.getOrderHash(c));
        assertTrue(validated);
        assertFalse(cancelled);
        assertEq(filled, 8);
        assertEq(size, N);
    }

    /// @dev Seaport's own clock agrees with the hook's: `endTime == cycleExerciseTs` is exclusive, so a
    ///      fill one second before the window goes through and one ON the tick fails `InvalidTime`
    ///      before the hook is even reached.
    function test_fill_atExerciseTsMinusOneWorks_atExerciseTsSeaportRefuses() public {
        (, OrderComponents memory c) = _listed();
        vm.warp(uint256(exerciseTs) - 1);
        feed.setAnswer(SPOT_FEED);
        assertTrue(_fulfillAdvanced(buyer, c, 2, N));
        assertEq(vault.contractsWritten(), 2);

        vm.warp(exerciseTs);
        feed.setAnswer(SPOT_FEED);
        AdvancedOrder memory ao = _advanced(c, 1, N, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ISeaportErrors.InvalidTime.selector, 0, exerciseTs));
        realSeaportFulfil.fulfillAdvancedOrder(ao, new CriteriaResolver[](0), bytes32(0), buyer);
        assertEq(vault.contractsWritten(), 2, "nothing written on the tick");
    }

    /// @dev A hook revert on a single-order path reverts the whole fill with the hook's own reason
    ///      (Seaport bubbles it): a rally that pulls the strike inside the band floor.
    function test_fulfillAdvancedOrder_hookRevertBubblesAndWritesNothing() public {
        (, OrderComponents memory c) = _listed();
        feed.setAnswer(229_00000000); // 231 strike inside the 3% floor at $229
        AdvancedOrder memory ao = _advanced(c, 5, N, "");
        vm.prank(buyer);
        vm.expectRevert();
        realSeaportFulfil.fulfillAdvancedOrder(ao, new CriteriaResolver[](0), bytes32(0), buyer);
        assertEq(vault.contractsWritten(), 0, "the stale-priced fill wrote nothing");
        assertEq(vault.claimKey(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        THE SAME ORDER, TWICE
    //////////////////////////////////////////////////////////////*/

    /// @dev `fulfillAvailableAdvancedOrders` with the vault's listing TWICE, both fractions inside the
    ///      remainder: Seaport runs `authorizeOrder` twice before any transfer, then both transfers, then
    ///      `validateOrder` twice. The transient baseline is taken once, so both validations see the
    ///      balance back where it started; 2 + 3 = 5 are written and sold.
    function test_fulfillAvailable_sameOrderTwiceWithinTheRemainder() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        AdvancedOrder[] memory aos = new AdvancedOrder[](2);
        aos[0] = _advanced(c, 2, N, "");
        aos[1] = _advanced(c, 3, N, "");
        (FulfillmentComponent[][] memory offerF, FulfillmentComponent[][] memory consF) = _aggregateTwo();

        vm.prank(buyer);
        bool[] memory available = realSeaportFulfil.fulfillAvailableAdvancedOrders(
            aos, new CriteriaResolver[](0), offerF, consF, bytes32(0), buyer, 2
        );
        assertTrue(available[0] && available[1], "both occurrences filled");
        assertEq(vault.contractsWritten(), 5, "two authorisations, five written");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no inventory");
        assertEq(clear.balanceOf(buyer, optionId), 5);
        assertEq(usdg.balanceOf(address(vault)), 5 * _okUnitPrice());
        (,, uint256 filled,) = realSeaport.getOrderStatus(realSeaport.getOrderHash(c));
        assertEq(filled, 5);
    }

    /// @dev The same listing twice with fractions that OVERFILL the remainder. Both `authorizeOrder`s
    ///      succeed (they see the pre-fill status), the second status update fails, and because an
    ///      authorised hook cannot be skipped, Seaport reverts the WHOLE transaction: the first
    ///      occurrence's write rolls back with it and the vault ends exactly where it started.
    function test_fulfillAvailable_sameOrderTwiceOverfillingRevertsTheWholeTx() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        AdvancedOrder[] memory aos = new AdvancedOrder[](2);
        aos[0] = _advanced(c, 15, N, "");
        aos[1] = _advanced(c, 10, N, "");
        (FulfillmentComponent[][] memory offerF, FulfillmentComponent[][] memory consF) = _aggregateTwo();

        vm.prank(buyer);
        vm.expectRevert();
        realSeaportFulfil.fulfillAvailableAdvancedOrders(
            aos, new CriteriaResolver[](0), offerF, consF, bytes32(0), buyer, 2
        );

        assertEq(vault.contractsWritten(), 0, "the first occurrence's write rolled back with the tx");
        assertEq(vault.claimKey(), 0, "no claim");
        assertEq(clear.balanceOf(address(vault), optionId), 0);
        assertEq(clear.balanceOf(buyer, optionId), 0);
        assertEq(nvda.balanceOf(address(vault)), 30e18, "not a wei of collateral moved");
        (,, uint256 filled,) = realSeaport.getOrderStatus(realSeaport.getOrderHash(c));
        assertEq(filled, 0, "Seaport recorded nothing either");
    }

    /*//////////////////////////////////////////////////////////////
                          SKIP VERSUS REVERT
    //////////////////////////////////////////////////////////////*/

    /// @dev Inside `fulfillAvailable*` a hook revert SKIPS the order rather than reverting the batch:
    ///      halted, the vault's listing is skipped, the state changes of its hook roll back with the
    ///      call frame, and a stranger's open order in the same batch still fills. With the vault's
    ///      order alone the batch reverts `NoSpecifiedOrdersAvailable`. The web must read
    ///      `OrderFulfilled`, never assume a successful tx filled the vault.
    function test_fulfillAvailable_hookRevertSkipsTheVaultOrder() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        vm.prank(guardian);
        vault.haltWrites();

        // Alone: nothing available.
        AdvancedOrder[] memory one = new AdvancedOrder[](1);
        one[0] = _advanced(c, 2, N, "");
        FulfillmentComponent[][] memory offer1 = new FulfillmentComponent[][](1);
        offer1[0] = new FulfillmentComponent[](1);
        offer1[0][0] = FulfillmentComponent(0, 0);
        vm.prank(buyer);
        vm.expectRevert(ISeaportErrors.NoSpecifiedOrdersAvailable.selector);
        realSeaportFulfil.fulfillAvailableAdvancedOrders(
            one, new CriteriaResolver[](0), offer1, offer1, bytes32(0), buyer, 1
        );

        // Beside a stranger's open order: skipped, the other fills.
        (address seller, uint256 sellerKey) = makeAddrAndKey("seller");
        _fund(seller, 5e18, 0);
        vm.startPrank(seller);
        nvda.approve(address(clear), type(uint256).max);
        clear.write(optionId, 5);
        clear.setApprovalForAll(SEAPORT_16, true);
        vm.stopPrank();
        OrderComponents memory theirs = _buildOrder(optionId, 5, _okUnitPrice());
        theirs.offerer = seller;
        theirs.zone = address(0);
        theirs.orderType = OrderType.PARTIAL_OPEN;
        theirs.consideration[0].recipient = payable(seller);
        theirs.counter = realSeaport.getCounter(seller);

        AdvancedOrder[] memory aos = new AdvancedOrder[](2);
        aos[0] = _advanced(c, 2, N, "");
        aos[1] = _advanced(theirs, 1, 5, _signOrder(sellerKey, theirs));
        FulfillmentComponent[][] memory offerF = new FulfillmentComponent[][](2);
        FulfillmentComponent[][] memory consF = new FulfillmentComponent[][](2);
        for (uint256 i; i < 2; i++) {
            offerF[i] = new FulfillmentComponent[](1);
            offerF[i][0] = FulfillmentComponent(i, 0);
            consF[i] = new FulfillmentComponent[](1);
            consF[i][0] = FulfillmentComponent(i, 0);
        }
        vm.prank(buyer);
        bool[] memory available = realSeaportFulfil.fulfillAvailableAdvancedOrders(
            aos, new CriteriaResolver[](0), offerF, consF, bytes32(0), buyer, 2
        );
        assertFalse(available[0], "the vault's order was skipped");
        assertTrue(available[1], "the stranger's filled");
        assertEq(vault.contractsWritten(), 0, "the skipped hook's write rolled back");
        assertEq(clear.balanceOf(buyer, optionId), 1, "one from the stranger");
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(usdg.balanceOf(seller), _okUnitPrice());
    }

    /*//////////////////////////////////////////////////////////////
                                 MATCH
    //////////////////////////////////////////////////////////////*/

    /// @dev `matchAdvancedOrders`: a third party matches a fraction of the vault's listing against a
    ///      buyer's signed mirror order (USDG for the option tokens). The vault's restricted order
    ///      still runs both hooks, the write lands, and the tokens go to the buyer, not the matcher.
    function test_matchAdvancedOrders_writesAndDeliversToTheMirrorOrdersOfferer() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        (address mirror, uint256 mirrorKey) = makeAddrAndKey("mirrorBuyer");
        _fund(mirror, 0, 100_000_000);
        vm.prank(mirror);
        usdg.approve(SEAPORT_16, type(uint256).max);

        uint256 k = 4;
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC20, address(usdg), 0, k * _okUnitPrice(), k * _okUnitPrice());
        ConsiderationItem[] memory cons = new ConsiderationItem[](1);
        cons[0] = ConsiderationItem(ItemType.ERC1155, address(clear), optionId, k, k, payable(mirror));
        OrderComponents memory m = OrderComponents({
            offerer: mirror,
            zone: address(0),
            offer: offer,
            consideration: cons,
            orderType: OrderType.FULL_OPEN,
            startTime: 0,
            endTime: exerciseTs,
            zoneHash: bytes32(0),
            salt: 99,
            conduitKey: bytes32(0),
            counter: realSeaport.getCounter(mirror)
        });

        AdvancedOrder[] memory aos = new AdvancedOrder[](2);
        aos[0] = _advanced(c, uint120(k), N, "");
        aos[1] = _advanced(m, 1, 1, _signOrder(mirrorKey, m));

        Fulfillment[] memory f = new Fulfillment[](2);
        f[0].offerComponents = new FulfillmentComponent[](1);
        f[0].offerComponents[0] = FulfillmentComponent(0, 0); // vault's option tokens
        f[0].considerationComponents = new FulfillmentComponent[](1);
        f[0].considerationComponents[0] = FulfillmentComponent(1, 0); // to the mirror buyer
        f[1].offerComponents = new FulfillmentComponent[](1);
        f[1].offerComponents[0] = FulfillmentComponent(1, 0); // mirror buyer's USDG
        f[1].considerationComponents = new FulfillmentComponent[](1);
        f[1].considerationComponents[0] = FulfillmentComponent(0, 0); // to the vault

        vm.prank(matcher);
        realSeaportFulfil.matchAdvancedOrders(aos, new CriteriaResolver[](0), f, matcher);

        assertEq(vault.contractsWritten(), k, "the match wrote exactly the matched fraction");
        assertEq(clear.balanceOf(mirror, optionId), k, "the mirror buyer holds the calls");
        assertEq(clear.balanceOf(matcher, optionId), 0, "the matcher got nothing");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no inventory");
        assertEq(usdg.balanceOf(address(vault)), k * _okUnitPrice(), "premium from the mirror order");
    }

    /*//////////////////////////////////////////////////////////////
                              BASIC ORDER
    //////////////////////////////////////////////////////////////*/

    /// @dev `fulfillBasicOrder` on the ERC20_TO_ERC1155_PARTIAL_RESTRICTED route fills an UNUSED order
    ///      in full and runs both hooks: the whole listing is written and sold. After any partial fill
    ///      the basic path is closed (`OrderPartiallyFilled`), so buyers use the advanced path then.
    function test_fulfillBasicOrder_fillsAnUnusedListingWhole_andIsRefusedAfterAPartialFill() public {
        _deposit(alice, 30e18);
        uint256 optionId = _rollOpen();
        OrderComponents memory small = _approveListing(optionId, 3, _okUnitPrice());

        vm.prank(buyer);
        assertTrue(realSeaportFulfil.fulfillBasicOrder(_basic(small)));
        assertEq(vault.contractsWritten(), 3, "the basic fill wrote the whole listing");
        assertEq(clear.balanceOf(buyer, optionId), 3);
        assertEq(clear.balanceOf(address(vault), optionId), 0);
        assertEq(usdg.balanceOf(address(vault)), 3 * _okUnitPrice());

        // A second listing, partially filled through the advanced path, then basic is refused.
        vm.prank(keeper);
        vault.cancelListing(small);
        OrderComponents memory again = _approveListing(optionId, 5, _okUnitPrice() + 1);
        assertTrue(_fulfillAdvanced(buyer, again, 1, 5));
        bytes32 h = realSeaport.getOrderHash(again);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ISeaportErrors.OrderPartiallyFilled.selector, h));
        realSeaportFulfil.fulfillBasicOrder(_basic(again));
        assertEq(vault.contractsWritten(), 4, "3 + 1, nothing from the refused basic fill");
    }

    /*//////////////////////////////////////////////////////////////
                           HOSTILE PARTICIPANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev A contract buyer re-entering from its ERC-1155 hook: Seaport's transient guard refuses
    ///      `validate` and `incrementCounter` (`NoReentrantCalls`), the vault's hook refuses the
    ///      stranger (`NotSeaport`), the mid-fill donation is refused by the receiver hook, and the
    ///      fill still completes with the post-condition intact.
    function test_hostileContractBuyer_cannotReenterSeaportOrTheVault() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        HostileBuyer evil = new HostileBuyer(vault, realSeaport, IERC1155Minimal(address(clear)));
        _fund(address(evil), 0, 100_000_000);
        evil.approve(address(usdg), SEAPORT_16);

        AdvancedOrder memory ao = _advanced(c, 3, N, "");
        vm.prank(address(evil));
        assertTrue(realSeaportFulfil.fulfillAdvancedOrder(ao, new CriteriaResolver[](0), bytes32(0), address(evil)));

        assertEq(evil.hookCalls(), 1);
        assertEq(bytes4(evil.validateRevert()), ISeaportErrors.NoReentrantCalls.selector, "Seaport guard: validate");
        assertEq(bytes4(evil.counterRevert()), ISeaportErrors.NoReentrantCalls.selector, "Seaport guard: counter");
        assertEq(bytes4(evil.authorizeRevert()), Vault.NotSeaport.selector, "the vault's hook refused the buyer");
        assertGt(evil.donationRevert().length, 0, "the mid-fill donation was refused");
        assertEq(vault.contractsWritten(), 3, "the fill completed");
        assertEq(clear.balanceOf(address(evil), optionId), 3);
        assertEq(clear.balanceOf(address(vault), optionId), 0, "nothing left behind");
    }

    /// @dev A stranger's restricted order that names the vault as zone: Seaport calls the vault's
    ///      `authorizeOrder`, which refuses `NotLiveListing` because the hash is not the vault's
    ///      listing. The vault cannot be made to write on somebody else's behalf.
    function test_foreignOrderNamingTheVaultAsZoneIsRefused() public {
        (uint256 optionId,) = _listed();
        (address m, uint256 pk) = makeAddrAndKey("foreignOfferer");
        _fund(m, 2e18, 0);
        vm.startPrank(m);
        nvda.approve(address(clear), type(uint256).max);
        clear.write(optionId, 1);
        clear.setApprovalForAll(SEAPORT_16, true);
        vm.stopPrank();

        OrderComponents memory foreign = _buildOrder(optionId, 1, _okUnitPrice());
        foreign.offerer = m;
        foreign.consideration[0].recipient = payable(m);
        foreign.counter = realSeaport.getCounter(m);
        bytes32 h = realSeaport.getOrderHash(foreign);
        AdvancedOrder memory ao = _advanced(foreign, 1, 1, _signOrder(pk, foreign));

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Vault.NotLiveListing.selector, h));
        realSeaportFulfil.fulfillAdvancedOrder(ao, new CriteriaResolver[](0), bytes32(0), buyer);
        assertEq(vault.contractsWritten(), 0);
        assertEq(clear.balanceOf(m, optionId), 1, "the stranger keeps its token");
    }

    /// @dev Killing a listing on the real Seaport: `cancel` makes the hash dead for ever, and a counter
    ///      bump re-keys every outstanding order so the old one no longer even hashes to a validated
    ///      order. Both paths stop fills without any vault-side flag.
    function test_cancelAndCounterBumpStopFillsOnTheRealSeaport() public {
        (, OrderComponents memory c) = _listed();
        bytes32 h = realSeaport.getOrderHash(c);
        vm.prank(guardian);
        vault.cancelListing(c);
        AdvancedOrder memory ao = _advanced(c, 1, N, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ISeaportErrors.OrderIsCancelled.selector, h));
        realSeaportFulfil.fulfillAdvancedOrder(ao, new CriteriaResolver[](0), bytes32(0), buyer);

        OrderComponents memory second = _approveListing(vault.optionId(), N, _okUnitPrice() + 1);
        vm.prank(guardian);
        vault.invalidateAllListings();
        assertGt(realSeaport.getCounter(address(vault)), 0, "the real counter jumped");
        AdvancedOrder memory ao2 = _advanced(second, 1, N, "");
        vm.prank(buyer);
        vm.expectRevert();
        realSeaportFulfil.fulfillAdvancedOrder(ao2, new CriteriaResolver[](0), bytes32(0), buyer);
        assertEq(vault.contractsWritten(), 0, "nothing ever filled");
    }

    /*//////////////////////////////////////////////////////////////
                          A FULL CYCLE, FOR REAL
    //////////////////////////////////////////////////////////////*/

    /// @dev End to end on the real code: fills through Seaport, exercise and redeem on the real Clear,
    ///      settlement to the cent. Sell 8 of 20, 3 exercised at 231 against a 260 spot.
    function test_fullCycleOnRealSeaportAndRealClear() public {
        (uint256 optionId, OrderComponents memory c) = _listed();
        assertTrue(_fulfillAdvanced(buyer, c, 5, N));
        assertTrue(_fulfillAdvanced(buyer, c, 3, N));
        assertEq(vault.contractsWritten(), 8);

        feed.setAnswer(260_00000000);
        _warpToExercise();
        vault.lockBook();
        _exercise(optionId, 3);
        assertEq(vault.contractsAssigned(), 3);
        assertEq(vault.lockedAssets(), 5e18);

        _warpToExpiry();
        _rollClose();
        assertEq(nvda.balanceOf(address(vault)), 27e18, "22 idle + 5 returned");
        assertEq(nvda.balanceOf(buyer), 3e18, "three lots delivered");
        assertEq(usdg.balanceOf(address(vault)) + usdg.balanceOf(feeSafe), 8 * _okUnitPrice() + 3 * 231_000_000);
        assertEq(usdg.balanceOf(feeSafe), (8 * _okUnitPrice() * 500) / 10_000, "fee on premium only");
        assertEq(_phase(), 0);
        assertTrue(vault.canRedeemInstantly());
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Aggregated fulfilments for two occurrences of the same one-offer, one-consideration order.
    function _aggregateTwo()
        internal
        pure
        returns (FulfillmentComponent[][] memory offerF, FulfillmentComponent[][] memory consF)
    {
        offerF = new FulfillmentComponent[][](1);
        offerF[0] = new FulfillmentComponent[](2);
        offerF[0][0] = FulfillmentComponent(0, 0);
        offerF[0][1] = FulfillmentComponent(1, 0);
        consF = new FulfillmentComponent[][](1);
        consF[0] = new FulfillmentComponent[](2);
        consF[0][0] = FulfillmentComponent(0, 0);
        consF[0][1] = FulfillmentComponent(1, 0);
    }

    /// @dev The vault's listing as a basic order: the fulfiller pays the USDG consideration to the
    ///      offerer for the ERC-1155 offer item.
    function _basic(OrderComponents memory c) internal pure returns (BasicOrderParameters memory b) {
        b = BasicOrderParameters({
            considerationToken: c.consideration[0].token,
            considerationIdentifier: 0,
            considerationAmount: c.consideration[0].startAmount,
            offerer: payable(c.offerer),
            zone: c.zone,
            offerToken: c.offer[0].token,
            offerIdentifier: c.offer[0].identifierOrCriteria,
            offerAmount: c.offer[0].startAmount,
            basicOrderType: BasicOrderType.ERC20_TO_ERC1155_PARTIAL_RESTRICTED,
            startTime: c.startTime,
            endTime: c.endTime,
            zoneHash: c.zoneHash,
            salt: c.salt,
            offererConduitKey: c.conduitKey,
            fulfillerConduitKey: bytes32(0),
            totalOriginalAdditionalRecipients: 0,
            additionalRecipients: new AdditionalRecipient[](0),
            signature: ""
        });
    }
}
