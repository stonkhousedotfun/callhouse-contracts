// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {V2Ids} from "../../src/v2/interfaces/V2Ids.sol";

/// @notice Writes test/v2/fixtures/series-ids.json: series-id test vectors computed by V2Ids, the formula the
///         Clearinghouse uses. Read-only, no RPC, no broadcast.
///
///           forge script script/v2/EmitSeriesIds.s.sol
///
/// @dev WHY Solidity produces the vectors: the TypeScript mirrors (seriesId.ts in the indexer, web and keeper) must
///      compute exactly the ids the chain computes, and a vector file written by hand or by the TS code itself would
///      only prove the TS agrees with itself. export-abis.sh copies the file to callhouse/ops/fixtures/v2/, and
///      test/v2/InterfaceIds.t.sol re-checks every vector against V2Ids and an independent reference, and that the
///      file still holds exactly {vectors}. Output is deterministic: re-running changes nothing.
///
///      File shape: { "formula": string, "generatedBy": string, "vectors": [ { "underlying": "0x..", "isPut": bool,
///      "strike": "<decimal>", "expiry": number, "longId": "<decimal>", "shortId": "<decimal>" } ] }. uint256 values
///      are decimal STRINGS because a JS number cannot hold them; strikes are too (uint128 max). expiry is a number:
///      uint40 max (1_099_511_627_775) is below 2^53.
contract EmitSeriesIds is Script {
    string internal constant OUT = "test/v2/fixtures/series-ids.json";

    // Robinhood Chain 4663 Stock Tokens (ops/markets/tier1.json).
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    // 16:00 New York (EDT, 20:00Z) expiries.
    uint40 internal constant THU_2026_09_17 = 1_789_675_200; // daily
    uint40 internal constant FRI_2026_09_18 = 1_789_761_600; // weekly
    uint40 internal constant FRI_2026_09_25 = 1_790_366_400; // weekly

    struct Vector {
        address underlying;
        bool isPut;
        uint128 strike;
        uint40 expiry;
    }

    /// @notice The vector inputs, in file order. Real markets first, then the encoding edge cases.
    function vectors() public pure returns (Vector[] memory v) {
        v = new Vector[](13);
        // real markets: calls and puts, a daily and two weekly expiries, $215 / $231 / $355 strikes
        v[0] = Vector(NVDA, false, 215_000_000, THU_2026_09_17);
        v[1] = Vector(NVDA, true, 215_000_000, THU_2026_09_17);
        v[2] = Vector(NVDA, false, 231_000_000, FRI_2026_09_18);
        v[3] = Vector(NVDA, true, 231_000_000, FRI_2026_09_18);
        v[4] = Vector(NVDA, false, 231_000_000, FRI_2026_09_25);
        v[5] = Vector(TSLA, false, 355_000_000, FRI_2026_09_18);
        v[6] = Vector(TSLA, true, 355_000_000, FRI_2026_09_18);
        v[7] = Vector(TSLA, false, 355_000_000, FRI_2026_09_25);
        // edge cases: every field at 0 and at its type's max, so a mirror that packs, truncates or sign-extends a
        // field (or forgets that abi.encode left-pads address and bool to 32 bytes) fails a vector
        v[8] = Vector(address(0), false, 0, 0);
        v[9] = Vector(address(0), true, type(uint128).max, type(uint40).max);
        v[10] = Vector(NVDA, false, type(uint128).max, FRI_2026_09_18);
        v[11] = Vector(TSLA, true, 0, type(uint40).max);
        v[12] = Vector(address(type(uint160).max), true, 1, 1);
    }

    function run() public {
        Vector[] memory v = vectors();
        string[] memory rows = new string[](v.length);
        for (uint256 i; i < v.length; ++i) {
            uint256 longId = V2Ids.longIdOf(v[i].underlying, v[i].isPut, v[i].strike, v[i].expiry);
            string memory key = string.concat("vector", vm.toString(i));
            vm.serializeAddress(key, "underlying", v[i].underlying);
            vm.serializeBool(key, "isPut", v[i].isPut);
            vm.serializeString(key, "strike", vm.toString(uint256(v[i].strike)));
            vm.serializeUint(key, "expiry", v[i].expiry);
            vm.serializeString(key, "longId", vm.toString(longId));
            rows[i] = vm.serializeString(key, "shortId", vm.toString(V2Ids.shortIdOf(longId)));
        }
        vm.serializeString(
            "root",
            "formula",
            string.concat(
                "longId = uint256(keccak256(abi.encode(address underlying, bool isPut, uint128 strike, ",
                "uint40 expiry))) & ~1; shortId = longId | 1"
            )
        );
        vm.serializeString("root", "generatedBy", "callhouse-contracts script/v2/EmitSeriesIds.s.sol");
        string memory json = vm.serializeString("root", "vectors", rows);
        vm.writeJson(json, OUT);
        // writeJson ends the file at the closing brace; a committed text file ends with a newline
        vm.writeLine(OUT, "");
        console2.log("wrote %s vectors to %s", v.length, OUT);
    }
}
