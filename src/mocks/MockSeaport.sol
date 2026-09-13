// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISeaport, OrderComponents, Order, ConsiderationItem, OfferItem} from "../interfaces/ISeaport.sol";
import {IERC1155Minimal} from "../interfaces/IERC1155Minimal.sol";

/// @notice Stand-in for Seaport 1.6 covering exactly what the vault touches.
/// @dev Implements order hashing, validation, cancellation, the offerer counter, and a
///      `fulfil` helper the tests drive a buyer through. The hash is a plain keccak of the
///      encoded components rather than Seaport's real EIP-712 tree: the vault only ever
///      compares hashes it obtained from this same contract, so the shape of the hash is
///      irrelevant to what is under test. Fork tests exercise the real Seaport.
contract MockSeaport is ISeaport {
    using SafeERC20 for IERC20;

    mapping(address => uint256) internal _counters;
    mapping(bytes32 => bool) public validated;
    mapping(bytes32 => bool) public cancelled;
    mapping(bytes32 => uint256) public filled;
    mapping(bytes32 => uint256) public size;

    bytes32 public immutable domainSeparator;

    error OrderNotValidated();
    error OrderIsCancelled();
    error NotOfferer();
    error InexactFraction();
    error ExceedsRemaining();

    constructor() {
        domainSeparator = keccak256(abi.encode("MockSeaport", block.chainid, address(this)));
    }

    function information() external view returns (string memory, bytes32, address) {
        return ("1.6", domainSeparator, address(0));
    }

    function getCounter(address offerer) external view returns (uint256) {
        return _counters[offerer];
    }

    function incrementCounter() external returns (uint256) {
        return ++_counters[msg.sender];
    }

    function getOrderHash(OrderComponents calldata o) public pure returns (bytes32) {
        return keccak256(abi.encode(o));
    }

    function validate(Order[] calldata orders) external returns (bool) {
        for (uint256 i; i < orders.length; i++) {
            if (orders[i].parameters.offerer != msg.sender) revert NotOfferer();
            bytes32 h = _hashParameters(orders[i], _counters[msg.sender]);
            validated[h] = true;
            size[h] = orders[i].parameters.offer[0].startAmount;
        }
        return true;
    }

    function cancel(OrderComponents[] calldata orders) external returns (bool) {
        for (uint256 i; i < orders.length; i++) {
            if (orders[i].offerer != msg.sender) revert NotOfferer();
            cancelled[keccak256(abi.encode(orders[i]))] = true;
        }
        return true;
    }

    function getOrderStatus(bytes32 orderHash) external view returns (bool, bool, uint256, uint256) {
        return (validated[orderHash], cancelled[orderHash], filled[orderHash], size[orderHash]);
    }

    /// @dev Rebuild the components hash from an Order so `validate` and `cancel` agree.
    function _hashParameters(Order calldata o, uint256 counter) internal pure returns (bytes32) {
        OrderComponents memory c = OrderComponents({
            offerer: o.parameters.offerer,
            zone: o.parameters.zone,
            offer: o.parameters.offer,
            consideration: o.parameters.consideration,
            orderType: o.parameters.orderType,
            startTime: o.parameters.startTime,
            endTime: o.parameters.endTime,
            zoneHash: o.parameters.zoneHash,
            salt: o.parameters.salt,
            conduitKey: o.parameters.conduitKey,
            counter: counter
        });
        return keccak256(abi.encode(c));
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FULFILMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Fill `fillAmount` contracts of a validated order as `msg.sender`.
    /// @dev Moves the ERC-1155 out of the offerer and pays every consideration item pro-rata.
    ///      Enforces the same divisibility rule real Seaport does, which is what makes the
    ///      per-contract fee rounding testable: an order whose consideration does not divide
    ///      by the order size reverts here exactly as it would on chain.
    function fulfil(OrderComponents calldata o, uint256 fillAmount) external {
        bytes32 h = keccak256(abi.encode(o));
        if (!validated[h]) revert OrderNotValidated();
        if (cancelled[h]) revert OrderIsCancelled();

        OfferItem calldata item = o.offer[0];
        uint256 total = item.startAmount;
        if (filled[h] + fillAmount > total) revert ExceedsRemaining();

        for (uint256 i; i < o.consideration.length; i++) {
            ConsiderationItem calldata c = o.consideration[i];
            // Seaport rejects a fraction it cannot express exactly.
            if ((c.startAmount * fillAmount) % total != 0) revert InexactFraction();
            uint256 pay = (c.startAmount * fillAmount) / total;
            if (pay != 0) IERC20(c.token).safeTransferFrom(msg.sender, c.recipient, pay);
        }

        filled[h] += fillAmount;
        IERC1155Minimal(item.token).safeTransferFrom(o.offerer, msg.sender, item.identifierOrCriteria, fillAmount, "");
    }
}
