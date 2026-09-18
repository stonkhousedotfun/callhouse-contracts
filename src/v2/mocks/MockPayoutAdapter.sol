// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPayoutAdapter} from "../interfaces/IPayoutAdapter.sol";

/// @notice An IPayoutAdapter that behaves well or badly on demand, for the Clearinghouse's USDG payout conversion
///         (ADR-11). It pays USDG from its own balance, so a test funds it first.
/// @dev Price model: `out = amountIn * usdgPerShare / 1e18 * rateBps / 1e4`, i.e. `usdgPerShare` (USDG base units per
///      whole 18-dp share) scaled by `rateBps` (10_000 = a fair rate, below it a bad rate). Modes:
///        - `Good`: pulls `amountIn`, pays `out`. With `enforceMinOut` it reverts below `minOut` like a real router;
///          without it a bad rate is delivered, so the Clearinghouse's own check is what stops it.
///        - `Revert`: reverts before touching anything.
///        - `PullNoPay`: pulls `amountIn`, pays nothing (keeps the stock).
///        - `PullPartial`: pulls half of `amountIn`, pays the full `out`.
///        - `StealExtra`: first tries to pull `amountIn + 1` and `2 * amountIn` (both must fail: the approval is
///          exactly `amountIn`), then behaves like `Good`, then tries one more base unit (must fail too). The attempts
///          are recorded in {stealAttempts} / {stealSucceeded}.
///        - `Reenter`: calls {reenterTarget} with {reenterData} (e.g. Clearinghouse.redeem or convertPayout), records
///          whether it succeeded and its revert data, then behaves like `Good`.
///      Every call records its arguments for assertions ({lastAmountIn}, {lastMinOut}, {lastTo}, {calls}).
///
///      {routeFeeBps} (INTERFACE_VERSION 6) answers per {feeMode}:
///        - `Word`: returns {routeFeeWord} as one ABI word, including values that do not fit uint16 (default 0);
///        - `Revert`: reverts;
///        - `Short`: returns one byte instead of a word;
///        - `BurnGas`: loops until it runs out of gas.
contract MockPayoutAdapter is IPayoutAdapter {
    using SafeERC20 for IERC20;

    enum Mode {
        Good,
        Revert,
        PullNoPay,
        PullPartial,
        StealExtra,
        Reenter
    }

    enum FeeMode {
        Word,
        Revert,
        Short,
        BurnGas
    }

    IERC20 public immutable usdg;

    Mode public mode;
    FeeMode public feeMode;
    uint256 public routeFeeWord;
    uint256 public usdgPerShare;
    uint256 public rateBps = 10_000;
    bool public enforceMinOut;

    address public reenterTarget;
    bytes public reenterData;
    bool public reenterSucceeded;
    bytes public reenterRevertData;

    uint256 public stealAttempts;
    bool public stealSucceeded;

    uint256 public calls;
    address public lastAsset;
    uint256 public lastAmountIn;
    uint256 public lastMinOut;
    address public lastTo;

    error MockAdapterReverted();
    error MockAdapterBelowMinOut(uint256 out, uint256 minOut);

    constructor(IERC20 usdg_, uint256 usdgPerShare_) {
        usdg = usdg_;
        usdgPerShare = usdgPerShare_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setRate(uint256 usdgPerShare_, uint256 rateBps_) external {
        usdgPerShare = usdgPerShare_;
        rateBps = rateBps_;
    }

    function setRouteFee(FeeMode m, uint256 word) external {
        feeMode = m;
        routeFeeWord = word;
    }

    function setEnforceMinOut(bool on) external {
        enforceMinOut = on;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    /// @notice USDG base units a swap of `amountIn` underlying base units pays at the configured rate.
    function quote(uint256 amountIn) public view returns (uint256) {
        return amountIn * usdgPerShare / 1e18 * rateBps / 10_000;
    }

    function swapToUsdg(address asset, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out) {
        ++calls;
        lastAsset = asset;
        lastAmountIn = amountIn;
        lastMinOut = minOut;
        lastTo = to;

        Mode m = mode;
        if (m == Mode.Revert) revert MockAdapterReverted();
        if (m == Mode.PullNoPay) {
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amountIn);
            return 0;
        }
        if (m == Mode.PullPartial) {
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amountIn / 2);
            return _pay(amountIn, minOut, to);
        }
        if (m == Mode.StealExtra) {
            _trySteal(asset, amountIn + 1);
            _trySteal(asset, amountIn * 2);
        }
        if (m == Mode.Reenter) {
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            reenterSucceeded = ok;
            reenterRevertData = ret;
        }
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amountIn);
        out = _pay(amountIn, minOut, to);
        if (m == Mode.StealExtra) _trySteal(asset, 1);
    }

    function routeFeeBps(address) external view returns (uint16) {
        FeeMode m = feeMode;
        if (m == FeeMode.Revert) revert MockAdapterReverted();
        uint256 word = routeFeeWord;
        if (m == FeeMode.Short) {
            assembly ("memory-safe") {
                mstore(0x00, word)
                return(0x1f, 0x01)
            }
        }
        if (m == FeeMode.BurnGas) {
            assembly ("memory-safe") {
                for {} 1 {} {
                    word := add(word, 1)
                }
            }
        }
        assembly ("memory-safe") {
            mstore(0x00, word)
            return(0x00, 0x20)
        }
    }

    function _pay(uint256 amountIn, uint256 minOut, address to) private returns (uint256 out) {
        out = quote(amountIn);
        if (enforceMinOut && out < minOut) revert MockAdapterBelowMinOut(out, minOut);
        usdg.safeTransfer(to, out);
    }

    function _trySteal(address asset, uint256 amount) private {
        ++stealAttempts;
        (bool ok, bytes memory ret) =
            asset.call(abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) stealSucceeded = true;
    }
}
