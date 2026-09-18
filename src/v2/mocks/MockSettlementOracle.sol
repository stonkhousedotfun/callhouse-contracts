// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISettlementOracle} from "../interfaces/ISettlementOracle.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {V2Types} from "../interfaces/V2Types.sol";

/// @notice An ISettlementOracle whose every answer a test sets directly, for the Clearinghouse and OrderBook suites
///         (the real SettlementOracle is C2-04). Prices are USDG base units (6 dp) per whole share.
/// @dev Per (underlying, expiry):
///        - {setSettlement} writes the status and price that {settlementPrice} reports;
///        - {setFinalizeMode} picks what {finalize} does: `Passive` (default) reports the stored state without changing
///          it, `FinalizeOnCall` makes the call itself finalize at a preset price, `Revert` reverts. With
///          `enforceTooEarly` (default on) every mode except `Revert` first reverts TooEarly before expiry +
///          FINALIZE_DELAY, like the real oracle.
///      Per underlying: {setSpot} sets what {spot} / {trySpot} return. Global switches make {trySpot} or
///      {settlementPrice} revert outright, to drive the "oracle broken or absent" paths.
///      {finalizeCalls} counts every finalize that did not revert, so a test can prove settle called it (or did not).
///      {pin} (INTERFACE_VERSION 6) accepts any caller, counts calls in {pinCalls}, marks {pinned} and emits nothing,
///      so the Clearinghouse suites' log assertions are those of the Clearinghouse alone; {setPinReverts} makes it
///      revert NoSource, as the real oracle does for a market without sources.
contract MockSettlementOracle is ISettlementOracle {
    enum FinalizeMode {
        Passive,
        FinalizeOnCall,
        Revert
    }

    struct Entry {
        V2Types.SettlementStatus status;
        uint256 price;
        FinalizeMode mode;
        uint256 finalizePrice;
    }

    struct SpotEntry {
        bool ok;
        uint256 price;
        uint256 updatedAt;
    }

    struct CandidateEntry {
        uint256 price;
        uint8 sourceIndex;
        bool disagreed;
        uint40 finalizableAt;
    }

    mapping(address underlying => mapping(uint40 expiry => Entry)) internal _entries;
    mapping(address underlying => mapping(uint40 expiry => CandidateEntry)) internal _candidates;
    mapping(address underlying => SpotEntry) internal _spots;

    bool public enforceTooEarly = true;
    bool public trySpotReverts;
    bool public settlementPriceReverts;
    uint256 public finalizeCalls;
    uint256 public snapshotCalls;
    uint256 public pinCalls;
    bool public pinReverts;
    mapping(address underlying => mapping(uint40 expiry => bool)) public pinned;

    error MockOracleReverted();

    /*//////////////////////////////////////////////////////////////
                               TEST SETTERS
    //////////////////////////////////////////////////////////////*/

    function setSettlement(address underlying, uint40 expiry, V2Types.SettlementStatus status, uint256 price) external {
        Entry storage e = _entries[underlying][expiry];
        e.status = status;
        e.price = price;
    }

    function setFinalizeMode(address underlying, uint40 expiry, FinalizeMode mode, uint256 finalizePrice) external {
        Entry storage e = _entries[underlying][expiry];
        e.mode = mode;
        e.finalizePrice = finalizePrice;
    }

    function setSpot(address underlying, bool ok, uint256 price, uint256 updatedAt) external {
        _spots[underlying] = SpotEntry(ok, price, updatedAt);
    }

    function setCandidate(
        address underlying,
        uint40 expiry,
        uint256 price,
        uint8 sourceIndex,
        bool disagreed,
        uint40 at
    ) external {
        _candidates[underlying][expiry] = CandidateEntry(price, sourceIndex, disagreed, at);
    }

    function setEnforceTooEarly(bool on) external {
        enforceTooEarly = on;
    }

    function setTrySpotReverts(bool on) external {
        trySpotReverts = on;
    }

    function setSettlementPriceReverts(bool on) external {
        settlementPriceReverts = on;
    }

    function setPinReverts(bool on) external {
        pinReverts = on;
    }

    /*//////////////////////////////////////////////////////////////
                             ISettlementOracle
    //////////////////////////////////////////////////////////////*/

    function SETTLEMENT_WINDOW() external pure returns (uint32) {
        return V2Constants.SETTLEMENT_WINDOW;
    }

    function spot(address underlying) external view returns (uint256 price, uint256 updatedAt) {
        SpotEntry memory s = _spots[underlying];
        if (!s.ok) revert V2Errors.NoSource();
        return (s.price, s.updatedAt);
    }

    function trySpot(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt) {
        if (trySpotReverts) revert MockOracleReverted();
        SpotEntry memory s = _spots[underlying];
        return (s.ok, s.price, s.updatedAt);
    }

    function snapshot(address, uint40) external returns (uint8 newlyRecorded) {
        ++snapshotCalls;
        return 0;
    }

    function finalize(address underlying, uint40 expiry) external returns (bool finalized, uint256 price) {
        Entry storage e = _entries[underlying][expiry];
        if (e.mode == FinalizeMode.Revert) revert MockOracleReverted();
        if (enforceTooEarly && block.timestamp < uint256(expiry) + V2Constants.FINALIZE_DELAY) {
            revert V2Errors.TooEarly(expiry + V2Constants.FINALIZE_DELAY);
        }
        ++finalizeCalls;
        if (e.mode == FinalizeMode.FinalizeOnCall && e.status != V2Types.SettlementStatus.Finalized) {
            e.status = V2Types.SettlementStatus.Finalized;
            e.price = e.finalizePrice;
            emit SettlementFinalized(underlying, expiry, e.price, 0, true);
        }
        if (e.status == V2Types.SettlementStatus.Finalized) return (true, e.price);
        return (false, 0);
    }

    function settlementPrice(address underlying, uint40 expiry)
        external
        view
        returns (V2Types.SettlementStatus status, uint256 price)
    {
        if (settlementPriceReverts) revert MockOracleReverted();
        Entry memory e = _entries[underlying][expiry];
        return (e.status, e.status == V2Types.SettlementStatus.Finalized ? e.price : 0);
    }

    function veto(address underlying, uint40 expiry) external {
        Entry storage e = _entries[underlying][expiry];
        if (e.status == V2Types.SettlementStatus.Finalized) revert V2Errors.AlreadyFinal();
        e.status = V2Types.SettlementStatus.Held;
        emit SettlementVetoed(underlying, expiry);
    }

    function unveto(address underlying, uint40 expiry) external {
        Entry storage e = _entries[underlying][expiry];
        if (e.status == V2Types.SettlementStatus.Finalized) revert V2Errors.AlreadyFinal();
        e.status = V2Types.SettlementStatus.Pending;
        // casting to uint40 is safe for any test clock
        // forge-lint: disable-next-line(unsafe-typecast)
        emit SettlementUnvetoed(underlying, expiry, uint40(block.timestamp));
    }

    function adminResolve(address underlying, uint40 expiry, uint256 price) external {
        Entry storage e = _entries[underlying][expiry];
        if (e.status == V2Types.SettlementStatus.Finalized) revert V2Errors.AlreadyFinal();
        e.status = V2Types.SettlementStatus.Finalized;
        e.price = price;
        emit SettlementResolved(underlying, expiry, price);
    }

    function candidate(address underlying, uint40 expiry)
        external
        view
        returns (uint256 price, uint8 sourceIndex, bool disagreed, uint40 finalizableAt)
    {
        CandidateEntry memory c = _candidates[underlying][expiry];
        return (c.price, c.sourceIndex, c.disagreed, c.finalizableAt);
    }

    function pin(address underlying, uint40 expiry) external {
        if (pinReverts) revert V2Errors.NoSource();
        ++pinCalls;
        pinned[underlying][expiry] = true;
    }
}
