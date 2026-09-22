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
///      SPOT STALENESS (T-OP-070, modelling SettlementOracle._spot after T-OP-061). By default a set spot is fresh for
///      ever, exactly as before. {setSpotRule} gives an underlying the real oracle's three-step rule -- an outer
///      `spotMaxAge` (0 = no outer bound), the 30-minute SPOT_CORROBORATION_AGE, and a modelled source-1 witness set by
///      {setSpotWitness} that must agree within `maxDeviationBps` when the print is older than 30 minutes -- and
///      {setSpotStale} is the blunt switch. A stale spot makes {spot} revert StaleSpot(updatedAt) and {trySpot}
///      answer (false, 0, 0), as the real oracle does.
///      HELD (T-OP-070, modelling SettlementOracle._advance). `FinalizeOnCall` on a Held expiry finalizes only when
///      {setCorroborated} marked it corroborated: the real chain finalizes a corroborated expiry whatever its status
///      and returns (false, 0) from a Held uncorroborated one. Default not corroborated, so a vetoed expiry now stays
///      Held until {unveto}, which is the behaviour a veto test means to assert.
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

    /// @dev The real oracle's spot rule, per underlying (SettlementOracle._spot, T-OP-061). All-zero = the pre-T-OP-070
    ///      mock: a set spot is fresh for ever.
    struct SpotRule {
        uint32 spotMaxAge; // outer bound, seconds; 0 = none
        uint16 maxDeviationBps; // the agreement band the witness must meet
        bool witnessOk; // source 1 modelled as answering ok
        uint256 witnessPrice; // source 1's price
        bool forceStale; // {setSpotStale}: stale whatever the clock says
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
    mapping(address underlying => SpotRule) internal _spotRules;
    /// @dev {finalize} in FinalizeOnCall mode finalizes a Held expiry only when this is set (T-OP-070).
    mapping(address underlying => mapping(uint40 expiry => bool)) public corroborated;

    /// @notice MIRRORS SettlementOracle.SPOT_CORROBORATION_AGE (30 minutes, T-OP-061): a print younger than this needs
    ///         no witness. The real contract is not imported here (a mock must not drag the oracle into every suite),
    ///         so the literal is mirrored and pinned by the unit tests that drive this rule.
    uint32 public constant SPOT_CORROBORATION_AGE = 30 minutes;
    uint8 private constant SPOT_OK = 0;
    uint8 private constant SPOT_NO_SOURCE = 1;
    uint8 private constant SPOT_STALE = 2;

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

    /// @notice The outer age bound and the agreement band of the three-step rule (0, 0 = the always-fresh default).
    function setSpotRule(address underlying, uint32 spotMaxAge, uint16 maxDeviationBps) external {
        SpotRule storage r = _spotRules[underlying];
        r.spotMaxAge = spotMaxAge;
        r.maxDeviationBps = maxDeviationBps;
    }

    /// @notice The modelled source 1: whether it answers ok, and at what price.
    function setSpotWitness(address underlying, bool ok, uint256 price) external {
        SpotRule storage r = _spotRules[underlying];
        r.witnessOk = ok;
        r.witnessPrice = price;
    }

    /// @notice The blunt switch: stale whatever the clock and the witness say.
    function setSpotStale(address underlying, bool stale) external {
        _spotRules[underlying].forceStale = stale;
    }

    /// @notice Marks (underlying, expiry) corroborated, so FinalizeOnCall finalizes it even while Held.
    function setCorroborated(address underlying, uint40 expiry, bool on) external {
        corroborated[underlying][expiry] = on;
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
        (uint8 status, SpotEntry memory s) = _spot(underlying);
        if (status == SPOT_NO_SOURCE) revert V2Errors.NoSource();
        if (status == SPOT_STALE) revert V2Errors.StaleSpot(s.updatedAt);
        return (s.price, s.updatedAt);
    }

    function trySpot(address underlying) external view returns (bool ok, uint256 price, uint256 updatedAt) {
        if (trySpotReverts) revert MockOracleReverted();
        (uint8 status, SpotEntry memory s) = _spot(underlying);
        // Pre-T-OP-070 shape for a spot that was never ok: the set values come back with ok = false, as before.
        if (status == SPOT_NO_SOURCE) return (false, s.price, s.updatedAt);
        if (status == SPOT_STALE) return (false, 0, 0);
        return (true, s.price, s.updatedAt);
    }

    /// @dev SettlementOracle._spot's three steps over the set spot and the modelled witness (T-OP-061, mirrored):
    ///        1. print at most SPOT_CORROBORATION_AGE old -> ok;
    ///        2. else, witness ok -> ok iff |witness - print| within maxDeviationBps of the smaller, else STALE;
    ///        3. else -> ok.
    ///      `spotMaxAge` (when set) is the outer bound in every step, and {setSpotStale} overrides everything. A print
    ///      stamped in the future is treated as age 0 here (the real `_latestOf` refuses it): fixtures that set a
    ///      spot before warping to it kept working unchanged, and modelling that refusal is a separate fidelity item.
    function _spot(address underlying) private view returns (uint8 status, SpotEntry memory s) {
        s = _spots[underlying];
        SpotRule memory r = _spotRules[underlying];
        if (!s.ok) return (SPOT_NO_SOURCE, s);
        if (r.forceStale) return (SPOT_STALE, s);
        uint256 age = s.updatedAt >= block.timestamp ? 0 : block.timestamp - s.updatedAt;
        if (r.spotMaxAge != 0 && age > r.spotMaxAge) return (SPOT_STALE, s);
        if (age <= SPOT_CORROBORATION_AGE) return (SPOT_OK, s);
        if (r.witnessOk) {
            uint256 lo = s.price < r.witnessPrice ? s.price : r.witnessPrice;
            uint256 diff = s.price < r.witnessPrice ? r.witnessPrice - s.price : s.price - r.witnessPrice;
            // SettlementOracle._agree, mirrored: |p_i - p_j| x 10_000 <= min(p_i, p_j) x maxDeviationBps.
            return (diff * 10_000 <= lo * r.maxDeviationBps ? SPOT_OK : SPOT_STALE, s);
        }
        return (SPOT_OK, s);
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
        // SettlementOracle._advance, mirrored: a corroborated expiry finalizes whatever its status; a Held
        // uncorroborated one is left untouched and reports (false, 0) until {unveto} (T-OP-070).
        bool heldBack = e.status == V2Types.SettlementStatus.Held && !corroborated[underlying][expiry];
        if (e.mode == FinalizeMode.FinalizeOnCall && e.status != V2Types.SettlementStatus.Finalized && !heldBack) {
            e.status = V2Types.SettlementStatus.Finalized;
            e.price = e.finalizePrice;
            emit SettlementFinalized(underlying, expiry, e.price, 0, corroborated[underlying][expiry]);
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
