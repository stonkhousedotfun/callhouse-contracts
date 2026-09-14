// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RealSeaportBase} from "../helpers/RealSeaportBase.sol";
import {RealClearBase} from "../helpers/RealClearBase.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockSeaport} from "../../src/mocks/MockSeaport.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {IERC1155Minimal} from "../../src/interfaces/IERC1155Minimal.sol";
import {
    ISeaport,
    IZone,
    Order,
    OrderComponents,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType,
    ZoneParameters
} from "../../src/interfaces/ISeaport.sol";

/// @dev A zone that records what Seaport hands it and WHEN, by reading the offerer's ERC-1155 balance
///      inside each hook. That is the direct observation of "authorizeOrder before any transfer,
///      validateOrder after all transfers" against the genuine runtime.
contract RecordingZone is IZone {
    IERC1155Minimal public immutable token;
    address public immutable offerer;
    uint256 public immutable id;

    uint256 public authorizeCalls;
    uint256 public validateCalls;
    uint256 public balanceAtAuthorize;
    uint256 public balanceAtValidate;
    uint256 public offerAmountSeen;
    uint256 public considerationAmountSeen;
    address public fulfillerSeen;
    bytes32 public orderHashSeen;
    uint256 public hashesAtAuthorize;
    uint256 public hashesAtValidate;
    bool public refuse;

    constructor(IERC1155Minimal token_, address offerer_, uint256 id_) {
        token = token_;
        offerer = offerer_;
        id = id_;
    }

    function setRefuse(bool r) external {
        refuse = r;
    }

    function authorizeOrder(ZoneParameters calldata zp) external returns (bytes4) {
        authorizeCalls++;
        balanceAtAuthorize = token.balanceOf(offerer, id);
        offerAmountSeen = zp.offer[0].amount;
        considerationAmountSeen = zp.consideration[0].amount;
        fulfillerSeen = zp.fulfiller;
        orderHashSeen = zp.orderHash;
        hashesAtAuthorize = zp.orderHashes.length;
        if (refuse) return 0xffffffff;
        return IZone.authorizeOrder.selector;
    }

    function validateOrder(ZoneParameters calldata zp) external returns (bytes4) {
        validateCalls++;
        balanceAtValidate = token.balanceOf(offerer, id);
        hashesAtValidate = zp.orderHashes.length;
        return IZone.validateOrder.selector;
    }
}

/// @title Fixture sanity: the vendored Seaport 1.6 and Valorem Clear runtimes behave as verified on chain
/// @notice Pins the facts later stages build on, against the real bytecode: `information()`, the pinned
///         runtime hashes, an EOA fill, and the zone-hook ORDER for restricted orders. The same recording
///         zone is then run through {MockSeaport.fulfil} so the mock's hook sequence is checked against
///         the real one rather than against our reading of the docs.
contract FixturesTest is Test, RealSeaportBase, RealClearBase {
    MockStockToken internal nvda;
    MockERC20 internal usdg;
    MockClear internal clear;
    MockSeaport internal mockSeaport;

    address internal seller;
    uint256 internal sellerKey;
    address internal buyer = makeAddr("buyer");
    address internal feeSink = makeAddr("feeSink");

    uint40 internal exerciseTs;
    uint40 internal expiryTs;
    uint256 internal optionId;

    function setUp() public {
        vm.warp(1_789_000_000);
        _installRealSeaport();

        (seller, sellerKey) = makeAddrAndKey("seller");
        nvda = new MockStockToken("NVDA Stock Token", "NVDAx");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        clear = new MockClear();
        mockSeaport = new MockSeaport();

        nvda.mint(seller, 100e18);
        usdg.mint(buyer, 10_000_000_000);
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        optionId = clear.newOptionType(address(nvda), 1e18, address(usdg), 231_000_000, exerciseTs, expiryTs);

        vm.startPrank(seller);
        nvda.approve(address(clear), type(uint256).max);
        clear.write(optionId, 20);
        clear.setApprovalForAll(SEAPORT_16, true);
        clear.setApprovalForAll(address(mockSeaport), true);
        vm.stopPrank();

        vm.startPrank(buyer);
        usdg.approve(SEAPORT_16, type(uint256).max);
        usdg.approve(address(mockSeaport), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              REAL SEAPORT
    //////////////////////////////////////////////////////////////*/

    function test_realSeaport_matchesTheChainRuntime() public view {
        assertEq(SEAPORT_16.codehash, SEAPORT_16_RUNTIME_HASH, "Seaport extcodehash");
        assertEq(CONDUIT_CONTROLLER.codehash, CONDUIT_CONTROLLER_RUNTIME_HASH, "ConduitController extcodehash");
        assertEq(SEAPORT_16.code.length, 23_981, "Seaport 1.6 runtime is 23,981 B on 4663");
        (string memory version, bytes32 domainSeparator, address controller) = realSeaport.information();
        assertEq(version, "1.6");
        assertEq(controller, CONDUIT_CONTROLLER);
        assertTrue(domainSeparator != bytes32(0));
        assertEq(realSeaport.getCounter(seller), 0);
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID);
    }

    /// An EOA-signed PARTIAL_OPEN order fills for a fraction through the real runtime.
    function test_realSeaport_fillsASignedPartialOpenOrder() public {
        OrderComponents memory c = _order(seller, address(0), OrderType.PARTIAL_OPEN, 20, 2_000_000, realSeaport);
        bytes memory sig = _signOrder(sellerKey, c);

        assertTrue(_fulfillAdvanced(buyer, c, 5, 20, sig));
        assertEq(clear.balanceOf(buyer, optionId), 5);
        assertEq(clear.balanceOf(seller, optionId), 15);
        assertEq(usdg.balanceOf(seller), 5 * 2_000_000);

        (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize) =
            realSeaport.getOrderStatus(realSeaport.getOrderHash(c));
        assertTrue(isValidated);
        assertFalse(isCancelled);
        assertEq(totalFilled, 5);
        assertEq(totalSize, 20);
    }

    /// For a PARTIAL_RESTRICTED order the real runtime calls `authorizeOrder` BEFORE the transfer (the
    /// offerer still holds all 20) and `validateOrder` AFTER it (15 left), with fraction-applied amounts,
    /// the fulfiller as `msg.sender`, and `orderHashes` truncated in authorize and complete in validate.
    function test_realSeaport_authorizeBeforeTransfersValidateAfter() public {
        RecordingZone zone = new RecordingZone(IERC1155Minimal(address(clear)), seller, optionId);
        OrderComponents memory c =
            _order(seller, address(zone), OrderType.PARTIAL_RESTRICTED, 20, 2_000_000, realSeaport);
        bytes memory sig = _signOrder(sellerKey, c);

        assertTrue(_fulfillAdvanced(buyer, c, 5, 20, sig));
        _assertHookRecord(zone, realSeaport.getOrderHash(c));
    }

    /// A zone that refuses in `authorizeOrder` stops the fill before anything moves.
    function test_realSeaport_refusedAuthorizeMovesNothing() public {
        RecordingZone zone = new RecordingZone(IERC1155Minimal(address(clear)), seller, optionId);
        zone.setRefuse(true);
        OrderComponents memory c =
            _order(seller, address(zone), OrderType.PARTIAL_RESTRICTED, 20, 2_000_000, realSeaport);
        bytes memory sig = _signOrder(sellerKey, c);

        vm.expectRevert();
        _fulfillAdvanced(buyer, c, 5, 20, sig);
        assertEq(clear.balanceOf(seller, optionId), 20, "nothing moved");
        assertEq(usdg.balanceOf(seller), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         MOCK SEAPORT PARITY
    //////////////////////////////////////////////////////////////*/

    /// {MockSeaport.fulfil} drives the same zone through the same sequence as the real runtime.
    function test_mockSeaport_hookOrderMatchesReal() public {
        RecordingZone zone = new RecordingZone(IERC1155Minimal(address(clear)), seller, optionId);
        OrderComponents memory c =
            _order(seller, address(zone), OrderType.PARTIAL_RESTRICTED, 20, 2_000_000, ISeaport(address(mockSeaport)));
        // The mock has no signatures: the offerer pre-validates, as the vault does on chain.
        _validateOnMock(c);

        vm.prank(buyer);
        mockSeaport.fulfil(c, 5);
        _assertHookRecord(zone, mockSeaport.getOrderHash(c));
    }

    function test_mockSeaport_refusedAuthorizeMovesNothing() public {
        RecordingZone zone = new RecordingZone(IERC1155Minimal(address(clear)), seller, optionId);
        zone.setRefuse(true);
        OrderComponents memory c =
            _order(seller, address(zone), OrderType.PARTIAL_RESTRICTED, 20, 2_000_000, ISeaport(address(mockSeaport)));
        _validateOnMock(c);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(MockSeaport.InvalidRestrictedOrder.selector, mockSeaport.getOrderHash(c))
        );
        mockSeaport.fulfil(c, 5);
        assertEq(clear.balanceOf(seller, optionId), 20, "nothing moved");
    }

    /*//////////////////////////////////////////////////////////////
                               REAL CLEAR
    //////////////////////////////////////////////////////////////*/

    function test_realClear_deploysWithTheVerifiedDefaults() public {
        IValoremClear real = _deployRealClear();
        assertEq(real.feeBps(), 15);
        assertFalse(real.feesEnabled());
        assertEq(real.feeTo(), CLEAR_FEE_TO);
        assertEq(real.tokenURIGenerator(), CLEAR_URI_GENERATOR);

        // A type on tokens with supply is created; its settlement seed is the option key.
        uint256 id = real.newOptionType(address(nvda), 1e18, address(usdg), 231_000_000, exerciseTs, expiryTs);
        assertEq(uint8(real.tokenType(id)), uint8(IValoremClear.TokenType.Option));
        assertEq(real.option(id).settlementSeed, uint160(id >> 96));
        assertEq(id, optionId, "the option id does not depend on which clearinghouse holds it");

        // The fee switch is the admin's alone.
        vm.expectRevert(
            abi.encodeWithSelector(IValoremClear.AccessControlViolation.selector, address(this), CLEAR_FEE_TO)
        );
        real.setFeesEnabled(true);
        _setRealClearFees(real, true);
        assertTrue(real.feesEnabled());
    }

    /// @dev The constructor refuses a zero admin or generator, so the deploy script cannot pass zero.
    function test_realClear_constructorRefusesZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(IValoremClear.InvalidAddress.selector, address(0)));
        vm.deployCode(CLEAR_ARTIFACT, abi.encode(address(0), CLEAR_URI_GENERATOR));
        vm.expectRevert(abi.encodeWithSelector(IValoremClear.InvalidAddress.selector, address(0)));
        vm.deployCode(CLEAR_ARTIFACT, abi.encode(CLEAR_FEE_TO, address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _order(address offerer, address zone, OrderType t, uint256 n, uint256 unit, ISeaport sp)
        internal
        view
        returns (OrderComponents memory c)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC1155, address(clear), optionId, n, n);
        ConsiderationItem[] memory cons = new ConsiderationItem[](1);
        cons[0] = ConsiderationItem(ItemType.ERC20, address(usdg), 0, unit * n, unit * n, payable(offerer));
        c = OrderComponents({
            offerer: offerer,
            zone: zone,
            offer: offer,
            consideration: cons,
            orderType: t,
            startTime: 0,
            endTime: exerciseTs,
            zoneHash: bytes32(0),
            salt: 0x1234,
            conduitKey: bytes32(0),
            counter: sp.getCounter(offerer)
        });
    }

    function _validateOnMock(OrderComponents memory c) internal {
        Order[] memory orders = new Order[](1);
        orders[0] = Order({parameters: _toParameters(c), signature: ""});
        vm.prank(c.offerer);
        mockSeaport.validate(orders);
    }

    function _assertHookRecord(RecordingZone zone, bytes32 expectedHash) internal view {
        assertEq(zone.authorizeCalls(), 1, "authorize once");
        assertEq(zone.validateCalls(), 1, "validate once");
        assertEq(zone.balanceAtAuthorize(), 20, "authorize ran BEFORE the transfer");
        assertEq(zone.balanceAtValidate(), 15, "validate ran AFTER the transfer");
        assertEq(zone.offerAmountSeen(), 5, "fraction-applied offer amount");
        assertEq(zone.considerationAmountSeen(), 5 * 2_000_000, "fraction-applied consideration");
        assertEq(zone.fulfillerSeen(), buyer, "fulfiller is msg.sender");
        assertEq(zone.orderHashSeen(), expectedHash, "order hash");
        assertEq(zone.hashesAtAuthorize(), 0, "orderHashes truncated to earlier orders in authorize");
        assertEq(zone.hashesAtValidate(), 1, "orderHashes complete in validate");
        assertEq(clear.balanceOf(buyer, optionId), 5);
        assertEq(usdg.balanceOf(seller), 5 * 2_000_000);
    }
}
