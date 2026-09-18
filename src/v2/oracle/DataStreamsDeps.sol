// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice One Chainlink Data Streams report in the RWA Advanced (v11) schema, as the VerifierProxy returns it after
///         verification: `abi.encode` of these 14 static fields, 448 bytes.
/// @dev SOURCE (fetched 2026-09-17 UTC, not from memory):
///        - field names and types: smartcontractkit/documentation `src/features/feeds/components/reportSchemaData.ts`
///          at commit b3fe42dae4581e86f5e933c6d958fd8d347ee929 (2026-09-11), rendered at
///          https://docs.chain.link/data-streams/reference/report-schema-v11 ;
///        - ABI order cross-checked against smartcontractkit/data-streams-sdk `go/report/v11/data.go`
///          at commit f73484f5940f42d9bad811d60cd7fb66960682a9 (2026-09-15). The Go decoder reads the three timestamps
///          as uint64 words; the docs type them uint32, and a seconds-resolution feed never exceeds that.
///      UNITS (per field): timestamps in seconds except `lastSeenTimestampNs` (nanoseconds); prices and volumes are
///      int192 with 18 decimals (Chainlink reference data directory, NVDA/USD-Streams-RegularHoursEquityPrice
///      `streamValuesMetadata` multiplier 1e18); fees are legacy fields, unused under subscription billing.
///      The first two bytes of `feedId` are the schema: high nibble = timestamp resolution (0 seconds, 1
///      milliseconds), low 12 bits = version (data-streams-sdk `go/feed/feed.go` ID.Version / ID.Resolution), so every
///      v11 seconds-resolution feed id starts 0x000b (R13: NVDA 0x000b6aa0..., TSLA 0x000b2dbe...).
struct DataStreamsReportV11 {
    /// @dev Stream id; 0x000b prefix for v11 in seconds.
    bytes32 feedId;
    /// @dev Seconds. Earliest time the price is valid (start of the report's window).
    uint32 validFromTimestamp;
    /// @dev Seconds. Latest time the price is valid (end of the report's window).
    uint32 observationsTimestamp;
    /// @dev Legacy onchain verification fee field (native token).
    uint192 nativeFee;
    /// @dev Legacy onchain verification fee field (LINK); not used for subscription billing.
    uint192 linkFee;
    /// @dev Seconds. The report is not valid after this time.
    uint32 expiresAt;
    /// @dev USD per equity share, 18 decimals. DON consensus mid price.
    int192 mid;
    /// @dev Nanoseconds. Last update of `mid` only; not guaranteed monotonic.
    uint64 lastSeenTimestampNs;
    /// @dev USD per share, 18 decimals. Median bid.
    int192 bid;
    /// @dev Shares, 18 decimals. Volume at the bid (one venue's book, informational).
    int192 bidVolume;
    /// @dev USD per share, 18 decimals. Median ask.
    int192 ask;
    /// @dev Shares, 18 decimals. Volume at the ask (one venue's book, informational).
    int192 askVolume;
    /// @dev USD per share, 18 decimals. Deprecated as a production input on 24/5 US equity streams from 2026-10-12.
    int192 lastTradedPrice;
    /// @dev 24/5 US equities mapping: 0 Unknown, 1 Pre-market, 2 Regular hours, 3 Post-market, 4 Overnight, 5 Closed.
    uint32 marketStatus;
}

/// @notice The Chainlink Data Streams VerifierProxy surface DataStreamsSource uses (on chain 4663:
///         0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7, `typeAndVersion()` "VerifierProxy 2.0.0").
/// @dev SOURCE (fetched 2026-09-17 UTC):
///      https://docs.chain.link/data-streams/reference/data-streams-api/onchain-verification
///      (smartcontractkit/documentation `src/content/data-streams/reference/data-streams-api/onchain-verification.mdx`
///      at commit b3fe42dae4581e86f5e933c6d958fd8d347ee929) and the implementation smartcontractkit/chainlink-evm
///      `contracts/src/v0.8/llo-feeds/v0.3.0/VerifierProxy.sol` (identical in v0.5.0) at
///      commit 593f99abbb70682140d02f2a59bbf1e1a622e1c2 (2026-09-15):
///        - `verify` reverts `AccessForbidden()` when an access controller is set and denies the caller, bills through
///          `s_feeManager` only when it is non-zero, routes by the payload's first word (the config digest) and reverts
///          `VerifierNotFound(bytes32)` for an unknown digest, then returns the Verifier's `reportData`: the report
///          body signed by the DON, i.e. `abi.encode(DataStreamsReportV11)` for a v11 feed;
///        - the payload is `abi.encode(bytes32[3] reportContext, bytes reportData, bytes32[] rs, bytes32[] ss,
///          bytes32 rawVs)`; the Verifier checks f+1 signatures over `keccak256(reportData)` and the context;
///        - neither the proxy nor the Verifier checks `expiresAt`: only a FeeManager did, so the consumer must.
///      R13 (callhouse ops/recon/R13-v2-sources.md): `s_feeManager()` is zero on 4663; verification is subscription
///      billed, so `parameterPayload` is empty and no value is sent.
interface IDataStreamsVerifierProxy {
    /// @param payload Full signed report from the Streams API (header + signed report body).
    /// @param parameterPayload Legacy fee metadata; empty under subscription billing.
    /// @return verifierResponse The verified report body (ABI-encoded report struct).
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);

    /// @param payloads Full signed reports; may span feed ids. Reverts as a whole when any one fails.
    /// @param parameterPayload Legacy fee metadata; empty under subscription billing.
    /// @return verifiedReports Verified report bodies in input order.
    function verifyBulk(bytes[] calldata payloads, bytes calldata parameterPayload)
        external
        payable
        returns (bytes[] memory verifiedReports);

    /// @notice Legacy FeeManager accessor; zero on 4663.
    function s_feeManager() external view returns (address);
}

/// @notice ERC-8056 display multiplier of a Robinhood Stock Token, 1e18-scaled. The token price is the equity price
///         times this multiplier; it can move down as well as up.
interface IUiMultiplier {
    function uiMultiplier() external view returns (uint256);
}
