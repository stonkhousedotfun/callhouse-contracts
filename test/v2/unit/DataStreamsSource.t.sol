// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";
import {DataStreamsReportV11} from "../../../src/v2/oracle/DataStreamsDeps.sol";
import {IUiMultiplier} from "../../../src/v2/oracle/DataStreamsDeps.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {IPriceSource} from "../../../src/v2/interfaces/IPriceSource.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {MockVerifierProxy} from "../../../src/v2/mocks/MockVerifierProxy.sol";

/// @notice DataStreamsSource: v11 decoding (against Solidity's own decoder), every submit rule (verification, feed id,
///         market status, stale/future/expired timestamps, mid staleness, ordering, paused flag, multiplier, price
///         bounds) as a skip that never reverts a batch, multiplier application including a decrease, the ring buffer
///         wrap, every window coverage rule with its boundary, sealing, {record} snapshots, admin configuration, and a
///         fuzzed TWAP against a forward-integrating reference.
/// @dev Extends BaseV2Test: {_deployFeeds} deploys the mock VerifierProxy, {_deployCore} the source with NVDAx and
///      TSLAx configured on their R13 Regular Hours feed ids (callhouse ops/markets/v2-sources.json). Reports are built
///      as the Streams API would deliver them: `abi.encode(DataStreamsReportV11)` wrapped by MockVerifierProxy.sign.
///      Equity prices in the reports are 18 dp (`_mid`), expectations are USDG 6 dp per share.
contract DataStreamsSourceTest is BaseV2Test {
    bytes32 internal constant NVDA_FEED_ID = 0x000b6aa036224454037bab103184565f6aa9ea589c3b349f6d8471ee753524b9;
    bytes32 internal constant TSLA_FEED_ID = 0x000b2dbed1640ead18d37338b75e4755630a900649261baf4ed79d9a749be13d;
    /// @dev AAPL's R13 id: a valid v11 id nobody configured here.
    bytes32 internal constant AAPL_FEED_ID = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;

    /// @dev A window well after START: [E - 1800, E].
    // casting to 'uint40' is safe because START is 1_789_000_000
    // forge-lint: disable-next-line(unsafe-typecast)
    uint40 internal constant E = uint40(START) + 1 days;
    uint40 internal constant S = E - 1800;
    /// @dev E as the uint32 the report timestamps are.
    // casting to 'uint32' is safe because E is 1_789_086_400 < 2^32
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 internal constant E32 = uint32(E);

    address internal stranger = makeAddr("stranger");

    MockVerifierProxy internal proxy;
    DataStreamsSource internal src;

    event FeedSet(address indexed underlying, bytes32 indexed feedId);
    event ObservationStored(
        address indexed underlying,
        bytes32 indexed feedId,
        uint40 observedAt,
        uint256 price,
        int256 mid,
        uint256 uiMultiplier
    );
    event ReportSkipped(uint256 indexed index, bytes32 indexed feedId, DataStreamsSource.SkipReason reason);
    event Recorded(address indexed underlying, uint40 indexed expiry, uint256 price, uint256 observations);

    function _deployFeeds() internal override {
        proxy = new MockVerifierProxy();
    }

    function _deployCore() internal override {
        _deployManager();
        src = new DataStreamsSource(address(manager), address(proxy));
        _wire(address(src), "DataStreamsSource", admin, 0);
        vm.startPrank(admin);
        src.setFeed(address(nvda), NVDA_FEED_ID);
        src.setFeed(address(tsla), TSLA_FEED_ID);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev 18-dp equity price for a USDG 6-dp price.
    function _mid(uint256 usdg6) internal pure returns (int192) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int192(int256(usdg6 * 1e12));
    }

    /// @dev A healthy regular-hours report observed at `at`: valid from one second earlier, expiring a day later, mid
    ///      last updated 0.2 s before the observation, a 1-cent spread.
    function _report(bytes32 feedId, uint256 at, uint256 usdg6) internal pure returns (DataStreamsReportV11 memory r) {
        int192 m = _mid(usdg6);
        r.feedId = feedId;
        // forge-lint: disable-next-line(unsafe-typecast)
        r.validFromTimestamp = uint32(at - 1);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.observationsTimestamp = uint32(at);
        r.nativeFee = 0;
        r.linkFee = 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        r.expiresAt = uint32(at + 1 days);
        r.mid = m;
        // forge-lint: disable-next-line(unsafe-typecast)
        r.lastSeenTimestampNs = uint64(at * 1e9 - 2e8);
        r.bid = m - 5e15;
        r.bidVolume = 120e18;
        r.ask = m + 5e15;
        r.askVolume = 80e18;
        r.lastTradedPrice = m;
        r.marketStatus = 2;
    }

    function _signed(DataStreamsReportV11 memory r) internal view returns (bytes memory) {
        return proxy.sign(abi.encode(r));
    }

    function _one(bytes memory payload) internal pure returns (bytes[] memory reports) {
        reports = new bytes[](1);
        reports[0] = payload;
    }

    function _submit(DataStreamsReportV11 memory r) internal returns (uint256) {
        return src.submit(_one(_signed(r)));
    }

    /// @dev Warps to just after `at` (never backwards) and submits an NVDA report observed at `at`.
    function _observe(uint256 at, uint256 usdg6) internal {
        if (block.timestamp < at + 2) vm.warp(at + 2);
        assertEq(_submit(_report(NVDA_FEED_ID, at, usdg6)), 1, "observation stored");
    }

    /// @dev `n` NVDA observations `spacing` seconds apart from `first`, all at `usdg6`.
    function _observeSeries(uint256 first, uint256 n, uint256 spacing, uint256 usdg6) internal {
        for (uint256 i; i < n; ++i) {
            _observe(first + i * spacing, usdg6);
        }
    }

    function _seal(uint256 end) internal {
        vm.warp(end + src.MAX_REPORT_AGE() + 1);
    }

    function _expectSkip(DataStreamsReportV11 memory r, DataStreamsSource.SkipReason reason) internal {
        vm.expectEmit(address(src));
        emit ReportSkipped(0, r.feedId, reason);
        assertEq(_submit(r), 0, "skipped");
    }

    function _window() internal view returns (bool ok, uint256 price) {
        return src.windowPrice(address(nvda), S, E);
    }

    /// @dev Exposed so a try/catch can ask Solidity's own decoder whether a body decodes.
    function abiDecodeV11(bytes calldata body) external pure returns (DataStreamsReportV11 memory) {
        return abi.decode(body, (DataStreamsReportV11));
    }

    /*//////////////////////////////////////////////////////////////
                                  DECODE
    //////////////////////////////////////////////////////////////*/

    function test_decode_allFieldsRoundTrip() public view {
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215_123_456);
        r.nativeFee = 7;
        r.linkFee = 9;
        r.lastTradedPrice = -3;
        r.marketStatus = 5;
        bytes memory body = abi.encode(r);
        assertEq(body.length, 448, "v11 body is 14 static words");

        (bool ok, DataStreamsReportV11 memory d) = src.decodeReport(body);
        assertTrue(ok, "decodes");
        assertEq(keccak256(abi.encode(d)), keccak256(body), "every field round-trips");
        assertEq(d.feedId, NVDA_FEED_ID);
        assertEq(d.validFromTimestamp, E - 1);
        assertEq(d.observationsTimestamp, E);
        assertEq(d.nativeFee, 7);
        assertEq(d.linkFee, 9);
        assertEq(d.expiresAt, E + 1 days);
        assertEq(d.mid, int192(215_123_456e12));
        assertEq(d.lastSeenTimestampNs, uint64(E) * 1e9 - 2e8);
        assertEq(d.bid, int192(215_118_456e12));
        assertEq(d.bidVolume, int192(120e18));
        assertEq(d.ask, int192(215_128_456e12));
        assertEq(d.askVolume, int192(80e18));
        assertEq(d.lastTradedPrice, -3);
        assertEq(d.marketStatus, 5);
    }

    function test_decode_rejectsWrongLengthAndSchema() public view {
        bytes memory body = abi.encode(_report(NVDA_FEED_ID, E, 215e6));
        bool ok;
        (ok,) = src.decodeReport(bytes.concat(body, hex"00"));
        assertFalse(ok, "449 bytes");
        (ok,) = src.decodeReport(_slice(body, 447));
        assertFalse(ok, "447 bytes");
        (ok,) = src.decodeReport("");
        assertFalse(ok, "empty");

        // v8 (RWA Standard) id, v3 id, and a millisecond-resolution v11 id (high nibble 1).
        bytes32[3] memory wrongIds = [
            bytes32(0x0008aaaa00000000000000000000000000000000000000000000000000000001),
            bytes32(0x0003bbbb00000000000000000000000000000000000000000000000000000002),
            bytes32(0x100b6aa036224454037bab103184565f6aa9ea589c3b349f6d8471ee753524b9)
        ];
        for (uint256 i; i < wrongIds.length; ++i) {
            (ok,) = src.decodeReport(abi.encode(_report(wrongIds[i], E, 215e6)));
            assertFalse(ok, "not a v11 seconds-resolution id");
        }
    }

    function test_decode_rejectsWordsOutsideTheirTypes() public view {
        bytes memory good = abi.encode(_report(NVDA_FEED_ID, E, 215e6));
        (bool ok,) = src.decodeReport(good);
        assertTrue(ok);

        // word index => a value just outside the field's ABI type
        uint256[8] memory idx = [uint256(1), 2, 3, 4, 5, 7, 13, 6];
        uint256[8] memory bad = [
            uint256(1) << 32,
            uint256(1) << 32,
            uint256(1) << 192,
            uint256(1) << 192,
            uint256(1) << 32,
            uint256(1) << 64,
            uint256(1) << 32,
            uint256(1) << 191
        ];
        for (uint256 i; i < idx.length; ++i) {
            bytes memory body = _withWord(good, idx[i], bad[i]);
            (ok,) = src.decodeReport(body);
            assertFalse(ok, "out-of-range word rejected");
            try this.abiDecodeV11(body) {
                revert("solidity decoder accepted it too");
            } catch {}
        }
        // Negative int192 values are sign-extended words: fine for every int192 field.
        for (uint256 w = 8; w <= 12; ++w) {
            (ok,) = src.decodeReport(_withWord(good, w, type(uint256).max));
            assertTrue(ok, "-1 decodes");
        }
    }

    /// Conformance: for arbitrary 448-byte bodies with the v11 prefix, decodeReport is ok exactly when Solidity's
    /// decoder accepts the body, and then the fields agree. Never reverts.
    function testFuzz_decode_matchesSolidityDecoder(bytes32[14] memory words, uint8 widen) public view {
        words[0] = bytes32((uint256(words[0]) >> 16) | (uint256(0x000b) << 240));
        // Most random words are out of range; narrow some so both outcomes are exercised.
        for (uint256 i = 1; i < 14; ++i) {
            if ((widen >> (i % 8)) & 1 == 0) words[i] = bytes32(uint256(words[i]) & type(uint32).max);
        }
        bytes memory body = abi.encodePacked(words);
        (bool ok, DataStreamsReportV11 memory d) = src.decodeReport(body);
        try this.abiDecodeV11(body) returns (DataStreamsReportV11 memory expected) {
            assertTrue(ok, "solidity decodes, so must the source");
            assertEq(keccak256(abi.encode(d)), keccak256(abi.encode(expected)), "same fields");
        } catch {
            assertFalse(ok, "solidity rejects, so must the source");
        }
    }

    /*//////////////////////////////////////////////////////////////
                         SUBMIT: STORED OBSERVATIONS
    //////////////////////////////////////////////////////////////*/

    function test_submit_storesTokenPriceAndEmits() public {
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215_120_000);
        vm.expectEmit(address(src));
        emit ObservationStored(address(nvda), NVDA_FEED_ID, E, 215_120_000, r.mid, 1e18);
        assertEq(_submit(r), 1);

        assertEq(proxy.verifyCalls(), 1, "verified once");
        assertEq(proxy.lastRequester(), address(src), "the source is the requester");
        assertEq(src.observationCount(address(nvda)), 1);
        (bool exists, uint40 at, uint256 price) = src.observationAt(address(nvda), 0);
        assertTrue(exists);
        assertEq(at, E);
        assertEq(price, 215_120_000);

        (bool ok, uint256 latestPrice, uint256 updatedAt) = src.latest(address(nvda));
        assertTrue(ok);
        assertEq(latestPrice, 215_120_000);
        assertEq(updatedAt, E);
    }

    function test_submit_batchOfTwoUnderlyings() public {
        vm.warp(E);
        bytes[] memory reports = new bytes[](2);
        reports[0] = _signed(_report(NVDA_FEED_ID, E, 215e6));
        reports[1] = _signed(_report(TSLA_FEED_ID, E, 358e6));
        assertEq(src.submit(reports), 2);
        (, uint256 n,) = src.latest(address(nvda));
        (, uint256 t,) = src.latest(address(tsla));
        assertEq(n, 215e6);
        assertEq(t, 358e6);
    }

    /// One bad report in the middle neither reverts the call nor stops the reports around it.
    function test_submit_badReportInBatch_othersStored() public {
        vm.warp(E + 60);
        bytes[] memory reports = new bytes[](3);
        reports[0] = _signed(_report(NVDA_FEED_ID, E, 215e6));
        bytes memory forged = _signed(_report(NVDA_FEED_ID, E + 40, 999e6));
        forged[forged.length - 100] = bytes1(uint8(forged[forged.length - 100]) ^ 0x01);
        reports[1] = forged;
        reports[2] = _signed(_report(NVDA_FEED_ID, E + 60, 216e6));

        vm.expectEmit(address(src));
        emit ReportSkipped(1, NVDA_FEED_ID, DataStreamsSource.SkipReason.VerifyFailed);
        assertEq(src.submit(reports), 2);
        assertEq(src.observationCount(address(nvda)), 2);
        (, uint256 price,) = src.latest(address(nvda));
        assertEq(price, 216e6, "third report stored after the forged one");
    }

    function test_submit_emptyBatch() public {
        assertEq(src.submit(new bytes[](0)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SUBMIT: PAYLOAD, VERIFIER, FEED ID
    //////////////////////////////////////////////////////////////*/

    function test_skip_malformedPayloads_neverVerified() public {
        vm.warp(E);
        bytes memory good = _signed(_report(NVDA_FEED_ID, E, 215e6));
        bytes[] memory reports = new bytes[](4);
        reports[0] = hex"deadbeef";
        reports[1] = _slice(good, 223);
        // reportData offset (word 3) pointing past the end
        reports[2] = _withWord(good, 3, good.length);
        // reportData length word below 32
        uint256 off = uint256(_wordAt(good, 3));
        reports[3] = _withWord(good, off / 32, 31);

        for (uint256 i; i < reports.length; ++i) {
            vm.expectEmit(address(src));
            emit ReportSkipped(i, bytes32(0), DataStreamsSource.SkipReason.Malformed);
        }
        assertEq(src.submit(reports), 0);
        assertEq(proxy.verifyCalls(), 0, "malformed payloads never reach the verifier");
    }

    function test_skip_unknownFeed_neverVerified() public {
        vm.warp(E);
        _expectSkip(_report(AAPL_FEED_ID, E, 333e6), DataStreamsSource.SkipReason.UnknownFeed);
        assertEq(proxy.verifyCalls(), 0, "unknown feeds cost no verification");
    }

    function test_skip_verifyFailures() public {
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);

        // bad signature: one byte of the signed body changed after signing
        bytes memory forged = _signed(r);
        forged[forged.length - 200] = bytes1(uint8(forged[forged.length - 200]) ^ 0x80);
        vm.expectEmit(address(src));
        emit ReportSkipped(0, NVDA_FEED_ID, DataStreamsSource.SkipReason.VerifyFailed);
        assertEq(src.submit(_one(forged)), 0, "bad signature");

        // unknown config digest (VerifierNotFound)
        proxy.setDigest(proxy.DIGEST(), false);
        _expectSkip(r, DataStreamsSource.SkipReason.VerifyFailed);
        proxy.setDigest(proxy.DIGEST(), true);

        // verifier reverts outright
        proxy.setReverts(true);
        _expectSkip(r, DataStreamsSource.SkipReason.VerifyFailed);
        proxy.setReverts(false);

        // a FeeManager appears: the empty fee payload cannot be billed
        proxy.setFeeManager(makeAddr("feeManager"));
        _expectSkip(r, DataStreamsSource.SkipReason.VerifyFailed);
        proxy.setFeeManager(address(0));

        // an access controller appears: the source is not allowlisted, then it is
        proxy.setAccessController(makeAddr("accessController"));
        _expectSkip(r, DataStreamsSource.SkipReason.VerifyFailed);
        proxy.setAllowed(address(src), true);
        assertEq(_submit(r), 1, "allowlisted source verifies again");
    }

    function test_skip_verifierRepliesThatAreNotBytes() public {
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        bytes memory body = abi.encode(r);

        bytes[4] memory replies = [
            bytes(hex"01"),
            abi.encode(uint256(32)), // offset but no length word
            bytes.concat(abi.encode(uint256(0x1000)), body), // offset out of bounds
            abi.encode(uint256(32), uint256(449), bytes32(0)) // length beyond the reply
        ];
        for (uint256 i; i < replies.length; ++i) {
            proxy.setRawReply(true, replies[i]);
            _expectSkip(r, DataStreamsSource.SkipReason.VerifyFailed);
        }
        // The same body as a proper ABI `bytes` reply is fine.
        proxy.setRawReply(true, abi.encode(body));
        assertEq(_submit(r), 1, "well-formed raw reply");
    }

    function test_skip_verifiedBodyNotV11() public {
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        proxy.setResponse(true, _slice(abi.encode(r), 447));
        _expectSkip(r, DataStreamsSource.SkipReason.BadReport);
        proxy.setResponse(true, _withWord(abi.encode(r), 2, uint256(1) << 32));
        _expectSkip(r, DataStreamsSource.SkipReason.BadReport);
    }

    /// The payload is routed by the NVDA id it carries, but the verifier vouches for a TSLA body.
    function test_skip_feedIdMismatch() public {
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        proxy.setResponse(true, abi.encode(_report(TSLA_FEED_ID, E, 358e6)));
        _expectSkip(r, DataStreamsSource.SkipReason.FeedIdMismatch);
        assertEq(src.observationCount(address(nvda)), 0);
        assertEq(src.observationCount(address(tsla)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SUBMIT: MARKET STATUS AND TIMESTAMPS
    //////////////////////////////////////////////////////////////*/

    function test_skip_marketStatusOtherThanRegular() public {
        vm.warp(E);
        uint32[5] memory statuses = [uint32(0), 1, 3, 4, 5];
        for (uint256 i; i < statuses.length; ++i) {
            DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
            r.marketStatus = statuses[i];
            _expectSkip(r, DataStreamsSource.SkipReason.MarketNotOpen);
        }
        assertEq(_submit(_report(NVDA_FEED_ID, E, 215e6)), 1, "2 = regular hours is stored");
    }

    function testFuzz_skip_marketStatus(uint32 status) public {
        vm.assume(status != 2);
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        r.marketStatus = status;
        _expectSkip(r, DataStreamsSource.SkipReason.MarketNotOpen);
    }

    function test_skip_validFromAfterObservation() public {
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        r.validFromTimestamp = E32 + 1;
        _expectSkip(r, DataStreamsSource.SkipReason.BadTimestamps);
        r.validFromTimestamp = E32;
        assertEq(_submit(r), 1, "validFrom == observation is a 0-second window, fine");
    }

    function test_skip_futureObservation_boundary() public {
        vm.warp(E);
        _expectSkip(_report(NVDA_FEED_ID, E + 1, 215e6), DataStreamsSource.SkipReason.FutureReport);
        assertEq(_submit(_report(NVDA_FEED_ID, E, 215e6)), 1, "observed now is fine");
    }

    function test_skip_staleObservation_boundary() public {
        uint256 age = src.MAX_REPORT_AGE();
        vm.warp(E + age + 1);
        _expectSkip(_report(NVDA_FEED_ID, E, 215e6), DataStreamsSource.SkipReason.StaleReport);
        vm.warp(E + age);
        assertEq(_submit(_report(NVDA_FEED_ID, E, 215e6)), 1, "exactly MAX_REPORT_AGE old is fine");
    }

    function test_skip_expiredReport_boundary() public {
        vm.warp(E + 30);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        r.expiresAt = E32 + 29;
        _expectSkip(r, DataStreamsSource.SkipReason.ExpiredReport);
        r.expiresAt = E32 + 30;
        assertEq(_submit(r), 1, "expiring this second is fine");
    }

    function test_skip_staleMid_boundary() public {
        vm.warp(E);
        uint256 maxMidAge = src.MAX_MID_AGE();
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.lastSeenTimestampNs = uint64((E - maxMidAge - 1) * 1e9 + 999_999_999);
        _expectSkip(r, DataStreamsSource.SkipReason.StaleMid);
        r.lastSeenTimestampNs = 0;
        _expectSkip(r, DataStreamsSource.SkipReason.StaleMid);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.lastSeenTimestampNs = uint64((E - maxMidAge) * 1e9);
        assertEq(_submit(r), 1, "mid exactly MAX_MID_AGE old is fine");
    }

    /// lastSeenTimestampNs is not monotonic (Chainlink docs): a later report whose mid timestamp moved back a little is
    /// still stored.
    function test_submit_nonMonotonicLastSeen_isFine() public {
        _observe(E, 215e6);
        vm.warp(E + 40);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E + 30, 215e6);
        r.lastSeenTimestampNs = uint64(E) * 1e9 - 5e9;
        assertEq(_submit(r), 1);
    }

    function test_skip_notNewer_duplicatesOlderAndTooClose() public {
        _observe(E, 215e6);
        uint256 spacing = src.MIN_OBSERVATION_SPACING();
        vm.warp(E + spacing + 5);
        _expectSkip(_report(NVDA_FEED_ID, E, 215e6), DataStreamsSource.SkipReason.NotNewer);
        _expectSkip(_report(NVDA_FEED_ID, E - 10, 215e6), DataStreamsSource.SkipReason.NotNewer);
        _expectSkip(_report(NVDA_FEED_ID, E + spacing - 1, 215e6), DataStreamsSource.SkipReason.NotNewer);
        assertEq(_submit(_report(NVDA_FEED_ID, E + spacing, 216e6)), 1, "exactly MIN_OBSERVATION_SPACING later");
        // Spacing is per underlying.
        assertEq(_submit(_report(TSLA_FEED_ID, E, 358e6)), 1, "TSLA has its own history");
    }

    function test_skip_notNewer_withinOneBatch() public {
        vm.warp(E + 60);
        bytes[] memory reports = new bytes[](3);
        reports[0] = _signed(_report(NVDA_FEED_ID, E + 30, 216e6));
        reports[1] = _signed(_report(NVDA_FEED_ID, E, 215e6)); // older, listed later
        reports[2] = _signed(_report(NVDA_FEED_ID, E + 60, 217e6));
        vm.expectEmit(address(src));
        emit ReportSkipped(1, NVDA_FEED_ID, DataStreamsSource.SkipReason.NotNewer);
        assertEq(src.submit(reports), 2);
    }

    /*//////////////////////////////////////////////////////////////
                  SUBMIT: TOKEN FLAGS, MULTIPLIER, PRICE
    //////////////////////////////////////////////////////////////*/

    function test_skip_oraclePaused() public {
        vm.warp(E);
        nvda.setOraclePaused(true);
        _expectSkip(_report(NVDA_FEED_ID, E, 215e6), DataStreamsSource.SkipReason.OraclePaused);
        vm.mockCallRevert(address(tsla), abi.encodeWithSignature("oraclePaused()"), "");
        _expectSkip(_report(TSLA_FEED_ID, E, 358e6), DataStreamsSource.SkipReason.OraclePaused);
    }

    function test_skip_badMultiplier() public {
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        nvda.setUiMultiplier(0);
        _expectSkip(r, DataStreamsSource.SkipReason.BadMultiplier);
        nvda.setUiMultiplier(src.MAX_UI_MULTIPLIER() + 1);
        _expectSkip(r, DataStreamsSource.SkipReason.BadMultiplier);
        nvda.setUiMultiplier(1e18);
        vm.mockCallRevert(address(nvda), abi.encodeCall(IUiMultiplier.uiMultiplier, ()), "");
        _expectSkip(r, DataStreamsSource.SkipReason.BadMultiplier);
        vm.clearMockedCalls();
        assertEq(_submit(r), 1);
    }

    function test_skip_badPrice() public {
        vm.warp(E);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 215e6);
        r.mid = 0;
        _expectSkip(r, DataStreamsSource.SkipReason.BadPrice);
        r.mid = -215e18;
        _expectSkip(r, DataStreamsSource.SkipReason.BadPrice);
        r.mid = 999_999_999_999; // < 1e12: under one USDG base unit
        _expectSkip(r, DataStreamsSource.SkipReason.BadPrice);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.mid = int192(int256(uint256(type(uint128).max) * 1e12));
        nvda.setUiMultiplier(2e18);
        _expectSkip(r, DataStreamsSource.SkipReason.BadPrice);
        nvda.setUiMultiplier(1e18);
        assertEq(_submit(r), 1, "exactly 2^128 - 1 at multiplier 1.0 is storable");
    }

    function test_multiplier_appliedAtSubmit() public {
        vm.warp(E);
        nvda.setUiMultiplier(1.05e18);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 200e6);
        vm.expectEmit(address(src));
        emit ObservationStored(address(nvda), NVDA_FEED_ID, E, 210e6, r.mid, 1.05e18);
        _submit(r);
        (, uint256 price,) = src.latest(address(nvda));
        assertEq(price, 210e6, "200.00 equity x 1.05 = 210.00 per token");
    }

    /// 215.123456789012345678 equity -> floor to 215.123456, x 1.5 = 322.685184.
    function test_multiplier_precision() public {
        vm.warp(E);
        nvda.setUiMultiplier(1.5e18);
        DataStreamsReportV11 memory r = _report(NVDA_FEED_ID, E, 0);
        r.mid = 215_123456789012345678;
        _submit(r);
        (, uint256 price,) = src.latest(address(nvda));
        assertEq(price, 322_685_184);
    }

    /// SEC-20. The multiplier is read when each report is submitted, so a decrease (2.0 -> 1.0, as WEEK did on
    /// chain) changes new observations only -- and a window spanning it holds prices in TWO denominations.
    ///
    /// THIS TEST ASSERTED THE DEFECT UNTIL SEC-20. It previously ended `assertTrue(ok)` and `assertEq(price,
    /// 150e6)`: the mean of 200.00 and 100.00, a number that is neither the pre-action price nor the post-action
    /// price and that would have finalised silently. The blend is not a rounding artefact -- it is half the
    /// multiplier change -- and nothing downstream could tell it from an ordinary price. The window now refuses.
    ///
    /// WHAT DID NOT CHANGE, and is still asserted below: stored observations keep the multiplier they were
    /// submitted with, and {latest} still answers with the newest regime's price. The fix is at the window, not
    /// at the observation.
    function test_multiplier_decreaseMidWindow_nowRefusesInsteadOfBlending() public {
        nvda.setUiMultiplier(2e18);
        _observeSeries(S, 5, 180, 100e6); // S .. S+720 at 200.00 per token
        (, uint256 before,) = src.latest(address(nvda));
        assertEq(before, 200e6);

        nvda.setUiMultiplier(1e18);
        _observeSeries(S + 900, 6, 180, 100e6); // S+900 .. S+1800 at 100.00 per token
        (bool exists,, uint256 older) = src.observationAt(address(nvda), 6);
        assertTrue(exists);
        assertEq(older, 200e6, "stored observations keep the multiplier they were submitted with");
        (, uint256 after_,) = src.latest(address(nvda));
        assertEq(after_, 100e6);

        _seal(E);
        // WAS: 200.00 over [S, S+900) and 100.00 over [S+900, E] -> 150.00, returned as ok.
        (bool ok, uint256 price) = _window();
        assertFalse(ok, "a window that straddles a multiplier change must refuse, not blend");
        assertEq(price, 0, "a refused window carries no price");

        // AND THE REFUSAL REACHES THE THING THAT MATTERS: nothing is recorded for the expiry, so this source
        // produces no settlement price at all rather than a plausible wrong one.
        assertFalse(src.record(address(nvda), E), "record must decline a mixed window");
        (uint128 recorded,,) = src.snapshots(address(nvda), E);
        assertEq(recorded, 0, "no snapshot was written");
    }

    /// THE CONTROL. A window entirely inside one multiplier regime still prices exactly as before.
    /// @dev Without this, the refusal above is satisfied by a window that refuses EVERYTHING, which is the
    ///      failure mode of a guard that over-fires -- and the one that would quietly stop settlement working.
    function test_multiplier_windowInsideOneRegimeStillPrices() public {
        nvda.setUiMultiplier(2e18);
        _observeSeries(S, 11, 180, 100e6); // the whole window at 200.00 per token, one regime throughout
        _seal(E);

        (bool ok, uint256 price) = _window();
        assertTrue(ok, "one regime, one denomination, an ordinary window");
        assertEq(price, 200e6, "and the price is the regime's price, unchanged by SEC-20");
    }

    /// A multiplier that is READ AGAIN but has not moved is not a new regime.
    /// @dev The epoch is bumped on a CHANGE, not on a read. A guard that treated every submit as a new regime
    ///      would refuse every window with more than one observation -- i.e. all of them.
    function test_multiplier_unchangedAcrossTheWindowIsOneRegime() public {
        nvda.setUiMultiplier(1.05e18);
        _observeSeries(S, 5, 180, 100e6);
        nvda.setUiMultiplier(1.05e18); // set again, same value
        _observeSeries(S + 900, 6, 180, 100e6);
        _seal(E);

        (bool ok,) = _window();
        assertTrue(ok, "re-reading the same multiplier is not a corporate action");
        (, uint16 epoch) = src.multiplierState(address(nvda));
        assertEq(epoch, 0, "and the regime counter did not move");
    }

    /*//////////////////////////////////////////////////////////////
                             WINDOW: THE TWAP
    //////////////////////////////////////////////////////////////*/

    /// 200.00 back-filled from S and in force to S+240 (240 s), 201.00 .. 208.00 for 180 s each, 209.00 from S+1680 to
    /// E (120 s): (48,000 + 1,636 x 180 + 25,080) / 1800 = 204.20.
    function test_window_handComputed() public {
        for (uint256 i; i < 10; ++i) {
            _observe(S + 60 + i * 180, 200e6 + i * 1e6);
        }
        _seal(E);
        (bool ok, uint256 price) = _window();
        assertTrue(ok);
        assertEq(price, 204_200_000);

        DataStreamsSource.Window memory w = src.inspectWindow(address(nvda), S, E);
        assertTrue(w.ok);
        assertEq(w.price, 204_200_000);
        assertEq(w.observations, 10);
        assertEq(w.firstAt, S + 60);
        assertEq(w.lastAt, S + 1680);
        assertEq(w.maxGap, 180);
    }

    /// Observations before `start` and after `end` do not enter the price.
    function test_window_ignoresObservationsOutside() public {
        _observeSeries(S - 600, 4, 150, 999e6); // S-600 .. S-150
        _observeSeries(S, 11, 180, 210e6); // S .. E
        _observeSeries(E + 30, 3, 30, 1e6); // after E, still inside MAX_REPORT_AGE of each
        vm.warp(E + 200);
        (bool ok, uint256 price) = _window();
        assertTrue(ok);
        assertEq(price, 210e6);
        assertEq(src.inspectWindow(address(nvda), S, E).observations, 11);
    }

    function test_window_sealedOnlyAfterMaxReportAge() public {
        _observeSeries(S, 11, 180, 210e6);
        vm.warp(E + src.MAX_REPORT_AGE());
        (bool ok,) = _window();
        assertFalse(ok, "a report observed at E could still arrive");
        vm.warp(E + src.MAX_REPORT_AGE() + 1);
        (ok,) = _window();
        assertTrue(ok, "sealed");
    }

    /// The seal must precede SettlementOracle's first finalize.
    function test_window_sealPrecedesFinalizeDelay() public view {
        assertLt(src.MAX_REPORT_AGE(), V2Constants.FINALIZE_DELAY);
        assertGe(src.RING_SIZE(), 256);
    }

    /*//////////////////////////////////////////////////////////////
                        WINDOW: COVERAGE RULES
    //////////////////////////////////////////////////////////////*/

    function test_rule_minObservations() public {
        // 9 observations 200 s apart from S: S .. S+1600; last >= E - 300, gaps 200.
        _observeSeries(S, 9, 200, 210e6);
        _seal(E);
        (bool ok,) = _window();
        assertFalse(ok, "9 observations");
        assertEq(src.inspectWindow(address(nvda), S, E).observations, 9);
    }

    function test_rule_minObservations_tenIsEnough() public {
        _observeSeries(S, 10, 200, 210e6); // S .. S+1800
        _seal(E);
        (bool ok,) = _window();
        assertTrue(ok, "10 observations");
    }

    function test_rule_maxGap_boundary() public {
        // 5 at 150 s spacing (S..S+600), a gap, then 7 more to E.
        _observeSeries(S, 5, 150, 210e6);
        _observeSeries(S + 901, 5, 150, 210e6); // gap S+600 -> S+901 = 301
        _observeSeries(S + 1651, 1, 1, 210e6);
        _seal(E);
        DataStreamsSource.Window memory w = src.inspectWindow(address(nvda), S, E);
        assertEq(w.maxGap, 301);
        assertFalse(w.ok, "a 301 s gap");
    }

    function test_rule_maxGap_exactly300() public {
        _observeSeries(S, 5, 150, 210e6);
        _observeSeries(S + 900, 5, 150, 210e6); // gap exactly 300
        _observeSeries(S + 1650, 1, 1, 210e6);
        _seal(E);
        DataStreamsSource.Window memory w = src.inspectWindow(address(nvda), S, E);
        assertEq(w.maxGap, 300);
        assertTrue(w.ok, "a 300 s gap is allowed");
    }

    function test_rule_firstObservation_boundary() public {
        // first at S+301: 10 observations 166 s apart end at S+1795
        _observeSeries(S + 301, 10, 166, 210e6);
        _seal(E);
        (bool ok,) = _window();
        assertFalse(ok, "first at start + 301");
    }

    function test_rule_firstObservation_exactly300() public {
        _observeSeries(S + 300, 10, 166, 210e6); // S+300 .. S+1794
        _seal(E);
        (bool ok, uint256 price) = _window();
        assertTrue(ok, "first at start + 300");
        assertEq(price, 210e6);
    }

    function test_rule_lastObservation_boundary() public {
        // last at E-301: 10 observations 166 s apart from S
        _observeSeries(S, 10, 166, 210e6); // S .. S+1494 = E-306
        _seal(E);
        (bool ok,) = _window();
        assertFalse(ok, "last at end - 306");

        uint40 end2 = S + 1494 + 300; // the same observations, a window ending 300 s after the last (already sealed)
        (ok,) = src.windowPrice(address(nvda), S, end2);
        assertTrue(ok, "last at end - 300");
        (ok,) = src.windowPrice(address(nvda), S, end2 + 1);
        assertFalse(ok, "last at end - 301");
    }

    function test_rule_noObservationInWindow() public {
        _observeSeries(S - 3000, 20, 60, 210e6);
        _seal(E);
        DataStreamsSource.Window memory w = src.inspectWindow(address(nvda), S, E);
        assertFalse(w.ok);
        assertEq(w.observations, 0);
        (bool ok,) = src.windowPrice(address(nvda), S - 100_000, S - 90_000);
        assertFalse(ok, "window before any observation");
    }

    function test_rule_badBoundsAndUnconfigured() public {
        _observeSeries(S, 11, 180, 210e6);
        _seal(E);
        (bool ok,) = src.windowPrice(address(nvda), E, E);
        assertFalse(ok, "start == end");
        (ok,) = src.windowPrice(address(nvda), E, S);
        assertFalse(ok, "start > end");
        (ok,) = src.windowPrice(address(usdg), S, E);
        assertFalse(ok, "unconfigured underlying");
        (bool latestOk,,) = src.latest(address(usdg));
        assertFalse(latestOk);
    }

    function test_rule_oraclePausedNow() public {
        _observeSeries(S, 11, 180, 210e6);
        _seal(E);
        nvda.setOraclePaused(true);
        (bool ok,) = _window();
        assertFalse(ok, "paused now");
        (bool latestOk,,) = src.latest(address(nvda));
        assertFalse(latestOk, "latest paused");
        nvda.setOraclePaused(false);
        (ok,) = _window();
        assertTrue(ok);
    }

    /*//////////////////////////////////////////////////////////////
                               RING BUFFER
    //////////////////////////////////////////////////////////////*/

    /// 300 observations 30 s apart from T0: slots wrap after 256, the 44 oldest are gone.
    function test_ring_wrap() public {
        uint256 t0 = E;
        _observeSeries(t0, 300, 30, 210e6);
        assertEq(src.observationCount(address(nvda)), 300);

        (bool exists, uint40 at,) = src.observationAt(address(nvda), 0);
        assertTrue(exists);
        assertEq(at, t0 + 299 * 30, "newest");
        (exists, at,) = src.observationAt(address(nvda), 255);
        assertTrue(exists);
        assertEq(at, t0 + 44 * 30, "oldest retained");
        (exists,,) = src.observationAt(address(nvda), 256);
        assertFalse(exists, "overwritten");
    }

    function test_ring_wrap_windowsKeptAndLost() public {
        uint256 t0 = E;
        for (uint256 i; i < 300; ++i) {
            _observe(t0 + i * 30, 200e6 + i * 1000);
        }
        uint256 oldestAt = t0 + 44 * 30;
        vm.warp(t0 + 300 * 30 + 100);

        // Starts exactly at the oldest retained observation: its predecessor is gone, so earlier in-window data may be.
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool ok,) = src.windowPrice(address(nvda), uint40(oldestAt), uint40(oldestAt + 1800));
        assertFalse(ok, "window reaching the overwritten slots");
        // One observation later the predecessor is retained: complete.
        // forge-lint: disable-next-line(unsafe-typecast)
        (ok,) = src.windowPrice(address(nvda), uint40(oldestAt + 1), uint40(oldestAt + 1801));
        assertTrue(ok, "window fully retained");
        // A window over overwritten history.
        // forge-lint: disable-next-line(unsafe-typecast)
        (ok,) = src.windowPrice(address(nvda), uint40(t0), uint40(t0 + 1800));
        assertFalse(ok, "overwritten window");
        // The latest window: binary search lands in the wrapped slots.
        uint256 last = t0 + 299 * 30;
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool okLast, uint256 price) = src.windowPrice(address(nvda), uint40(last - 1800), uint40(last));
        assertTrue(okLast, "latest window after wrap");
        // prices 200.000000 + i x 0.001 for i = 239..299, each 30 s, first back-filled 0: mean of i = 240..299 plus
        // i = 239 weighted 30 s -> (sum over i=239..298 of p_i) x 30 / 1800 + p_299 x 0 = mean of 239..298
        assertEq(price, 200e6 + ((239 + 298) * 1000) / 2);
    }

    /// Gas of the settlement-shaped read: a full 30-minute window of 61 observations, located by binary search in a
    /// wrapped ring with 1.5 hours of later observations.
    function test_gas_windowPriceWrappedRing() public {
        _observeSeries(S, 256 + 61, 30, 210e6);
        vm.warp(S + 317 * 30 + 100);
        uint256 end = S + 316 * 30 - 5400;
        uint256 g = gasleft();
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool ok,) = src.windowPrice(address(nvda), uint40(end - 1800), uint40(end));
        uint256 used = g - gasleft();
        emit log_named_uint("gas: windowPrice, 61 observations in a wrapped ring", used);
        assertTrue(ok);
        assertLt(used, 250_000);
    }

    /*//////////////////////////////////////////////////////////////
                                  RECORD
    //////////////////////////////////////////////////////////////*/

    function test_record_onceSealedOnceOnly() public {
        _observeSeries(S, 11, 180, 210e6);
        vm.warp(E + src.MAX_REPORT_AGE());
        assertFalse(src.record(address(nvda), E), "not sealed: false, no revert");
        assertFalse(src.record(address(nvda), E - 1000), "not ok: false");

        _seal(E);
        vm.expectEmit(address(src));
        emit Recorded(address(nvda), E, 210e6, 11);
        assertTrue(src.record(address(nvda), E));
        assertFalse(src.record(address(nvda), E), "second record");
        (uint128 price, uint16 used, uint40 recordedAt) = src.snapshots(address(nvda), E);
        assertEq(price, 210e6);
        assertEq(used, 11);
        assertEq(recordedAt, block.timestamp);
    }

    function test_record_unconfiguredAndTinyExpiry() public {
        assertFalse(src.record(address(usdg), E));
        assertFalse(src.record(address(nvda), 1800));
        assertFalse(src.record(address(nvda), 0));
    }

    /// The snapshot outlives the ring: after 256 later observations the window is no longer computable, but
    /// windowPrice still serves the recorded price for exactly the settlement window.
    function test_record_survivesRingWrap() public {
        _observeSeries(S, 11, 180, 210e6);
        _seal(E);
        assertTrue(src.record(address(nvda), E));

        _observeSeries(E + 1000, 256, 30, 300e6);
        assertFalse(src.inspectWindow(address(nvda), S, E).ok, "ring no longer holds the window");
        (bool ok, uint256 price) = _window();
        assertTrue(ok, "snapshot served");
        assertEq(price, 210e6);
        (ok,) = src.windowPrice(address(nvda), S + 1, E);
        assertFalse(ok, "the snapshot answers only the settlement window");

        // It also survives removing the feed, like UniV3TwapSource's snapshots.
        vm.prank(admin);
        src.setFeed(address(nvda), bytes32(0));
        (ok, price) = _window();
        assertTrue(ok);
        assertEq(price, 210e6);
    }

    /*//////////////////////////////////////////////////////////////
                                  LATEST
    //////////////////////////////////////////////////////////////*/

    function test_latest_emptyThenNewestRegardlessOfAge() public {
        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok, "nothing stored");
        _observe(E, 215e6);
        _observe(E + 45, 216e6);
        vm.warp(E + 10 days);
        uint256 price;
        uint256 updatedAt;
        (ok, price, updatedAt) = src.latest(address(nvda));
        assertTrue(ok, "age is the caller's business");
        assertEq(price, 216e6);
        assertEq(updatedAt, E + 45);
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_admin_constructor() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new DataStreamsSource(address(0), address(proxy));
        vm.expectRevert(V2Errors.NoSource.selector);
        new DataStreamsSource(address(manager), makeAddr("eoaProxy"));

        DataStreamsSource fresh = new DataStreamsSource(address(manager), address(proxy));
        assertEq(fresh.verifierProxy(), address(proxy));
        (bool isConfigAdmin,) = manager.hasRole(V8Roles.CONFIG_ADMIN, admin);
        assertTrue(isConfigAdmin, "admin is the wired config admin");
        (bool ok,,) = fresh.latest(address(nvda));
        assertFalse(ok, "disabled until a feed is set");
    }

    function test_admin_setFeed_rejects() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.setFeed(address(nvda), AAPL_FEED_ID);

        vm.startPrank(admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        src.setFeed(address(0), AAPL_FEED_ID);
        vm.expectRevert(V2Errors.NoSource.selector);
        src.setFeed(address(nvda), bytes32(0x0008aaaa00000000000000000000000000000000000000000000000000000001));
        vm.expectRevert(V2Errors.NoSource.selector);
        src.setFeed(address(nvda), bytes32(0x100b6aa036224454037bab103184565f6aa9ea589c3b349f6d8471ee753524b9));
        vm.expectRevert(V2Errors.NoSource.selector);
        src.setFeed(address(nvda), TSLA_FEED_ID); // already prices TSLAx
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        src.setFeed(address(usdg), AAPL_FEED_ID); // no uiMultiplier()
        nvda.setUiMultiplier(0);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        src.setFeed(address(nvda), AAPL_FEED_ID);
        vm.stopPrank();
    }

    /// @dev v8: the source carries no role table at all (Managed, not AccessControl). A stranger cannot grant or
    ///      revoke anything on the source; configuration is gated by the manager, which reverts NotAuthorized.
    function test_admin_noRoleSurfaceOnTheSource() public {
        assertEq(src.authority(), address(manager), "the manager is the authority");
        vm.startPrank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.setFeed(address(nvda), AAPL_FEED_ID);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.setOracle(makeAddr("oracle"), true);
        vm.stopPrank();
    }

    function test_admin_changeFeed_restartsHistory() public {
        _observe(E, 215e6);

        vm.prank(admin);
        src.setFeed(address(nvda), NVDA_FEED_ID); // same id: no change
        assertEq(src.observationCount(address(nvda)), 1, "same id keeps history");

        vm.expectEmit(address(src));
        emit FeedSet(address(nvda), AAPL_FEED_ID);
        vm.prank(admin);
        src.setFeed(address(nvda), AAPL_FEED_ID);
        assertEq(src.feedIdOf(address(nvda)), AAPL_FEED_ID);
        assertEq(src.underlyingOf(AAPL_FEED_ID), address(nvda));
        assertEq(src.underlyingOf(NVDA_FEED_ID), address(0), "old id released");
        assertEq(src.observationCount(address(nvda)), 0, "history restarts");
        (bool ok,,) = src.latest(address(nvda));
        assertFalse(ok);

        vm.warp(E + 60);
        _expectSkip(_report(NVDA_FEED_ID, E + 58, 215e6), DataStreamsSource.SkipReason.UnknownFeed);
        // The new stream's first observation is not held back by the old history's spacing.
        assertEq(_submit(_report(AAPL_FEED_ID, E + 1, 215e6)), 1);

        vm.expectEmit(address(src));
        emit FeedSet(address(nvda), bytes32(0));
        vm.prank(admin);
        src.setFeed(address(nvda), bytes32(0));
        assertEq(src.underlyingOf(AAPL_FEED_ID), address(0));
        assertEq(src.observationCount(address(nvda)), 0);
        // The released id can now price another underlying.
        vm.prank(admin);
        src.setFeed(address(tsla), AAPL_FEED_ID);
        assertEq(src.underlyingOf(TSLA_FEED_ID), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      PINNING (INTERFACE_VERSION 6)
    //////////////////////////////////////////////////////////////*/

    event OracleSet(address indexed oracle, bool allowed);
    event FeedPinned(address indexed underlying, uint40 indexed expiry, bytes32 feedId, uint64 version);

    address internal oracleAddr = makeAddr("oracle");

    function _pinNvdaE() internal {
        vm.prank(oracleAddr);
        src.pin(address(nvda), E);
    }

    /// The allow-list, the pin's log and idempotency, and which setFeed calls move the version.
    function test_pin_allowListVersionAndIdempotency() public {
        vm.prank(stranger);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.setOracle(oracleAddr, true);
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        src.pin(address(nvda), E);

        vm.expectEmit(address(src));
        emit OracleSet(oracleAddr, true);
        vm.prank(admin);
        src.setOracle(oracleAddr, true);
        assertEq(src.feedVersion(address(nvda)), 1, "the fixture's setFeed");
        vm.expectEmit(address(src));
        emit FeedPinned(address(nvda), E, NVDA_FEED_ID, 1);
        _pinNvdaE();
        vm.recordLogs();
        _pinNvdaE();
        assertEq(vm.getRecordedLogs().length, 0, "idempotent");
        (bool pinned, uint64 version) = src.pinnedFeeds(address(nvda), E);
        assertTrue(pinned, "pinned");
        assertEq(version, 1, "at version 1");

        vm.prank(admin);
        src.setFeed(address(nvda), NVDA_FEED_ID);
        assertEq(src.feedVersion(address(nvda)), 1, "the same id changes nothing");
        vm.prank(admin);
        src.setFeed(address(nvda), AAPL_FEED_ID);
        assertEq(src.feedVersion(address(nvda)), 2, "a change bumps it");
    }

    /// C2-16 finding 1: after the pin, a feed change (even away and back to the same stream, which restarts the
    /// history) takes this source out of the pinned expiry: neither windowPrice nor record answers for it, while an
    /// unpinned window over the same prints does.
    function test_pin_feedChangedAfterPin_notOkForThatExpiry() public {
        vm.prank(admin);
        src.setOracle(oracleAddr, true);
        _pinNvdaE();
        vm.startPrank(admin);
        src.setFeed(address(nvda), AAPL_FEED_ID);
        src.setFeed(address(nvda), NVDA_FEED_ID);
        vm.stopPrank();

        _observeSeries(S, 11, 180, 210e6);
        _seal(E);
        assertTrue(src.inspectWindow(address(nvda), S, E).ok, "the ring would price it");
        (bool ok,) = _window();
        assertFalse(ok, "but the pinned expiry refuses: the version moved");
        assertFalse(src.record(address(nvda), E), "nor records");
        uint256 price;
        (ok, price) = src.windowPrice(address(nvda), S - 1, E - 1);
        assertTrue(ok, "an unpinned window over the same prints");
        assertEq(price, 210e6);
    }

    /// Fails closed: an underlying without a feed id cannot be pinned (NoSource), and a pin of an expiry already pinned
    /// is confirmed only at the pinned version. A change away and back to the same stream moves the version (the ring
    /// restarted), so it refuses too; answers the pin selector otherwise.
    function test_pin_unconfiguredOrMovedVersion_reverts() public {
        vm.prank(admin);
        src.setOracle(oracleAddr, true);
        address other = makeAddr("unconfigured");
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.NoSource.selector);
        src.pin(other, E);
        (bool pinned,) = src.pinnedFeeds(other, E);
        assertFalse(pinned, "nothing pinned");

        vm.prank(oracleAddr);
        assertEq(src.pin(address(nvda), E), IPriceSource.pin.selector, "answers the pin selector");
        vm.prank(oracleAddr);
        assertEq(src.pin(address(nvda), E), IPriceSource.pin.selector, "same version: confirmed");

        vm.startPrank(admin);
        src.setFeed(address(nvda), AAPL_FEED_ID);
        src.setFeed(address(nvda), NVDA_FEED_ID);
        vm.stopPrank();
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.PinMismatch.selector);
        src.pin(address(nvda), E);
        vm.prank(admin);
        src.setFeed(address(nvda), bytes32(0));
        vm.prank(oracleAddr);
        vm.expectRevert(V2Errors.PinMismatch.selector);
        src.pin(address(nvda), E);
        (, uint64 version) = src.pinnedFeeds(address(nvda), E);
        assertEq(version, 1, "the pinned version did not move");
    }

    /// A pinned expiry recorded before the change keeps its snapshot; one whose version did not move is priced as usual.
    function test_pin_recordedBeforeTheChange_survives() public {
        vm.prank(admin);
        src.setOracle(oracleAddr, true);
        _pinNvdaE();
        _observeSeries(S, 11, 180, 210e6);
        _seal(E);
        (bool ok, uint256 price) = _window();
        assertTrue(ok, "unchanged version: priced");
        assertEq(price, 210e6);
        assertTrue(src.record(address(nvda), E), "recorded");
        vm.prank(admin);
        src.setFeed(address(nvda), AAPL_FEED_ID);
        (ok, price) = _window();
        assertTrue(ok, "the snapshot is served after the change");
        assertEq(price, 210e6);
    }

    /*//////////////////////////////////////////////////////////////
                                   FUZZ
    //////////////////////////////////////////////////////////////*/

    /// The window price equals a forward integration of the same observations computed here, for random spacings
    /// (inside the rules), prices, multipliers and window edges.
    function testFuzz_window_matchesReference(uint256 seed, uint8 nRaw, uint16 lead, uint16 tail) public {
        uint256 n = bound(nRaw, 10, 40);
        uint256 startOffset = bound(lead, 0, 300); // first observation at start + startOffset
        uint256 endOffset = bound(tail, 0, 300); // end at last observation + endOffset
        uint256 start = E;
        uint256[] memory times = new uint256[](n);
        uint256[] memory prices = new uint256[](n);
        // SEC-20: ONE MULTIPLIER FOR THE WHOLE WINDOW, fuzzed per run rather than per observation. This test
        // exists to check the weighted-mean reference against the contract, and after SEC-20 a window whose
        // observations span more than one multiplier regime REFUSES rather than averaging -- so varying the
        // multiplier per observation (as this did) would make every run exercise the refusal and never the
        // arithmetic. The refusal has its own coverage below and in the three deterministic cases above.
        uint256 multiplier = bound(uint256(keccak256(abi.encode(seed, "mult"))), 0.5e18, 3e18);
        nvda.setUiMultiplier(multiplier);
        uint256 t = start + startOffset;
        for (uint256 i; i < n; ++i) {
            if (i > 0) t += bound(uint256(keccak256(abi.encode(seed, i, "gap"))), 30, 300);
            uint256 equity = bound(uint256(keccak256(abi.encode(seed, i, "price"))), 1e6, 5000e6);
            times[i] = t;
            prices[i] = equity * multiplier / 1e18;
            _observe(t, equity);
        }
        uint256 end = t + endOffset;
        vm.warp(end + 61);

        uint256 weighted = prices[0] * (times[0] - start);
        for (uint256 i; i < n; ++i) {
            uint256 until = i + 1 < n ? times[i + 1] : end;
            weighted += prices[i] * (until - times[i]);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool ok, uint256 price) = src.windowPrice(address(nvda), uint40(start), uint40(end));
        assertTrue(ok, "every rule holds by construction");
        assertEq(price, weighted / (end - start));
    }

    /// SEC-20: wherever the corporate action falls inside the window, the window refuses.
    /// @dev The deterministic cases pin one position each; this pins that the rule does not depend on WHERE the
    ///      change lands, which is the thing an off-by-one in the walk would get wrong.
    function testFuzz_window_refusesWhereverTheMultiplierChanges(uint256 seed, uint8 nRaw, uint8 atRaw) public {
        uint256 n = bound(nRaw, 10, 40);
        uint256 changeAt = bound(atRaw, 1, n - 1); // never 0: the first observation defines the regime
        nvda.setUiMultiplier(1e18);

        uint256 t = E;
        for (uint256 i; i < n; ++i) {
            if (i > 0) t += bound(uint256(keccak256(abi.encode(seed, i, "gap"))), 30, 300);
            if (i == changeAt) nvda.setUiMultiplier(2e18);
            _observe(t, bound(uint256(keccak256(abi.encode(seed, i, "price"))), 1e6, 5000e6));
        }
        uint256 end = t + 60;
        vm.warp(end + 61);

        // forge-lint: disable-next-line(unsafe-typecast)
        (bool ok, uint256 price) = src.windowPrice(address(nvda), uint40(E), uint40(end));
        assertFalse(ok, "a window containing the change must refuse wherever it falls");
        assertEq(price, 0, "and carry no price");
    }

    /// latest and windowPrice never revert, whatever the window and whatever was stored.
    function testFuzz_views_neverRevert(uint40 start, uint40 end, uint8 count) public {
        uint256 n = bound(count, 0, 20);
        _observeSeries(E, n, 45, 210e6);
        vm.warp(E + 5000);
        src.windowPrice(address(nvda), start, end);
        src.inspectWindow(address(nvda), start, end);
        src.latest(address(nvda));
        src.record(address(nvda), end);
    }

    /// Arbitrary payload bytes never revert submit.
    function testFuzz_submit_arbitraryPayloadNeverReverts(bytes calldata junk, bytes32 word3) public {
        vm.warp(E);
        bytes[] memory reports = new bytes[](2);
        reports[0] = junk;
        bytes memory good = _signed(_report(NVDA_FEED_ID, E, 215e6));
        reports[1] = _withWord(good, 3, uint256(word3) % (good.length + 64));
        src.submit(reports);
    }

    /*//////////////////////////////////////////////////////////////
                              BYTES HELPERS
    //////////////////////////////////////////////////////////////*/

    function _slice(bytes memory data, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = data[i];
        }
    }

    function _wordAt(bytes memory data, uint256 index) internal pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }

    /// @dev A copy of `data` with 32-byte word `index` replaced by `value`.
    function _withWord(bytes memory data, uint256 index, uint256 value) internal pure returns (bytes memory out) {
        out = bytes.concat(data);
        assembly {
            mstore(add(add(out, 0x20), mul(index, 0x20)), value)
        }
    }
}
