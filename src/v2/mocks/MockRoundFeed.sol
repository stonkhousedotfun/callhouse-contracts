// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A Chainlink AggregatorV3 PROXY with a settable round history, for the v2 price-source tests.
/// @dev Mirrors what matters about the live proxies on chain 4663 (ops/recon/R13-v2-sources.md, the NVDA proxy
///      0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15):
///      - round ids are phase-prefixed, `phaseId << 64 | aggregatorRoundId`, and aggregator round numbers restart at 1
///        in every phase. {startPhase} moves the head to a new phase; the old phase's rounds stay readable under their
///        own prefix;
///      - `getRoundData` for a round the aggregator does not have echoes the id with zero answer and timestamps (the
///        live proxy answers `phaseId << 64 | 0` that way) rather than reverting;
///      - `latestRoundData` is the newest round of the current phase.
///      Test switches: {setReverts} makes every read revert, {setHistoryFloor} makes `getRoundData` revert below an id
///      (a pruned history), {setRound} overwrites any round (non-monotonic timestamps, `updatedAt == 0`, bad answers).
///
///      A round is ONE storage slot (int192 answer, uint64 updatedAt), about what a real OCR aggregator reads per
///      round, so the gas a test measures for a long walk is not flattered by the mock.
contract MockRoundFeed {
    struct StoredRound {
        int192 answer;
        uint64 updatedAt;
    }

    uint8 public decimals;
    string public description;
    uint16 public phaseId = 1;
    bool public reverts;
    uint80 public historyFloor;

    /// @notice Rounds pushed into each phase; the latest aggregator round number of that phase.
    mapping(uint16 phase => uint64) public roundsInPhase;
    mapping(uint80 id => StoredRound) internal _rounds;

    error MockFeedReverted();
    error MockAnswerTooWide(int256 answer);
    error MockPhaseNotNewer(uint16 current, uint16 requested);

    constructor(uint8 decimals_, string memory description_) {
        decimals = decimals_;
        description = description_;
    }

    /*//////////////////////////////////////////////////////////////
                                 SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Appends a round to the current phase and returns its proxy id.
    function push(int256 answer, uint256 updatedAt) external returns (uint80 id) {
        uint64 n = roundsInPhase[phaseId] + 1;
        roundsInPhase[phaseId] = n;
        id = roundId(phaseId, n);
        _store(id, answer, updatedAt);
    }

    /// @notice Overwrites (or creates) any round without moving the head.
    function setRound(uint80 id, int256 answer, uint256 updatedAt) external {
        _store(id, answer, updatedAt);
    }

    /// @notice Starts a new phase: later pushes and `latestRoundData` use it. Its first push is aggregator round 1.
    function startPhase(uint16 newPhase) external {
        if (newPhase <= phaseId) revert MockPhaseNotNewer(phaseId, newPhase);
        phaseId = newPhase;
    }

    function setReverts(bool on) external {
        reverts = on;
    }

    function setHistoryFloor(uint80 floor) external {
        historyFloor = floor;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setDescription(string calldata d) external {
        description = d;
    }

    /*//////////////////////////////////////////////////////////////
                              AGGREGATOR V3
    //////////////////////////////////////////////////////////////*/

    function latestRoundData()
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (reverts) revert MockFeedReverted();
        id = roundId(phaseId, roundsInPhase[phaseId]);
        StoredRound memory r = _rounds[id];
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }

    function getRoundData(uint80 id)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (reverts || id < historyFloor) revert MockFeedReverted();
        StoredRound memory r = _rounds[id];
        if (r.updatedAt == 0) return (id, 0, 0, 0, id);
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The proxy id of aggregator round `n` in `phase`.
    function roundId(uint16 phase, uint64 n) public pure returns (uint80) {
        return uint80((uint256(phase) << 64) | n);
    }

    function _store(uint80 id, int256 answer, uint256 updatedAt) internal {
        if (answer > type(int192).max || answer < type(int192).min) revert MockAnswerTooWide(answer);
        // forge-lint: disable-next-line(unsafe-typecast)
        _rounds[id] = StoredRound({answer: int192(answer), updatedAt: uint64(updatedAt)});
    }
}
