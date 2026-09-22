// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {MockClearinghouse} from "../../../src/v2/mocks/MockClearinghouse.sol";
import {OrderBookFeeDelayTest} from "../unit/OrderBookFeeDelay.t.sol";
import {OrderBookFuzzTest} from "../unit/OrderBookFuzz.t.sol";
import {OrderBookLogsTest} from "../unit/OrderBookLogs.t.sol";
import {OrderBookMintFeeTest} from "../unit/OrderBookMintFee.t.sol";
import {OrderBookOrdersTest} from "../unit/OrderBookOrders.t.sol";
import {OrderBookPreFundTest} from "../unit/OrderBookPreFund.t.sol";
import {OrderBookTakeTest} from "../unit/OrderBookTake.t.sol";

/// @notice Every OrderBook suite of C2-06 again, over the REAL Clearinghouse instead of MockClearinghouse.
/// @dev C2-06 argued the book against a mock that copies the Clearinghouse on the paths the book touches. Rerunning
///      the unmodified suites here turns each of those copied assumptions into a test of the real contract:
///        - mint's check order (writer or operator, series, market enabled, mint pause, cutoff, units, receiver,
///          collateral) and InsufficientCollateral(have, need), which the book's plan must predict exactly;
///        - mint's log order TransferSingle(long), TransferSingle(short), Minted with the acceptance callbacks last,
///          so a refusing receiver reverts the mint and the book skips the fill (OrderBookLogs, OrderBookTake);
///        - the receiver hook's operator and caller for the book's escrow transfers (the book accepts only
///          operator == book, msg.sender == Clearinghouse);
///        - the redeem rule: holder, holder's operator, or anyone unless the holder opted out, so nobody can redeem
///          the book's escrow (ThirdPartyRedeemDisabled), and redeemBatch skipping it;
///        - settle over the series' pinned oracle, and tokens staying transferable after settlement.
///      The real Clearinghouse is deployed by the same (admin, usdg, calendar, feeRecipient, baseUri) constructor and
///      addressed through the MockClearinghouse type: every selector the suites call exists on both with the same
///      signature. The only extra behaviour the real contract has (payout adapter, keeper bounties) is unset here,
///      exactly as in the mock.
///      INTERFACE_VERSION 7 adds one more copied assumption to check: the collateral rent {Clearinghouse.mint} charges
///      on top of the collateral, which the book's budget must predict to the base unit ({OrderBookMintFeeTest}); the
///      mock's `mintFee` / `mintFeesHeld` mirror it, and this run is what proves the mirror honest.
contract OrderBookOrdersRealClearinghouseTest is OrderBookOrdersTest {
    function _deployClearinghouse() internal override returns (MockClearinghouse) {
        return
            MockClearinghouse(
                address(new Clearinghouse(address(manager), address(usdg), address(calendar), chFees, ""))
            );
    }
}

/// @notice OrderBookTakeTest over the real Clearinghouse (see {OrderBookOrdersRealClearinghouseTest}).
contract OrderBookTakeRealClearinghouseTest is OrderBookTakeTest {
    function _deployClearinghouse() internal override returns (MockClearinghouse) {
        return
            MockClearinghouse(
                address(new Clearinghouse(address(manager), address(usdg), address(calendar), chFees, ""))
            );
    }
}

/// @notice OrderBookLogsTest over the real Clearinghouse (see {OrderBookOrdersRealClearinghouseTest}).
contract OrderBookLogsRealClearinghouseTest is OrderBookLogsTest {
    function _deployClearinghouse() internal override returns (MockClearinghouse) {
        return
            MockClearinghouse(
                address(new Clearinghouse(address(manager), address(usdg), address(calendar), chFees, ""))
            );
    }
}

/// @notice OrderBookFuzzTest over the real Clearinghouse (see {OrderBookOrdersRealClearinghouseTest}).
contract OrderBookFuzzRealClearinghouseTest is OrderBookFuzzTest {
    function _deployClearinghouse() internal override returns (MockClearinghouse) {
        return
            MockClearinghouse(
                address(new Clearinghouse(address(manager), address(usdg), address(calendar), chFees, ""))
            );
    }
}

/// @notice OrderBookFeeDelayTest over the real Clearinghouse (see {OrderBookOrdersRealClearinghouseTest}).
contract OrderBookFeeDelayRealClearinghouseTest is OrderBookFeeDelayTest {
    function _deployClearinghouse() internal override returns (MockClearinghouse) {
        return
            MockClearinghouse(
                address(new Clearinghouse(address(manager), address(usdg), address(calendar), chFees, ""))
            );
    }
}

/// @notice OrderBookMintFeeTest over the real Clearinghouse (see {OrderBookOrdersRealClearinghouseTest}): the c05
///         budget is planned against the contract that actually charges the rent, not against the mock's copy of it.
contract OrderBookMintFeeRealClearinghouseTest is OrderBookMintFeeTest {
    function _deployClearinghouse() internal override returns (MockClearinghouse) {
        return
            MockClearinghouse(
                address(new Clearinghouse(address(manager), address(usdg), address(calendar), chFees, ""))
            );
    }
}

/// @notice OrderBookPreFundTest over the real Clearinghouse: the feature is "money arrives in the real ledger
///         before planning", and the mock's `free` is a plain mapping.
contract OrderBookPreFundRealClearinghouseTest is OrderBookPreFundTest {
    function _deployClearinghouse() internal override returns (MockClearinghouse) {
        return
            MockClearinghouse(
                address(new Clearinghouse(address(manager), address(usdg), address(calendar), chFees, ""))
            );
    }
}
