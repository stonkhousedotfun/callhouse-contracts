// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ISeaport, Order, OrderComponents, OrderParameters} from "../../src/interfaces/ISeaport.sol";

/*//////////////////////////////////////////////////////////////
                    SEAPORT 1.6 FULFILMENT TYPES
//////////////////////////////////////////////////////////////*/

/// @dev The fulfilment-side structs the vault never touches but a test driving a buyer through the
///      real Seaport needs. Field order is Seaport 1.6's `ConsiderationStructs.sol`.
struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator;
    bytes signature;
    bytes extraData;
}

struct CriteriaResolver {
    uint256 orderIndex;
    uint8 side;
    uint256 index;
    uint256 identifier;
    bytes32[] criteriaProof;
}

struct FulfillmentComponent {
    uint256 orderIndex;
    uint256 itemIndex;
}

struct Fulfillment {
    FulfillmentComponent[] offerComponents;
    FulfillmentComponent[] considerationComponents;
}

/// @dev Seaport's basic-order route enum, all 24 values in declaration order. The vault's listings are
///      `ERC20_TO_ERC1155_PARTIAL_RESTRICTED` (15): the fulfiller pays ERC20 for the offerer's ERC1155,
///      and `basicOrderType % 4` must equal the order's `orderType` (PARTIAL_RESTRICTED = 3).
enum BasicOrderType {
    ETH_TO_ERC721_FULL_OPEN,
    ETH_TO_ERC721_PARTIAL_OPEN,
    ETH_TO_ERC721_FULL_RESTRICTED,
    ETH_TO_ERC721_PARTIAL_RESTRICTED,
    ETH_TO_ERC1155_FULL_OPEN,
    ETH_TO_ERC1155_PARTIAL_OPEN,
    ETH_TO_ERC1155_FULL_RESTRICTED,
    ETH_TO_ERC1155_PARTIAL_RESTRICTED,
    ERC20_TO_ERC721_FULL_OPEN,
    ERC20_TO_ERC721_PARTIAL_OPEN,
    ERC20_TO_ERC721_FULL_RESTRICTED,
    ERC20_TO_ERC721_PARTIAL_RESTRICTED,
    ERC20_TO_ERC1155_FULL_OPEN,
    ERC20_TO_ERC1155_PARTIAL_OPEN,
    ERC20_TO_ERC1155_FULL_RESTRICTED,
    ERC20_TO_ERC1155_PARTIAL_RESTRICTED,
    ERC721_TO_ERC20_FULL_OPEN,
    ERC721_TO_ERC20_PARTIAL_OPEN,
    ERC721_TO_ERC20_FULL_RESTRICTED,
    ERC721_TO_ERC20_PARTIAL_RESTRICTED,
    ERC1155_TO_ERC20_FULL_OPEN,
    ERC1155_TO_ERC20_PARTIAL_OPEN,
    ERC1155_TO_ERC20_FULL_RESTRICTED,
    ERC1155_TO_ERC20_PARTIAL_RESTRICTED
}

struct AdditionalRecipient {
    uint256 amount;
    address payable recipient;
}

/// @dev Seaport 1.6 `BasicOrderParameters`, field order per `ConsiderationStructs.sol`. On the
///      ERC20_TO_ERC1155 routes the "offer" is the offerer's ERC1155 and the "consideration" the ERC20
///      the fulfiller pays to the offerer; the derived order hash must equal the validated one.
struct BasicOrderParameters {
    address considerationToken;
    uint256 considerationIdentifier;
    uint256 considerationAmount;
    address payable offerer;
    address zone;
    address offerToken;
    uint256 offerIdentifier;
    uint256 offerAmount;
    BasicOrderType basicOrderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 offererConduitKey;
    bytes32 fulfillerConduitKey;
    uint256 totalOriginalAdditionalRecipients;
    AdditionalRecipient[] additionalRecipients;
    bytes signature;
}

/// @dev The Seaport 1.6 errors the write-on-fill tests pin.
interface ISeaportErrors {
    error OrderAlreadyFilled(bytes32 orderHash);
    error OrderPartiallyFilled(bytes32 orderHash);
    error InvalidRestrictedOrder(bytes32 orderHash);
    error InvalidTime(uint256 startTime, uint256 endTime);
    error NoSpecifiedOrdersAvailable();
    error NoReentrantCalls();
    error OrderIsCancelled(bytes32 orderHash);
}

/// @notice The Seaport 1.6 fulfilment entry points a buyer uses.
interface ISeaportFulfil {
    function fulfillOrder(Order calldata order, bytes32 fulfillerConduitKey) external payable returns (bool fulfilled);

    function fulfillBasicOrder(BasicOrderParameters calldata parameters) external payable returns (bool fulfilled);

    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool fulfilled);

    function fulfillAvailableAdvancedOrders(
        AdvancedOrder[] calldata advancedOrders,
        CriteriaResolver[] calldata criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient,
        uint256 maximumFulfilled
    ) external payable returns (bool[] memory availableOrders);

    /// @dev Returns `Execution[]` on chain; declared without a return so the compiler does not try to
    ///      decode it. The tests read the resulting balances instead.
    function matchAdvancedOrders(
        AdvancedOrder[] calldata orders,
        CriteriaResolver[] calldata criteriaResolvers,
        Fulfillment[] calldata fulfillments,
        address recipient
    ) external payable;
}

/// @notice Puts the REAL Seaport 1.6 runtime (and its ConduitController) into the test EVM at the
///         addresses they occupy on Robinhood Chain 4663.
/// @dev WHY ETCH AT THE REAL ADDRESSES. Seaport 1.6 stores the ConduitController as an immutable
///      and derives the conduit code hash from it at construction, so the runtime bytes only make
///      sense with the controller at exactly 0x00000000F9490004C11Cef243f5400493c00Ad63. Its cached
///      EIP-712 domain separator was likewise computed for its own address on chain 4663; Seaport
///      recomputes it whenever `block.chainid` differs from the cached one, so the fixture is
///      correct on any chain id, but {setUp} pins 4663 so hashes and `information()` match mainnet.
///
///      The two runtimes were read from mainnet 4663 with `cast code` (2026-09-13) and are committed
///      under test/fixtures/seaport/. Their keccak hashes are pinned below so a swapped fixture fails
///      loudly; `script/Verify.s.sol` compares the live extcodehash against the same constants.
///
///      The vault never calls a fulfil function itself: tests do, as the buyer, through
///      {ISeaportFulfil}. Helpers below build `AdvancedOrder`s from the vault's `OrderComponents`.
abstract contract RealSeaportBase is Test {
    address internal constant SEAPORT_16 = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant CONDUIT_CONTROLLER = 0x00000000F9490004C11Cef243f5400493c00Ad63;
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    bytes32 internal constant SEAPORT_16_RUNTIME_HASH =
        0x95809b70c9659c30188db5fdd87103e24b1a55379af8c851fca393aba0224a00;
    bytes32 internal constant CONDUIT_CONTROLLER_RUNTIME_HASH =
        0x880348b652e7cce91216153a4d0107e70c77b92192f3d7a127ff1f1351961948;

    ISeaport internal realSeaport = ISeaport(SEAPORT_16);
    ISeaportFulfil internal realSeaportFulfil = ISeaportFulfil(SEAPORT_16);

    /// @notice Etch both runtimes and pin the chain id. Call from `setUp` BEFORE deploying anything
    ///         that reads `seaport.information()`.
    function _installRealSeaport() internal {
        vm.chainId(ROBINHOOD_CHAIN_ID);

        bytes memory seaportCode = vm.parseBytes(vm.readFile("test/fixtures/seaport/Seaport16.runtime.hex"));
        bytes memory controllerCode = vm.parseBytes(vm.readFile("test/fixtures/seaport/ConduitController.runtime.hex"));
        assertEq(keccak256(seaportCode), SEAPORT_16_RUNTIME_HASH, "Seaport 1.6 fixture changed");
        assertEq(keccak256(controllerCode), CONDUIT_CONTROLLER_RUNTIME_HASH, "ConduitController fixture changed");

        vm.etch(CONDUIT_CONTROLLER, controllerCode);
        vm.etch(SEAPORT_16, seaportCode);
        vm.label(SEAPORT_16, "Seaport1.6(real)");
        vm.label(CONDUIT_CONTROLLER, "ConduitController(real)");

        (string memory version,, address controller) = realSeaport.information();
        assertEq(version, "1.6", "Seaport version");
        assertEq(controller, CONDUIT_CONTROLLER, "Seaport conduit controller");
    }

    /*//////////////////////////////////////////////////////////////
                             ORDER HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev `OrderComponents` (what the vault checks and hashes) to `OrderParameters` (what a fill takes).
    function _toParameters(OrderComponents memory c) internal pure returns (OrderParameters memory p) {
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

    /// @dev A fraction `numerator / denominator` of `c`, filled with `signature` (empty for an order
    ///      the offerer pre-validated on chain).
    function _advanced(OrderComponents memory c, uint120 numerator, uint120 denominator, bytes memory signature)
        internal
        pure
        returns (AdvancedOrder memory)
    {
        return AdvancedOrder({
            parameters: _toParameters(c),
            numerator: numerator,
            denominator: denominator,
            signature: signature,
            extraData: ""
        });
    }

    /// @dev The offerer's EIP-712 signature over `c`, for orders that are NOT pre-validated.
    function _signOrder(uint256 privateKey, OrderComponents memory c) internal view returns (bytes memory) {
        bytes32 orderHash = realSeaport.getOrderHash(c);
        (, bytes32 domainSeparator,) = realSeaport.information();
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, orderHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Fill `numerator / denominator` of `c` as `buyer`, tokens to `buyer`.
    function _fulfillAdvanced(address buyer, OrderComponents memory c, uint120 numerator, uint120 denominator)
        internal
        returns (bool ok)
    {
        return _fulfillAdvanced(buyer, c, numerator, denominator, "");
    }

    function _fulfillAdvanced(
        address buyer,
        OrderComponents memory c,
        uint120 numerator,
        uint120 denominator,
        bytes memory signature
    ) internal returns (bool ok) {
        AdvancedOrder memory ao = _advanced(c, numerator, denominator, signature);
        vm.prank(buyer);
        ok = realSeaportFulfil.fulfillAdvancedOrder(ao, new CriteriaResolver[](0), bytes32(0), buyer);
    }
}
