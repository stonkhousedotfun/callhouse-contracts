// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IClearinghouse} from "../interfaces/IClearinghouse.sol";

/// @title MockFundingSource
/// @notice Test double for the OrderBook's INTERFACE_VERSION 8 pre-fund stage ({IFundingSource}). One instance plays
///         every behaviour the book must survive: an honest full delivery, a partial one, an over-delivery, a revert,
///         a gas drain that exhausts `V2Constants.FUNDING_GAS` / `FUNDABLE_READ_GAS`, short return data, a
///         reentry attempt (against the book while its guard is held, or at any target a test names with
///         {setReenterTarget}), and a NET WITHDRAWAL that returns normally.
/// @dev NOT declared `is IFundingSource` and {fundable} is NOT `view`, deliberately, exactly as
///      {MockFeeDiscount} is not `is IFeeDiscount` (src/v2/mocks/MockFeeDiscount.sol:12-16): a `view`
///      implementation could not ATTEMPT a state change, and attempting one is precisely what the Reenter probe
///      exists to prove impossible. The signatures are identical, so the selectors the book binds to are the
///      interface's, and `IFundingSource(address(mock))` is all any wiring needs.
///
///      THE ONLY THING THE BOOK EVER MEASURES IS THE `free` DELTA. {IFundingSource} says so twice
///      (src/v2/interfaces/IFundingSource.sol:15-21, :39-43): delivery is the source's Clearinghouse `free`
///      delta, never the call's return and never {fundable}'s claim. Every mode here is therefore written to be
///      judged by that delta, and the self-test asserts it that way rather than trusting a return value.
///
///      A funding source deposits into its OWN ledger account (`to == address(this)`), never to the book, the
///      taker or a third party — IFundingSource.sol:27-29. Locked collateral never leaves the Clearinghouse.
contract MockFundingSource {
    enum Mode {
        Honest,
        Partial,
        Revert,
        GasDrain,
        Garbage,
        Reenter,
        Over,
        /// @dev F-CT3-01 (ops/audit/CT3-ORACLE-MOCKS-LEGACY.md:37-77). Returns NORMALLY having LOWERED this
        ///      source's own `free` balance -- the one input {OrderBook._preFund} saturates for, and the one no
        ///      mode here could express. Appended, never inserted: the six values above are the ones existing
        ///      tests write as literals.
        Drain
    }

    /// @dev Gas the Reenter probe in {fundable} holds back so the double can still answer after the refused write.
    ///      A write inside a static context is an EXCEPTIONAL HALT, which burns everything the inner frame was
    ///      given, and an uncapped call gives it 63/64 of what is left (EIP-150). Under the book's 50,000
    ///      `V2Constants.FUNDABLE_READ_GAS` the 1/64 that came back could not pay for the cold SLOAD of
    ///      `fundableAmount`, so the whole read ran out of gas and the self-test's "the double still answers"
    ///      failed on gas rather than on the property it asserts (T-454, measured: an uncapped probe still ran out
    ///      of gas under a 150,000 cap and first answered under 170,000). Forwarding all but this reserve still
    ///      hands the reentry target tens of thousands of gas, far more than it needs to reach its write.
    uint256 internal constant REENTER_ANSWER_RESERVE = 10_000;

    /// @dev Honest is enum value 0, so a freshly deployed double behaves.
    Mode public mode;
    /// @dev Partial: the share of `amount` actually deposited, in basis points. 10_000 (all of it) by default, so
    ///      Partial with no `setDeliverBps` is still a legal — if pointless — full delivery.
    uint16 public deliverBps;
    /// @dev What {fundable} reports in every mode but Garbage (short data) and GasDrain (out of gas).
    uint256 public fundableAmount;
    /// @dev Drain: how much of its own `free` this source withdraws inside {fund}. It must already hold at
    ///      least this much free collateral, or the withdrawal reverts and the mode degrades into Revert.
    uint256 public drainAmount;
    /// @dev The book: the default target of the Reenter probes (see {reenterTarget}).
    address public book;
    IClearinghouse public ch;
    /// @dev Raw calldata the Reenter mode fires at {reenterTarget}, so a test can aim at `place`, `cancel` or `take`
    ///      without this double knowing the book's ABI.
    bytes public reenterCalldata;
    /// @dev T-470. An explicit Reenter target; zero -- the default -- means `book`. Until this existed the probes
    ///      could ONLY hit the book, so calldata meant for another contract (a Clearinghouse `deposit`) landed on
    ///      the book, reverted there as an unknown selector, was swallowed, and the test it served passed without
    ///      re-entering anything. Zero-means-book rather than a copy of `book` so that every existing test, including
    ///      one that calls {setBook} after this is set, still aims at the book.
    address internal _reenterAt;

    constructor(IClearinghouse ch_) {
        ch = ch_;
        deliverBps = 10_000;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setDeliverBps(uint16 bps) external {
        deliverBps = bps;
    }

    function setFundable(uint256 amount) external {
        fundableAmount = amount;
    }

    /// @notice How much of its own `free` the Drain mode withdraws inside {fund}.
    function setDrainAmount(uint256 amount) external {
        drainAmount = amount;
    }

    function setBook(address book_) external {
        book = book_;
    }

    function setReenterCalldata(bytes calldata data) external {
        reenterCalldata = data;
    }

    /// @notice Aim the Reenter probes at `target` instead of the book. `address(0)` restores the default.
    function setReenterTarget(address target) external {
        _reenterAt = target;
    }

    /// @notice Where the Reenter probes fire: the target set by {setReenterTarget}, or `book` if none was.
    function reenterTarget() public view returns (address) {
        address at = _reenterAt;
        return at == address(0) ? book : at;
    }

    /// @notice Max-approve the Clearinghouse for `asset`, so {fund} can deposit what this source holds.
    function approveClearinghouse(address asset) external {
        IERC20(asset).approve(address(ch), type(uint256).max);
    }

    /// @notice Make `operator` this source's Clearinghouse operator, so the book can mint FOR this maker.
    /// @dev Forwards to {IClearinghouse.setOperator} (src/v2/interfaces/IClearinghouse.sol:264). The book's
    ///      `_reserveCollateral` requires `isOperator(writer, book)`, so a funded maker that never calls this is
    ///      skipped for a reason that has nothing to do with funding.
    function setOperator(address operator, bool approved) external {
        ch.setOperator(operator, approved);
    }

    /// @notice What this source claims it could deliver.
    /// @dev Same selector as {IFundingSource.fundable}, and deliberately NOT `view`. The book reads it as a
    ///      staticcall capped at `V2Constants.FUNDABLE_READ_GAS`; a revert, an out-of-gas or short return data
    ///      counts as 0 (IFundingSource.sol:32-34). Under Reenter this attempts a write inside that static
    ///      context and is EXPECTED to fail at the EVM level whatever this contract is allowed to do — which is
    ///      the point of the probe, and the same argument MockFeeDiscount.sol:63-66 makes.
    function fundable(address asset) external returns (uint256) {
        asset; // the double answers the same for every asset; named for signature parity with the interface
        if (mode == Mode.Revert) revert("MockFundingSource: forced revert");
        if (mode == Mode.Garbage) {
            // 16 bytes: shorter than one word, which a caller copying one word reads as 0.
            assembly {
                return(0x00, 0x10)
            }
        }
        if (mode == Mode.GasDrain) {
            // Runs out of the 50,000 gas cap; the caller reads that as 0.
            uint256 burn = type(uint256).max;
            while (burn != 0) --burn;
        }
        if (mode == Mode.Reenter) {
            // A state-changing call inside a staticcall reverts at the EVM level (the static flag forbids the
            // write), whatever this contract is allowed to do; caught, and the double still answers -- which it
            // can only do if the refused frame did not take the gas the answer needs. See REENTER_ANSWER_RESERVE.
            // Target and calldata are loaded BEFORE gasleft() is sampled: their cold SLOADs would otherwise be
            // paid out of the reserve.
            address target = reenterTarget();
            bytes memory data = reenterCalldata;
            uint256 g = gasleft();
            (bool ok,) = target.call{gas: g > REENTER_ANSWER_RESERVE ? g - REENTER_ANSWER_RESERVE : 0}(data);
            ok;
        }
        return fundableAmount;
    }

    /// @notice Deposit up to `amount` of `asset` into THIS source's own Clearinghouse ledger.
    /// @dev Same selector as {IFundingSource.fund}. The book calls it inside `try` with
    ///      `V2Constants.FUNDING_GAS`; under-delivery and reverts are allowed and cost only this maker's fills
    ///      (IFundingSource.sol:40-43).
    function fund(address asset, uint256 amount) external {
        if (mode == Mode.Revert) revert("MockFundingSource: forced revert");
        if (mode == Mode.GasDrain) {
            uint256 burn = type(uint256).max;
            while (burn != 0) --burn;
        }
        if (mode == Mode.Garbage) {
            // Returns data from a function the interface declares as returning none, and deposits NOTHING. A
            // caller that believed the return instead of the `free` delta would credit a delivery that never
            // happened.
            assembly {
                mstore(0x00, 0xdeadbeef)
                return(0x00, 0x20)
            }
        }
        if (mode == Mode.Reenter) {
            // Fired while the book's reentrancy guard is held for the whole take; the catch is what lets the
            // double go on to deliver honestly, so a test sees the reentry refused AND the funding succeed. Aimed
            // elsewhere (e.g. the Clearinghouse, which that guard does not cover), the call may land; any delivery
            // it makes into this source's own ledger is part of the `free` delta the book measures.
            (bool ok,) = reenterTarget().call(reenterCalldata);
            ok;
        }

        if (mode == Mode.Drain) {
            // F-CT3-01. Deposits NOTHING and takes its own collateral out, then returns normally -- so the book
            // sees a successful `fund` whose `free` delta is NEGATIVE. The book's guard is held for the whole
            // take but does not cover the Clearinghouse, so `withdraw` is reachable from here; that is the
            // reachability argument OrderBook.sol:881-886 makes, and this is the mode that exercises it.
            // Returning early is the point: any deposit after this would net the delta back up.
            ch.withdraw(asset, drainAmount, address(this));
            return;
        }

        uint256 give = amount;
        if (mode == Mode.Partial) give = (amount * deliverBps) / 10_000;
        if (mode == Mode.Over) {
            // More than asked. The book must not revert and must report the true, larger delta.
            uint256 held = IERC20(asset).balanceOf(address(this));
            give = amount * 2 > held ? held : amount * 2;
        }
        ch.deposit(asset, give, address(this));
    }
}
