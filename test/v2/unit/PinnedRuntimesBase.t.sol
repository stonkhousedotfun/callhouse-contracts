// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";

/// @notice Reads `script/artifacts/v2-4663` (C3-101): the runtimes of the v2 set live on chain 4663, pinned from the
///         commit that deployed it by `script/v2/pin-deployed.sh`, and the manifest that proves them against the chain.
///         Shared by the offline unit suite (VerifyV2Pinned.t.sol) and the fork suite (PinnedRuntimesFork.t.sol).
abstract contract PinnedRuntimesBase is Test {
    /// @dev One recorded immutable word of the live runtime. forge's JSON parser hands struct fields over in
    ///      alphabetical order, hence `length, start, value`.
    struct Word {
        uint256 length;
        uint256 start;
        bytes32 value;
    }

    /// @dev One `{start, length}` immutable reference of an artifact, fields in the same alphabetical order.
    struct Ref {
        uint256 length;
        uint256 start;
    }

    string internal constant MANIFEST = "script/artifacts/v2-4663/manifest.json";

    /// @dev VerifyV2's registry names, in its `_set` order (the deploy order).
    function _names() internal pure returns (string[13] memory) {
        return [
            "expiryCalendar",
            "sources.chainlink",
            "sources.univ3",
            "sources.dataStreams",
            "settlementOracle",
            "clearinghouse",
            "orderBook",
            "keeperRewards",
            "autoRoller",
            "payoutAdapter",
            "makerRegistry",
            "makerVault",
            "rewardsDistributor"
        ];
    }

    function _manifest() internal view returns (string memory) {
        return vm.readFile(MANIFEST);
    }

    function _entry(string memory name) internal pure returns (string memory) {
        return string.concat(".contracts['", name, "']");
    }

    function _pinnedAddress(string memory m, string memory name) internal pure returns (address) {
        return vm.parseJsonAddress(m, string.concat(_entry(name), ".address"));
    }

    function _pinnedPath(string memory m, string memory name) internal pure returns (string memory) {
        return vm.parseJsonString(m, string.concat(_entry(name), ".artifact"));
    }

    /// @dev The recorded immutable words; a contract without immutables records an empty list, which does not decode
    ///      as a struct array, so it is recognised by `maskedBytes == 0`.
    function _words(string memory m, string memory name) internal pure returns (Word[] memory) {
        if (vm.parseJsonUint(m, string.concat(_entry(name), ".maskedBytes")) == 0) return new Word[](0);
        return abi.decode(vm.parseJson(m, string.concat(_entry(name), ".immutables")), (Word[]));
    }

    /// @dev The pinned artifact's runtime, immutable slots still zero.
    function _artifactRuntime(string memory m, string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.parseJsonString(vm.readFile(_pinnedPath(m, name)), ".deployedBytecode.object"));
    }

    /// @dev The runtime the chain holds: the pinned artifact with the recorded immutable words written in.
    function _liveRuntime(string memory m, string memory name) internal view returns (bytes memory code) {
        code = _artifactRuntime(m, name);
        Word[] memory w = _words(m, name);
        for (uint256 i; i < w.length; ++i) {
            assertEq(w[i].length, 32, "every immutable is one word");
            assertLe(w[i].start + 32, code.length, "the word lies inside the runtime");
            bytes32 value = w[i].value;
            uint256 start = w[i].start;
            assembly ("memory-safe") {
                mstore(add(add(code, 32), start), value)
            }
        }
    }

    /// @dev The pinned set as V2DeployBase.Contracts.
    function _pinnedSet(string memory m) internal pure returns (V2DeployBase.Contracts memory c) {
        c.expiryCalendar = _pinnedAddress(m, "expiryCalendar");
        c.chainlinkSource = _pinnedAddress(m, "sources.chainlink");
        c.univ3Source = _pinnedAddress(m, "sources.univ3");
        c.dataStreamsSource = _pinnedAddress(m, "sources.dataStreams");
        c.settlementOracle = _pinnedAddress(m, "settlementOracle");
        c.clearinghouse = _pinnedAddress(m, "clearinghouse");
        c.orderBook = _pinnedAddress(m, "orderBook");
        c.keeperRewards = _pinnedAddress(m, "keeperRewards");
        c.autoRoller = _pinnedAddress(m, "autoRoller");
        c.payoutRouter = _pinnedAddress(m, "payoutAdapter"); // C8-10A: the registry KEY is kept, the field is now payoutRouter (03-INTERFACES 4)
        c.makerRegistry = _pinnedAddress(m, "makerRegistry");
        c.makerVault = _pinnedAddress(m, "makerVault");
        c.rewardsDistributor = _pinnedAddress(m, "rewardsDistributor");
    }
}
