// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";

/// @notice VerifyV2's pin dry run (PIN DRY RUN in script/v2/VerifyV2.s.sol): sends SettlementOracle.pin as the
///         Clearinghouse (a cheatcode prank, so simulation only) and reverts with the outcome, so nothing the pin wrote
///         stays. A contract of its own, in a file of its own: a script contract may not call itself (forge refuses
///         `address(this)` in scripts), and `forge script <file>` needs exactly one contract in its target file.
contract PinDryRun {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The outcome: whether the pin succeeded, and its return or revert data.
    error PinDryRunResult(bool ok, bytes result);

    /// @notice Always reverts with {PinDryRunResult}.
    function run(address oracle, address clearinghouse, address asset, uint40 expiry) external {
        VM.prank(clearinghouse);
        (bool ok, bytes memory result) = oracle.call(abi.encodeCall(SettlementOracle.pin, (asset, expiry)));
        revert PinDryRunResult(ok, result);
    }
}
