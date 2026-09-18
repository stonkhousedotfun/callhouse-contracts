// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniV3PoolFactory, IUniV3SwapRouter02} from "../periphery/PayoutDeps.sol";

/// @notice A SwapRouter02 stand-in (router and pool in one) for the UniV3PayoutAdapter suites. It pays the output token
///         from its own balance, so a test funds it first, and keeps the input it pulls.
/// @dev Price model: `out = amountUsed * pricePerShare[tokenIn] / 1e18 * rateBps / 1e4`, i.e. output base units per
///      whole 18-dp input share, scaled by `rateBps` (10_000 = fair, below it a bad rate).
///      Like the real router it reverts when the factory has no pool for (tokenIn, tokenOut, fee), maps the recipient
///      sentinels address(1) -> msg.sender and address(2) -> itself, pays the output before pulling the input (the
///      pool's callback order), and reverts with the router's own string "Too little received" below
///      amountOutMinimum. Modes:
///        - `Good`: the above.
///        - `IgnoreMinOut`: pays below amountOutMinimum without reverting (a broken router; the adapter must catch it).
///        - `Partial`: consumes and prices only half of amountIn, as a pool that ran out of in-range liquidity.
///        - `PayElsewhere`: sends the output to {elsewhere} instead of the recipient.
///        - `Revert`: reverts before touching anything.
///        - `Reenter`: calls {reenterTarget} with {reenterData} first, records the outcome, then behaves like `Good`.
///      Every call records its parameters ({lastParams}, {calls}).
contract MockPayoutSwapRouter is IUniV3SwapRouter02 {
    using SafeERC20 for IERC20;

    enum Mode {
        Good,
        IgnoreMinOut,
        Partial,
        PayElsewhere,
        Revert,
        Reenter
    }

    address public immutable factory;

    Mode public mode;
    uint256 public rateBps = 10_000;
    mapping(address tokenIn => uint256) public pricePerShare;
    address public elsewhere;

    address public reenterTarget;
    bytes public reenterData;
    bool public reenterAttempted;
    bool public reenterSucceeded;
    bytes public reenterRevertData;

    uint256 public calls;
    ExactInputSingleParams internal _last;

    error MockRouterReverted();
    error MockRouterNoPool();

    constructor(address factory_) {
        factory = factory_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setPrice(address tokenIn, uint256 outPerShare) external {
        pricePerShare[tokenIn] = outPerShare;
    }

    function setRateBps(uint256 bps) external {
        rateBps = bps;
    }

    function setElsewhere(address to) external {
        elsewhere = to;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function lastParams() external view returns (ExactInputSingleParams memory) {
        return _last;
    }

    /// @notice Output base units for `amountIn` input base units at the configured price and rate.
    function quote(address tokenIn, uint256 amountIn) public view returns (uint256) {
        return amountIn * pricePerShare[tokenIn] / 1e18 * rateBps / 10_000;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        ++calls;
        _last = p;
        Mode m = mode;
        if (m == Mode.Revert) revert MockRouterReverted();
        if (IUniV3PoolFactory(factory).getPool(p.tokenIn, p.tokenOut, p.fee) == address(0)) revert MockRouterNoPool();
        if (m == Mode.Reenter) {
            reenterAttempted = true;
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            reenterSucceeded = ok;
            reenterRevertData = ret;
        }

        address recipient = p.recipient;
        if (recipient == address(1)) recipient = msg.sender;
        else if (recipient == address(2)) recipient = address(this);
        if (m == Mode.PayElsewhere) recipient = elsewhere;

        uint256 used = m == Mode.Partial ? p.amountIn / 2 : p.amountIn;
        amountOut = quote(p.tokenIn, used);
        IERC20(p.tokenOut).safeTransfer(recipient, amountOut);
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), used);
        if (m != Mode.IgnoreMinOut) require(amountOut >= p.amountOutMinimum, "Too little received");
    }
}
