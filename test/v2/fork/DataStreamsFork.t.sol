// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";
import {
    DataStreamsReportV11,
    IDataStreamsVerifierProxy,
    IUiMultiplier
} from "../../../src/v2/oracle/DataStreamsDeps.sol";

interface ITypeAndVersion {
    function typeAndVersion() external pure returns (string memory);
}

interface IVerifierProxyAccess {
    function s_accessController() external view returns (address);
}

/// @notice DataStreamsSource against the LIVE Chainlink Data Streams VerifierProxy on chain 4663: the proxy is the
///         version the source was written against, with no FeeManager and no access controller (so subscription-billed
///         verification needs no fee payload and no allowlisting), and a report that is not DON-signed is skipped by
///         `submit` with VerifyFailed instead of reverting the call. No signed report is available without the owner's
///         Data Streams credentials, so a successful live verification is out of scope (docs/V2-DATA-STREAMS.md).
/// @dev Run with:
///        FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/DataStreamsFork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as SourcesFork.t.sol does.
contract DataStreamsForkTest is Test {
    /// @dev R13 (callhouse ops/recon/R13-v2-sources.md).
    address constant VERIFIER_PROXY = 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    /// @dev NVDA/USD-Streams-RegularHoursEquityPrice (callhouse ops/markets/v2-sources.json `dataStreamsFeedId`).
    bytes32 constant NVDA_FEED_ID = 0x000b6aa036224454037bab103184565f6aa9ea589c3b349f6d8471ee753524b9;

    /// @dev chainlink-evm llo-feeds VerifierProxy.
    error VerifierNotFound(bytes32 configDigest);

    event ReportSkipped(uint256 indexed index, bytes32 indexed feedId, DataStreamsSource.SkipReason reason);

    address admin = makeAddr("admin");
    DataStreamsSource src;

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        src = new DataStreamsSource(admin, VERIFIER_PROXY);
        vm.prank(admin);
        src.setFeed(NVDA, NVDA_FEED_ID);
    }

    function test_fork_verifierProxyShape() public view onlyFork {
        assertGt(VERIFIER_PROXY.code.length, 0, "VerifierProxy has code");
        assertEq(ITypeAndVersion(VERIFIER_PROXY).typeAndVersion(), "VerifierProxy 2.0.0", "version");
        assertEq(IDataStreamsVerifierProxy(VERIFIER_PROXY).s_feeManager(), address(0), "no FeeManager");
        assertEq(IVerifierProxyAccess(VERIFIER_PROXY).s_accessController(), address(0), "no access controller");
    }

    function test_fork_sourceConfiguredOnLiveToken() public view onlyFork {
        assertEq(src.verifierProxy(), VERIFIER_PROXY);
        assertEq(src.feedIdOf(NVDA), NVDA_FEED_ID);
        assertEq(src.underlyingOf(NVDA_FEED_ID), NVDA);
        uint256 m = IUiMultiplier(NVDA).uiMultiplier();
        console2.log("NVDA uiMultiplier (1e18 = 1.0):", m);
        assertGt(m, 0, "live multiplier answers");
        assertLe(m, src.MAX_UI_MULTIPLIER(), "inside the accepted range");
        (bool ok,,) = src.latest(NVDA);
        assertFalse(ok, "nothing submitted yet");
    }

    /// A v11-shaped payload that no DON signed: the real proxy reverts VerifierNotFound for its config digest, and
    /// submit turns that into a VerifyFailed skip.
    function test_fork_unsignedReportSkippedNotReverted() public onlyFork {
        DataStreamsReportV11 memory r;
        r.feedId = NVDA_FEED_ID;
        // forge-lint: disable-next-line(unsafe-typecast)
        r.observationsTimestamp = uint32(block.timestamp);
        r.validFromTimestamp = r.observationsTimestamp - 1;
        r.expiresAt = r.observationsTimestamp + 1 days;
        r.mid = 215e18;
        r.lastSeenTimestampNs = uint64(block.timestamp) * 1e9;
        r.marketStatus = 2;
        bytes32 digest = keccak256("not a config digest");
        bytes32[] memory rs = new bytes32[](1);
        bytes32[] memory ss = new bytes32[](1);
        bytes memory payload = abi.encode([digest, bytes32(0), bytes32(0)], abi.encode(r), rs, ss, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(VerifierNotFound.selector, digest));
        IDataStreamsVerifierProxy(VERIFIER_PROXY).verify(payload, "");

        bytes[] memory reports = new bytes[](1);
        reports[0] = payload;
        vm.expectEmit(address(src));
        emit ReportSkipped(0, NVDA_FEED_ID, DataStreamsSource.SkipReason.VerifyFailed);
        assertEq(src.submit(reports), 0, "skipped");
        assertEq(src.observationCount(NVDA), 0);
    }
}
