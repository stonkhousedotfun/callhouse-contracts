// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFeeDiscount} from "../interfaces/IFeeDiscount.sol";
import {OrderBook} from "../OrderBook.sol";

/// @title MockFeeDiscount
/// @notice Test double for the OrderBook's INTERFACE_VERSION 8 discount seam ({IFeeDiscount}). One instance plays
///         every behaviour the book must survive: an honest fixed rate, a forced revert, short return data, a gas
///         drain that exhausts DISCOUNT_READ_GAS, and a state-changing reentry attempt (which the book's staticcall
///         context makes impossible, so the take must proceed anyway). `bps` above MAX_DISCOUNT_BPS exercises the
///         book's clamp.
/// @dev NOT declared `is IFeeDiscount` and NOT `view`, deliberately: a view implementation could not ATTEMPT a state
///      change, and attempting one is exactly what the Reenter probe is for. The function signature is identical, so
///      the selector the book's staticcall binds to is the interface's; `setDiscountModule(IFeeDiscount(address))`
///      only ever needs the address.
contract MockFeeDiscount {
    enum Mode {
        Fixed,
        Revert,
        Short,
        GasDrain,
        Reenter
    }

    Mode public mode = Mode.Fixed;
    /// @dev Deliberately wider than uint16 so a test can answer above MAX_DISCOUNT_BPS (5,000) and watch the clamp.
    uint256 public bps;
    OrderBook public book;

    constructor(uint256 bps_) {
        bps = bps_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setBps(uint256 b) external {
        bps = b;
    }

    function setBook(OrderBook book_) external {
        book = book_;
    }

    /// @dev Same selector as {IFeeDiscount.discountBps}. The book calls it as a gas-capped staticcall; the Reenter
    ///      branch relies on the static context that call creates to defeat the state-changing attempt.
    function discountBps(address) external returns (uint16) {
        if (mode == Mode.Revert) revert("MockFeeDiscount: forced revert");
        if (mode == Mode.Short) {
            // 16 bytes: shorter than one word, which the book reads as 0.
            assembly {
                return(0x00, 0x10)
            }
        }
        if (mode == Mode.GasDrain) {
            // Runs out of the 30,000 gas cap; the book reads that as 0.
            uint256 burn = type(uint256).max;
            while (burn != 0) --burn;
        }
        if (mode == Mode.Reenter) {
            // A state-changing call inside the book's staticcall reverts at the EVM level (the static flag forbids
            // the write), whatever role the mock holds; caught, and the mock still answers.
            try book.setTradingPaused(true) {} catch {}
        }
        return bps > type(uint16).max ? type(uint16).max : uint16(bps);
    }
}
