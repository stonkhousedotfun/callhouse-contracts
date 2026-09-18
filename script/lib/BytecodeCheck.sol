// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

/// @notice Runtime-bytecode comparison helpers for the post-deploy verifiers: a deployed contract against
///         this checkout's `out/` artifact, byte for byte, with only link sites and immutable slots masked.
/// @dev Copied from `script/Verify.s.sol` (the pooled Vault's verifier, which is not edited so its 67..76
///      recorded check counts stay exact) and generalised to one linked library per artifact, which is
///      what `src/solo/` needs: `WriterAccount` links `ValoremLib` and `AccountFactory` links nothing.
///      Used by `script/VerifySolo.s.sol` only.
///
///      WHY BYTE FOR BYTE. A getter can show a parameter; only the runtime proves the logic and every
///      compiled-in hard cap ({Policy}) are this commit's. Three kinds of byte are masked, each checked
///      separately by the caller: the 20-byte library link sites (each must hold the expected library),
///      the immutable slots (each read through its getter), and a via-IR public library's own
///      deploy-address word (must equal that library's address).
abstract contract BytecodeCheck is Script {
    /// @dev One `{start, length}` reference from the artifact; forge's JSON parser emits object keys in
    ///      alphabetical order, hence `length` before `start`.
    struct Ref {
        uint256 length;
        uint256 start;
    }

    /// @dev The artifact's runtime for a contract with NO link placeholders (parseBytes rejects `__$..$__`).
    function _artifactRuntime(string memory json) internal pure returns (bytes memory) {
        return vm.parseBytes(vm.parseJsonString(json, ".deployedBytecode.object"));
    }

    /// @dev Replaces every `__$<34 hex>$__` link placeholder in the artifact's hex with zeros so it parses,
    ///      masks those 20 bytes, and counts how many of the deployed bytes there are the library the
    ///      placeholder names. `seen` is every placeholder found, `ok` those whose deployed bytes equal
    ///      `lib`; a placeholder naming another library counts in `seen` only.
    function _expectedWithLinks(string memory json, bytes memory deployed, string memory libName, address lib)
        internal
        pure
        returns (bytes memory want, bool[] memory mask, uint256 ok, uint256 seen)
    {
        bytes memory hex_ = bytes(vm.parseJsonString(json, ".deployedBytecode.object"));
        bytes memory libTag = _placeholderTag(libName);
        uint256 offsetCount;
        uint256[] memory offsets = new uint256[](16);
        bool[] memory named = new bool[](16);

        for (uint256 i = 2; i + 40 <= hex_.length; i++) {
            if (hex_[i] != "_" || hex_[i + 1] != "_" || hex_[i + 2] != "$") continue;
            bytes memory tag = new bytes(34);
            for (uint256 t; t < 34; t++) {
                tag[t] = hex_[i + 3 + t];
            }
            named[offsetCount] = keccak256(tag) == keccak256(libTag);
            offsets[offsetCount++] = (i - 2) / 2;
            for (uint256 c; c < 40; c++) {
                hex_[i + c] = "0";
            }
            i += 39;
        }

        want = vm.parseBytes(string(hex_));
        mask = new bool[](want.length);
        for (uint256 n; n < offsetCount; n++) {
            seen++;
            for (uint256 k; k < 20; k++) {
                mask[offsets[n] + k] = true;
            }
            if (named[n] && deployed.length >= offsets[n] + 20) {
                if (address(bytes20(_word(deployed, offsets[n]))) == lib) ok++;
            }
        }
    }

    /// @dev Number of link sites the artifact records for one library. Read from `linkReferences`, never
    ///      hard-coded: every new library call site adds one, and a stale constant would make a
    ///      byte-perfect deployment FAIL (and train operators to ignore the line).
    function _linkSites(string memory json, string memory file, string memory lib) internal view returns (uint256) {
        string memory key = string.concat(".deployedBytecode.linkReferences['", file, "'].", lib);
        if (!vm.keyExistsJson(json, key)) return 0;
        return abi.decode(vm.parseJson(json, key), (Ref[])).length;
    }

    /// @dev Byte offset of the first link site of one library in the artifact's runtime.
    function _firstLinkSite(string memory json, string memory file, string memory lib) internal pure returns (uint256) {
        return
            vm.parseJsonUint(json, string.concat(".deployedBytecode.linkReferences['", file, "'].", lib, "[0].start"));
    }

    /// @dev solc's placeholder is the first 34 hex characters of keccak256 of the fully qualified name.
    function _placeholderTag(string memory fullyQualified) internal pure returns (bytes memory tag) {
        bytes memory h = bytes(vm.toString(keccak256(bytes(fullyQualified))));
        tag = new bytes(34);
        for (uint256 i; i < 34; i++) {
            tag[i] = h[2 + i];
        }
    }

    /// @dev Masks every immutable slot the artifact records, whatever the immutable's id.
    function _maskImmutables(string memory json, bool[] memory mask) internal pure {
        string[] memory ids = vm.parseJsonKeys(json, ".deployedBytecode.immutableReferences");
        for (uint256 i; i < ids.length; i++) {
            Ref[] memory refs = abi.decode(
                vm.parseJson(json, string.concat(".deployedBytecode.immutableReferences.", ids[i])), (Ref[])
            );
            for (uint256 r; r < refs.length; r++) {
                for (uint256 k; k < refs[r].length; k++) {
                    mask[refs[r].start + k] = true;
                }
            }
        }
    }

    /// @dev A via-IR public library stores its own address in an immutable for call protection; that word
    ///      must equal the library's address and everything else must match the artifact.
    /// @return hasCode  the library address holds code at all
    /// @return selfOk   every deploy-address word equals `lib`
    /// @return runtimeOk the runtime equals the artifact outside those words
    function _libraryRuntime(string memory path, address lib)
        internal
        view
        returns (bool hasCode, bool selfOk, bool runtimeOk)
    {
        bytes memory code = lib.code;
        if (code.length == 0) return (false, false, false);
        hasCode = true;
        string memory json = vm.readFile(path);
        bytes memory want = _artifactRuntime(json);
        bool[] memory mask = new bool[](want.length);
        Ref[] memory refs =
            abi.decode(vm.parseJson(json, ".deployedBytecode.immutableReferences.library_deploy_address"), (Ref[]));
        selfOk = refs.length > 0;
        for (uint256 r; r < refs.length; r++) {
            for (uint256 k; k < refs[r].length; k++) {
                mask[refs[r].start + k] = true;
            }
            if (code.length >= refs[r].start + 32) {
                selfOk = selfOk && uint256(_word(code, refs[r].start)) == uint256(uint160(lib));
            } else {
                selfOk = false;
            }
        }
        runtimeOk = _equalMasked(code, want, mask);
    }

    function _equalMasked(bytes memory got, bytes memory want, bool[] memory mask) internal pure returns (bool) {
        if (got.length != want.length) return false;
        for (uint256 i; i < got.length; i++) {
            if (!mask[i] && got[i] != want[i]) return false;
        }
        return true;
    }

    function _word(bytes memory b, uint256 offset) internal pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(b, 32), offset))
        }
    }
}
