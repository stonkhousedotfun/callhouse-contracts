// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*//////////////////////////////////////////////////////////////
                        SEAPORT 1.6 TYPES
//////////////////////////////////////////////////////////////*/

/// @dev Seaport item categories. Only ERC1155 (offer) and ERC20 (consideration) are used here.
enum ItemType {
    NATIVE,
    ERC20,
    ERC721,
    ERC1155,
    ERC721_WITH_CRITERIA,
    ERC1155_WITH_CRITERIA
}

/// @dev Seaport order categories.
///      FULL_*  = order must be filled in one shot.
///      PARTIAL_* = order may be partially filled.
///      *_RESTRICTED = the zone must approve the fill.
enum OrderType {
    FULL_OPEN,
    PARTIAL_OPEN,
    FULL_RESTRICTED,
    PARTIAL_RESTRICTED,
    CONTRACT
}

struct OfferItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

/// @dev The struct hashed into an order hash. `counter` is the offerer's current
///      Seaport counter; bumping it invalidates every outstanding order at once.
struct OrderComponents {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 counter;
}

/// @dev Same as OrderComponents but with totalOriginalConsiderationItems instead of
///      counter. This is what `validate` and the fulfil paths take.
struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

/*//////////////////////////////////////////////////////////////
                           INTERFACE
//////////////////////////////////////////////////////////////*/

/// @notice The subset of Seaport 1.6 that the vault touches.
/// @dev Deployed on Robinhood Chain 4663 at 0x0000000000000068F116a894984e2DB1123eB395.
interface ISeaport {
    /// @notice Marks orders as validated on-chain so they can be filled with an empty
    ///         signature. The caller must be the offerer.
    function validate(Order[] calldata orders) external returns (bool validated);

    /// @notice Cancels orders. The caller must be the offerer or the zone.
    function cancel(OrderComponents[] calldata orders) external returns (bool cancelled);

    /// @notice Bumps the offerer's counter, invalidating every outstanding order at once.
    function incrementCounter() external returns (uint256 newCounter);

    /// @notice The EIP-712 order hash for the given components.
    function getOrderHash(OrderComponents calldata order) external view returns (bytes32 orderHash);

    /// @notice isValidated / isCancelled / totalFilled / totalSize for an order hash.
    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize);

    /// @notice The offerer's current counter.
    function getCounter(address offerer) external view returns (uint256 counter);

    /// @notice Version string, EIP-712 domain separator, and conduit controller address.
    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);
}

/// @notice Minimal ConduitController surface: resolve a conduit key to its conduit address.
interface IConduitController {
    function getConduit(bytes32 conduitKey) external view returns (address conduit, bool exists);
}
