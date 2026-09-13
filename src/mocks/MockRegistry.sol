// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOvercallRegistry} from "../interfaces/IOvercallRegistry.sol";

/// @notice Stand-in for OvercallRegistry, matching the deployed contract's real surface.
/// @dev Mirrors the live semantics recon confirmed on chain 4663:
///      `isCycleLive()` is `now < expiry`, `writeDeadline()` IS `exerciseTimestamp`, and
///      `isWritingOpen()` is `cycleNumber != 0 && now < writeDeadline()`. There is no status
///      enum; the real registry does not have one.
contract MockRegistry is IOvercallRegistry {
    address public collateralToken;
    address public exerciseToken;
    address public clearinghouse;
    address public owner;
    address public pendingOwner;

    uint96 public lotSize = 1e18;
    uint32 public cycleNumber;
    uint40 public exerciseTimestamp;
    uint40 public expiryTimestamp;
    uint96 internal _cycleLotSize = 1e18;

    uint256[] internal _optionIds;
    mapping(uint256 => uint96) internal _strike;
    mapping(uint256 => bool) internal _approved;
    mapping(uint256 => uint32) internal _cycleOf;

    Cycle[] internal _history;

    constructor(address collateral, address exercise, address clear) {
        collateralToken = collateral;
        exerciseToken = exercise;
        clearinghouse = clear;
        owner = msg.sender;
    }

    function MAX_STRIKES() external pure returns (uint256) {
        return 5;
    }

    function MIN_EXERCISE_WINDOW() external pure returns (uint256) {
        return 1 days;
    }

    /// @notice Test helper: install a cycle with explicit strikes.
    function setCycleWithStrikes(uint256[] calldata ids, uint96[] calldata strikes, uint40 exerciseAt, uint40 expireAt)
        external
    {
        for (uint256 i; i < _optionIds.length; i++) {
            _approved[_optionIds[i]] = false;
        }
        delete _optionIds;

        cycleNumber += 1;
        exerciseTimestamp = exerciseAt;
        expiryTimestamp = expireAt;
        _cycleLotSize = lotSize;

        for (uint256 i; i < ids.length; i++) {
            _optionIds.push(ids[i]);
            _strike[ids[i]] = strikes[i];
            _approved[ids[i]] = true;
            _cycleOf[ids[i]] = cycleNumber;
        }

        _history.push(
            Cycle({
                number: cycleNumber,
                exerciseTimestamp: exerciseAt,
                expiryTimestamp: expireAt,
                lotSize: _cycleLotSize,
                optionIds: _optionIds
            })
        );

        emit CycleSet(cycleNumber, _optionIds, exerciseAt, expireAt, _cycleLotSize);
    }

    function setCycle(uint256[] calldata, uint40, uint40) external pure {
        revert("use setCycleWithStrikes");
    }

    function setLotSize(uint96 newLotSize) external {
        emit LotSizeSet(lotSize, newLotSize);
        lotSize = newLotSize;
    }

    function cycleLotSize() external view returns (uint96) {
        return _cycleLotSize;
    }

    function writeDeadline() public view returns (uint40) {
        return exerciseTimestamp;
    }

    function isWritingOpen() external view returns (bool) {
        return cycleNumber != 0 && block.timestamp < writeDeadline();
    }

    function isCycleLive() public view returns (bool) {
        return block.timestamp < expiryTimestamp;
    }

    function canReplaceCycle() external view returns (bool) {
        return cycleNumber == 0 || block.timestamp >= expiryTimestamp;
    }

    function isApproved(uint256 optionId) external view returns (bool) {
        return _approved[optionId];
    }

    function cycleOf(uint256 optionId) external view returns (uint32) {
        return _cycleOf[optionId];
    }

    function activeOptionIds() external view returns (uint256[] memory) {
        return _optionIds;
    }

    function cycle() external view returns (Cycle memory) {
        return Cycle({
            number: cycleNumber,
            exerciseTimestamp: exerciseTimestamp,
            expiryTimestamp: expiryTimestamp,
            lotSize: _cycleLotSize,
            optionIds: _optionIds
        });
    }

    function cycleCount() external view returns (uint256) {
        return _history.length;
    }

    function cycleAt(uint256 index) external view returns (Cycle memory) {
        return _history[index];
    }

    function strikePerContract(uint256 optionId) external view returns (uint96) {
        return _strike[optionId];
    }

    function transferOwnership(address n) external {
        pendingOwner = n;
    }

    function acceptOwnership() external {
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function renounceOwnership() external pure {
        revert("RenounceDisabled");
    }
}
