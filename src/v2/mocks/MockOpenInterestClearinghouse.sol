// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";

/// @notice The two things SettlementOracle needs from a Clearinghouse, for its tests: a settable
///         `openInterest(underlying, expiry)` (the bounty gate) and a way to call `finalize` as the Clearinghouse does
///         inside `settle`, so the oracle sees this contract as msg.sender.
contract MockOpenInterestClearinghouse {
    mapping(address underlying => mapping(uint40 expiry => uint256 units)) internal _openInterest;
    bool public reverts;

    error MockOpenInterestReverted();

    function setOpenInterest(address underlying, uint40 expiry, uint256 units) external {
        _openInterest[underlying][expiry] = units;
    }

    function setReverts(bool on) external {
        reverts = on;
    }

    /// @notice Sum of long supply over the expiry's series, 0.01-share units (as IClearinghouse.openInterest).
    function openInterest(address underlying, uint40 expiry) external view returns (uint256) {
        if (reverts) revert MockOpenInterestReverted();
        return _openInterest[underlying][expiry];
    }

    /// @notice `oracle.finalize` with this contract as the caller, like Clearinghouse.settle.
    function settleFinalize(ISettlementOracle oracle, address underlying, uint40 expiry)
        external
        returns (bool finalized, uint256 price)
    {
        return oracle.finalize(underlying, expiry);
    }
}
