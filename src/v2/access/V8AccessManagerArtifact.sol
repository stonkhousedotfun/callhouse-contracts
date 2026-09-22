// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// The one AccessManager of INTERFACE_VERSION 8 is OpenZeppelin v5.7.0's, UNMODIFIED: no subclass, no wrapper, no
// dependency bump. It is already in `lib/`, but solc only compiles what something imports, so without this line
// there is no `out/AccessManager.sol/AccessManager.json` for `DeployV8` to deploy from, for `VerifyV8` to compare
// runtime bytecode against, or for `script/v2/export-abis.sh` to publish as `ops/abis/v2/AccessManager.json` -- which
// is what the indexer and the monitor decode `OperationScheduled`, `OperationExecuted`, `OperationCanceled`,
// `RoleGranted` and `RoleRevoked` with. AccessManager's `RoleGranted(uint64,address,uint32,uint48,bool)` shares its
// NAME with AccessControl's `RoleGranted(bytes32,address,address)` and has a different topic, so a handler written
// against the v7 ABI silently never fires.
//
// This file declares nothing of its own on purpose: importing the contract is the whole job, and anything declared
// here would be a modification of the access model the audit scope treats as unmodified OpenZeppelin.
//
// T-543 CHECKED THE SCANNER BLIND SPOT AGAINST THIS FILE, and there is nothing here to be blind to.
// The C8-11 ledger suspicion worried that `script/v2/scan-v2-contracts.awk` and the independent
// derivation it was cross-checked against are blind in the SAME place -- both match
// `^[[:space:]]*contract`, so a declaration with anything between line-start and the keyword, "or a
// declaration produced by a macro-ish import shim like V8AccessManagerArtifact.sol", would be
// silently unpublishable. This file was named as that hypothetical shim. It is not one: it declares
// NOTHING, by the design stated just below, so no declaration of its own can go unseen. Measured
// rather than reasoned -- the scanner emits zero `D|` records for this file and one for
// `src/v2/access/Managed.sol`, so the zero is a real absence and not a scanner that failed to open it
// (the `S|` receipt is what distinguishes those, see scan-v2-contracts.awk:8-13).
//
// The blind spot ITSELF is real, and it is already written down at its own site:
// `script/v2/scan-v2-contracts.awk:15-21`, under "WHAT THIS CANNOT SEE, stated because an
// undocumented blind spot is how the defect it guards was born", whose first bullet is exactly this
// worry and cross-references the same limit in `script/v2/export-abis.sh`. Nothing to fix here.
//
// forge-lint: disable-next-line(unused-import)
// solhint-disable-next-line no-unused-import
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
