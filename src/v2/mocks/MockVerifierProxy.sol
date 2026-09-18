// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A Chainlink Data Streams VerifierProxy + Verifier stand-in for the DataStreamsSource tests.
/// @dev Mirrors the verify path of smartcontractkit/chainlink-evm `llo-feeds/v0.3.0/VerifierProxy.sol` ("VerifierProxy
///      2.0.0", the version R13 found on 4663) and `Verifier.sol` at commit 593f99abbb70682140d02f2a59bbf1e1a622e1c2:
///        - access controller set and caller not allowed -> `AccessForbidden()`;
///        - a non-zero FeeManager is called with `parameterPayload`; the real FeeManager `abi.decode`s a fee token
///          address from it, so an empty payload reverts. The mock reverts `MockFeeManagerNeedsParameters()` instead;
///        - the payload is `abi.encode(bytes32[3] reportContext, bytes reportData, bytes32[] rs, bytes32[] ss, bytes32
///          rawVs)`; an unknown config digest (`reportContext[0]`) -> `VerifierNotFound(bytes32)`;
///        - on success it emits `ReportVerified(feedId, requester)` and returns `reportData` unchanged.
///      SIGNATURES are simulated: a report verifies when `rs.length == ss.length == 1` and `rs[0] ==
///      {signatureOf}(reportContext, reportData)` (else `BadVerification()`), so a test can forge a bad signature by
///      changing one byte of a signed payload. {sign} builds a valid payload for any body under the active digest.
///      Test switches: {setReverts} (every verify reverts), {setResponse} (a verified call returns other ABI bytes,
///      e.g. a body with another feed id), {setRawReply} (a verified call returns raw, non-ABI bytes), {setFeeManager},
///      {setAccessController} + {setAllowed}, {setDigest}.
contract MockVerifierProxy {
    /// @notice The config digest {sign} uses; active from construction.
    bytes32 public constant DIGEST = keccak256("MockVerifierProxy digest");

    address public s_feeManager;
    address public s_accessController;
    mapping(address caller => bool) public allowed;
    mapping(bytes32 digest => bool) public activeDigest;

    bool public reverts;
    bool public responseSet;
    bytes internal _response;
    bool public rawReplySet;
    bytes internal _rawReply;

    /// @notice Successful verifications and the last caller, for assertions.
    uint256 public verifyCalls;
    address public lastRequester;

    event ReportVerified(bytes32 indexed feedId, address requester);

    error AccessForbidden();
    error VerifierNotFound(bytes32 configDigest);
    error BadVerification();
    error MockVerifierReverted();
    error MockFeeManagerNeedsParameters();

    constructor() {
        activeDigest[DIGEST] = true;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "VerifierProxy 2.0.0";
    }

    /*//////////////////////////////////////////////////////////////
                                 SWITCHES
    //////////////////////////////////////////////////////////////*/

    function setReverts(bool on) external {
        reverts = on;
    }

    function setResponse(bool on, bytes calldata response) external {
        responseSet = on;
        _response = response;
    }

    function setRawReply(bool on, bytes calldata reply) external {
        rawReplySet = on;
        _rawReply = reply;
    }

    function setFeeManager(address feeManager) external {
        s_feeManager = feeManager;
    }

    function setAccessController(address controller) external {
        s_accessController = controller;
    }

    function setAllowed(address caller, bool on) external {
        allowed[caller] = on;
    }

    function setDigest(bytes32 digest, bool active) external {
        activeDigest[digest] = active;
    }

    /*//////////////////////////////////////////////////////////////
                              VERIFIER PROXY
    //////////////////////////////////////////////////////////////*/

    function verify(bytes calldata payload, bytes calldata parameterPayload) external payable returns (bytes memory) {
        bytes memory reportData = _verify(payload, parameterPayload);
        if (rawReplySet) {
            bytes memory raw = _rawReply;
            assembly {
                return(add(raw, 0x20), mload(raw))
            }
        }
        return responseSet ? _response : reportData;
    }

    function verifyBulk(bytes[] calldata payloads, bytes calldata parameterPayload)
        external
        payable
        returns (bytes[] memory verifiedReports)
    {
        verifiedReports = new bytes[](payloads.length);
        for (uint256 i; i < payloads.length; ++i) {
            verifiedReports[i] = _verify(payloads[i], parameterPayload);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The simulated DON signature over a report.
    function signatureOf(bytes32[3] memory reportContext, bytes memory reportData) public pure returns (bytes32) {
        return keccak256(abi.encode(reportContext, keccak256(reportData)));
    }

    /// @notice A payload for `reportData` that verifies under {DIGEST}, shaped exactly like a Streams API `fullReport`.
    function sign(bytes memory reportData) external pure returns (bytes memory payload) {
        bytes32[3] memory ctx = [DIGEST, bytes32(uint256(0x0101)), bytes32(0)];
        bytes32[] memory rs = new bytes32[](1);
        bytes32[] memory ss = new bytes32[](1);
        rs[0] = signatureOf(ctx, reportData);
        ss[0] = bytes32(uint256(1));
        return abi.encode(ctx, reportData, rs, ss, bytes32(0));
    }

    function _verify(bytes calldata payload, bytes calldata parameterPayload) internal returns (bytes memory) {
        if (reverts) revert MockVerifierReverted();
        if (s_accessController != address(0) && !allowed[msg.sender]) revert AccessForbidden();
        if (s_feeManager != address(0) && parameterPayload.length < 32) revert MockFeeManagerNeedsParameters();
        (bytes32[3] memory ctx, bytes memory reportData, bytes32[] memory rs, bytes32[] memory ss,) =
            abi.decode(payload, (bytes32[3], bytes, bytes32[], bytes32[], bytes32));
        if (!activeDigest[ctx[0]]) revert VerifierNotFound(ctx[0]);
        if (rs.length != 1 || ss.length != 1 || rs[0] != signatureOf(ctx, reportData)) revert BadVerification();
        ++verifyCalls;
        lastRequester = msg.sender;
        // casting to 'bytes32' takes the first word of the report: its feed id, as the real Verifier reads it
        // forge-lint: disable-next-line(unsafe-typecast)
        emit ReportVerified(bytes32(reportData), msg.sender);
        return reportData;
    }
}
