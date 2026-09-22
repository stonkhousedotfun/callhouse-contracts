// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {PinnedRuntimesBase} from "../unit/PinnedRuntimesBase.t.sol";
import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";

import {ForkFloor} from "./ForkFloor.sol";

/// @notice C3-101 against the LIVE chain-4663 set: from this checkout, VerifyV8's bytecode group passes on all 13
///         deployed addresses because it compares them with the runtimes pinned from the commit that deployed them
///         (script/artifacts/v2-4663), not with this checkout's `out/`. Every live code hash and immutable word is the
///         one the manifest recorded, and the manifest's addresses are the published registry's
///         (callhouse ops/markets/tier1.json `v2.contracts`, deployBlock 65780341).
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/PinnedRuntimesFork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as the other fork suites do.
contract PinnedRuntimesForkTest is PinnedRuntimesBase {
    VerifyV8 internal verify;
    string internal m;

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        verify = new VerifyV8();
        m = _manifest();
    }

    /// @dev The published live set (callhouse registry `v2.contracts`, written back by the deploy on 2026-09-18),
    ///      typed here so the manifest's addresses are checked against something the manifest did not produce.
    function _published() internal pure returns (V2DeployBase.Contracts memory c) {
        c.expiryCalendar = 0xd0fCeD9Ee6F533aA900BEe8d0523eF4867a5784a;
        c.chainlinkSource = 0x1a595B2F836b7B76e71C0F85ADA6186ef16fB96A;
        c.univ3Source = 0x030f05E856c79bC215c5683DC201473e4F88a155;
        c.dataStreamsSource = 0xeC049Df6F9908374940065cec593Ac83fc1db4d2;
        c.settlementOracle = 0xb205984b5F2F9010c2bD8aCA46d946Fe1c4F2A54;
        c.clearinghouse = 0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424;
        c.orderBook = 0x9fcAe743C3fA0aEC7DB9b1d01e86464b85759942;
        c.keeperRewards = 0xFB409E6E253bcC12a65ED02B9D5aa3cAbF8f63f3;
        c.autoRoller = 0xca76e9d57992904a14E31C5103454A4906ebFfee;
        c.payoutRouter = 0xf529CE3708bd2002D6bC974dFC0501c92aE72c30; // C8-10A: field renamed, live v7 address unchanged
        c.makerRegistry = 0xED816A81F8e311F78496c63c66abaA93A996cD3B;
        c.makerVault = 0x5EA899580B3dEB99c6866c7CD14dEDc913C8C1d0;
        c.rewardsDistributor = 0xc2Eea33F12e26662c66D632915fD75BCEA13BF4f;
    }

    /// VerifyV8's bytecode group, run from this checkout against the live set: 13 ok, no FAIL.
    function test_fork_verifyBytecodeOfTheLiveSet() public onlyFork {
        V2DeployBase.Contracts memory c = _published();
        assertEq(abi.encode(_pinnedSet(m)), abi.encode(c), "the manifest pins the published registry's 13 addresses");
        (uint256 passed, uint256 failed) = verify.checkBytecode(c);
        console2.log("fork block %s: VerifyV8 bytecode group %s ok, %s FAIL", block.number, passed, failed);
        assertEq(passed, 13, "13 ok");
        assertEq(failed, 0, "no FAIL");
    }

    /// Exact, per address: pinned under its name, the live code hash and size are the recorded ones, every recorded
    /// immutable word is the live word, and the runtime equals the pinned artifact outside those slots. Logged too:
    /// whether this checkout's `out/` would also match (the drift that made pinning necessary).
    function test_fork_liveRuntimesAreThePinnedOnes() public onlyFork {
        string[13] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            string memory e = _entry(names[i]);
            address a = _pinnedAddress(m, names[i]);
            (bool pinned, string memory path,) = verify.pinnedArtifact(names[i], a);
            assertTrue(pinned, names[i]);
            assertEq(a.code.length, vm.parseJsonUint(m, string.concat(e, ".codeSize")), "code size");
            assertEq(a.codehash, vm.parseJsonBytes32(m, string.concat(e, ".codeHash")), "code hash");
            assertEq(keccak256(a.code), keccak256(_liveRuntime(m, names[i])), "artifact + recorded words == chain");
            Word[] memory w = _words(m, names[i]);
            bytes memory code = a.code;
            for (uint256 k; k < w.length; ++k) {
                bytes32 live;
                uint256 start = w[k].start;
                assembly ("memory-safe") {
                    live := mload(add(add(code, 32), start))
                }
                assertEq(live, w[k].value, "immutable word");
            }
            assertTrue(verify.runtimeMatches(a, path), "runtime == pinned artifact outside immutable slots");

            string memory contractName = vm.parseJsonString(m, string.concat(e, ".contract"));
            string memory compiled = string.concat("out/", contractName, ".sol/", contractName, ".json");
            console2.log(
                string.concat(
                    names[i],
                    " ",
                    vm.toString(a),
                    ": pinned match; this checkout's out/ ",
                    verify.runtimeMatches(a, compiled) ? "also matches" : "DIFFERS (pin needed)"
                )
            );
        }
    }

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424`, an address this suite's own tests read.
    ///      The live Clearinghouse, mirrored from this file's own `:43` rather than retyped: its addresses are assigned
    ///      inside a function, so there is no constant to name here.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_pinnedRuntimesForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424, "PinnedRuntimesFork");
    }
}
