// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";

/// @notice A scriptable IPriceSource for the SettlementOracle tests: every answer is set by the test, plus the ways a
///         source can misbehave that the real sources never do.
/// @dev {windowPrice} answers the scripted value only for a span of exactly SETTLEMENT_WINDOW ending at or before now,
///      so a test also proves the oracle asks for `[expiry - SETTLEMENT_WINDOW, expiry]`. {record} returns true once per
///      (underlying, expiry) while `recordable`, and can re-enter a target (the oracle) to prove its guard holds.
///      Modes apply to all four functions: Reverts, ShortReply (31 bytes, fewer than any reply needs) and DirtyOk (the
///      ok word is 2, not a valid ABI bool). {pin} accepts any caller, counts calls, marks {pinned} and answers the
///      IPriceSource.pin selector; it scripts nothing else (a test that needs pinned answers or pin refusals uses the
///      real sources), and {setPinBurnsGas} makes it consume all the gas it is given, as a source that runs out of gas
///      does. Under ShortReply and DirtyOk the pin succeeds but its answer is not the selector.
contract MockOraclePriceSource is IPriceSource {
    enum Mode {
        Normal,
        Reverts,
        ShortReply,
        DirtyOk
    }

    Mode public mode;

    bool public windowOk;
    uint256 public windowAnswer;

    bool public latestOk;
    uint256 public latestAnswer;
    uint256 public latestUpdatedAt;

    bool public recordable;
    uint256 public recordCalls;
    address public reenterTarget;
    bytes public reenterCall;
    mapping(address underlying => mapping(uint40 expiry => bool)) public recorded;

    uint256 public pinCalls;
    bool public pinBurnsGas;
    mapping(address underlying => mapping(uint40 expiry => bool)) public pinned;

    error MockSourceReverted();

    function setPinBurnsGas(bool on) external {
        pinBurnsGas = on;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    /// @notice Scripted `windowPrice` answer (USDG 6 dp per share) for any correctly sized window.
    function setWindow(bool ok, uint256 price) external {
        (windowOk, windowAnswer) = (ok, price);
    }

    /// @notice Scripted `latest` answer.
    function setLatest(bool ok, uint256 price, uint256 updatedAt) external {
        (latestOk, latestAnswer, latestUpdatedAt) = (ok, price, updatedAt);
    }

    function setRecordable(bool on) external {
        recordable = on;
    }

    /// @notice {record} calls `target` with `data` first and bubbles its revert (zero target: off).
    function setReenter(address target, bytes calldata data) external {
        (reenterTarget, reenterCall) = (target, data);
    }

    function latest(address) external view returns (bool ok, uint256 price, uint256 updatedAt) {
        _misbehave(latestAnswer);
        return (latestOk, latestAnswer, latestUpdatedAt);
    }

    function windowPrice(address, uint40 start, uint40 end) external view returns (bool ok, uint256 price) {
        _misbehave(windowAnswer);
        if (uint256(start) + V2Constants.SETTLEMENT_WINDOW != end || end > block.timestamp) return (false, 0);
        return (windowOk, windowAnswer);
    }

    function record(address underlying, uint40 expiry) external returns (bool) {
        _misbehave(0);
        ++recordCalls;
        if (reenterTarget != address(0)) {
            (bool success, bytes memory ret) = reenterTarget.call(reenterCall);
            if (!success) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        if (!recordable || recorded[underlying][expiry]) return false;
        recorded[underlying][expiry] = true;
        return true;
    }

    function pin(address underlying, uint40 expiry) external returns (bytes4) {
        _misbehave(0);
        if (pinBurnsGas) {
            assembly {
                invalid()
            }
        }
        ++pinCalls;
        pinned[underlying][expiry] = true;
        return IPriceSource.pin.selector;
    }

    function _misbehave(uint256 second) private view {
        Mode m = mode;
        if (m == Mode.Reverts) revert MockSourceReverted();
        if (m == Mode.ShortReply) {
            assembly {
                mstore(0, 1)
                return(0, 31)
            }
        }
        if (m == Mode.DirtyOk) {
            assembly {
                mstore(0, 2)
                mstore(0x20, second)
                mstore(0x40, timestamp())
                return(0, 0x60)
            }
        }
    }
}
