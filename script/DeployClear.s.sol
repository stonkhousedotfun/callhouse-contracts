// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";

/// @notice OPTIONAL: deploys our own ValoremOptionsClearinghouse from the vendored upstream artifact.
/// @dev The vault is agnostic about which clearinghouse it settles on (decision D16): the default in
///      script/Deploy.s.sol is Overcall's unmodified instance at 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0,
///      whose `feeTo` key holds only the 15 bps fee switch. This script exists so that dependency can be
///      removed entirely: deploy an instance whose `feeTo` is the admin Safe (owner decision 2026-09-14;
///      `HandoverAdmin.s.sol` never moves it), then pass its address to Deploy.s.sol as `CLEARINGHOUSE`.
///      Run with:
///        DEPLOYER_PK=... CLEAR_FEE_TO=<admin Safe> forge script script/DeployClear.s.sol --rpc-url $RH_RPC --broadcast
///
///      THE ARTIFACT IS UPSTREAM, NOT OURS. `script/artifacts/ValoremOptionsClearinghouse.json` is a copy of
///      `test/fixtures/valorem/ValoremOptionsClearinghouse.json`: valorem-labs-inc/clear @ 6436c823, solc
///      0.8.16, optimizer 200, viaIR off, evm london, whose clearinghouse source is byte-identical to the
///      Sourcify exact-match source of the 4663 deployment (integrations/valorem.md §2). It is kept under
///      script/ so a deploy script never reads test fixtures, and the two files are asserted identical by
///      test/unit/Fixtures.t.sol. The constructor is `(address _feeTo, address _tokenURIGenerator)` and
///      reverts `InvalidAddress` for a zero in either slot.
///
///      THE URI GENERATOR. `tokenURIGenerator` is reached by `uri()` alone; write, exercise, redeem and
///      Seaport never touch it. The default is Overcall's generator at 0xE53cCB924d27f421a91b59087587fD866C5d64c7
///      (same block, same deployer as their Clear; Sourcify exact match), which renders metadata for any
///      Clear instance. `feeTo` can later move it with `setTokenURIGenerator` if we deploy our own.
contract DeployClear is Script {
    string internal constant ARTIFACT = "script/artifacts/ValoremOptionsClearinghouse.json";
    address internal constant OVERCALL_URI_GENERATOR = 0xE53cCB924d27f421a91b59087587fD866C5d64c7;

    function run() external returns (IValoremClear clear) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address feeTo = vm.envAddress("CLEAR_FEE_TO");
        address uriGenerator = vm.envOr("TOKEN_URI_GENERATOR", OVERCALL_URI_GENERATOR);
        require(feeTo != address(0), "CLEAR_FEE_TO is zero");
        require(uriGenerator != address(0), "TOKEN_URI_GENERATOR is zero");
        require(uriGenerator.code.length > 0, "TOKEN_URI_GENERATOR has no code on this chain");

        vm.startBroadcast(pk);
        clear = IValoremClear(deployCode(ARTIFACT, abi.encode(feeTo, uriGenerator)));
        vm.stopBroadcast();

        // The two facts Deploy.s.sol's preflight and the vault's fee gate rely on, plus the admin wiring.
        require(clear.feeBps() == 15, "deployed Clear feeBps != 15");
        require(!clear.feesEnabled(), "deployed Clear has the fee switch ON");
        require(clear.feeTo() == feeTo, "deployed Clear feeTo mismatch");
        require(clear.tokenURIGenerator() == uriGenerator, "deployed Clear tokenURIGenerator mismatch");
        require(clear.supportsInterface(0xd9b67a26), "deployed Clear is not ERC-1155");

        console2.log("ValoremOptionsClearinghouse", address(clear));
        console2.log("feeTo (fee switch holder)  ", feeTo);
        console2.log("tokenURIGenerator          ", uriGenerator);
        console2.log("runtime bytes              ", address(clear).code.length);
        console2.log("NEXT: CLEARINGHOUSE=<this address> forge script script/Deploy.s.sol ...");
    }
}
