// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RewardsDistributor} from "../../src/v2/mm/RewardsDistributor.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @notice Deploys the SECOND `RewardsDistributor`: the LENDER instance, paying the $STONKHOUSE token (18 dp)
///         instead of USDG (6 dp). No `src/` change is needed -- the contract has been token-agnostic since C8-05,
///         and its reward-token getter is still literally named `usdg` (`src/v2/mm/RewardsDistributor.sol:50`),
///         which is left alone on purpose: renaming it would move the ABI.
///
///           DEPLOYER_PK=... V2_STONKHOUSE_TOKEN=0x... V2_ACCESS_MANAGER=0x... V2_TREASURY_SAFE=0x... \
///             forge script script/v2/DeployLenderRewards.s.sol --rpc-url "$RH_RPC" --broadcast
///
/// @dev IT TOUCHES NOTHING ELSE. This script does not deploy, wire or read the core v8 set; `DeployV8.s.sol`,
///      `DevDeploy.s.sol` and `VerifyV8.s.sol` are untouched by P8-05. A second instance of an already-exported
///      contract needs no ABI change either, so `abi-manifest.txt` and `export-abis.sh` stay as they are.
///
///      EVERY PREFLIGHT REVERTS WITH A NAMED REASON, and every one of them is a re-derivation rather than a
///      trusted constant. `V8-plan/impact/IMPACT-contracts.md` records the token as
///      `0xc2525b7c68b6d66dE5AABFEDC7B13314F389D5C4`; this script treats that as a DEFAULT AN OPERATOR MAY TYPE and
///      never as a verified fact, so it calls `decimals()` and `symbol()` on whatever address it is actually given
///      and refuses anything that is not an 18-decimal token called STONKHOUSE. A 6-decimal token would deploy a
///      lender distributor that silently pays a millionth of every reward.
///
///      THE SELECTOR MAP IS EMITTED, NOT WRITTEN. `script/v2/roles.v8.json` `.targets` is keyed by CONTRACT NAME
///      and every consumer resolves that name to an address through a hand-written table
///      (`DeployV8.s.sol:_targetAddress`, `VerifyV8.s.sol:1059 _targetOf`) that REVERTS on a name it does not know.
///      A second INSTANCE of a contract that is already a key therefore cannot be expressed in that file: a new key
///      for it would brick both scripts, because neither table knows the name.
///
///      T-182 corrects what this paragraph used to claim. It said "a 19th key", and that `test/v2/unit/
///      AccessMatrix.t.sol:48-49` pins counts that such a key would break. NEITHER IS TRUE ANY MORE, and both are
///      re-derived here rather than re-counted by hand: `roles.v8.json` `.targets` now names TWENTY-ONE targets,
///      and T-220 DELETED `EXPECTED_TARGETS` / `EXPECTED_MAPPED` from that test on purpose -- a literal counted
///      off the JSON and then compared with the JSON agrees with itself. The reason this script emits rather than
///      writes is the RESOLVER TABLES, which is a fact about `_targetAddress` and `_targetOf`, not about a count.
///      So this script leaves the manifest alone and PRINTS the three `setTargetFunctionRole` calls the Safe must
///      execute for the lender instance, with the roles READ from `.targets.RewardsDistributor` -- the same three
///      rows, on a different address. Nothing here types a selector or a role id.
contract DeployLenderRewards is V2DeployBase {
    /// @dev Exactly what the token must answer. `symbol()` is compared by hash; `decimals()` by value.
    string internal constant WANT_SYMBOL = "STONKHOUSE";
    uint8 internal constant WANT_DECIMALS = 18;

    /// @dev The manifest target whose three rows the lender instance reuses.
    string internal constant TARGET = "RewardsDistributor";

    struct Inputs {
        IERC20 token;
        address manager;
        address treasury;
    }

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.token = IERC20(vm.envAddress("V2_STONKHOUSE_TOKEN"));
        in_.manager = vm.envAddress("V2_ACCESS_MANAGER");
        in_.treasury = vm.envAddress("V2_TREASURY_SAFE");
    }

    /*//////////////////////////////////////////////////////////////
                                ENTRY
    //////////////////////////////////////////////////////////////*/

    function run() external returns (RewardsDistributor lender) {
        Inputs memory in_ = inputsFromEnv();
        // T-182 / F-DCON-08. THIS SCRIPT HAD NO CHAIN-ID GUARD AT ALL. Its only `block.chainid` was in the report
        // it writes AFTERWARDS, which records the chain it landed on rather than refusing the wrong one.
        // `DeployV8.s.sol` requires the expected chain before it creates anything and `DeployV2Batch.sh` already
        // exports `V2_EXPECT_CHAIN_ID` for every script it runs, so the value was there and simply unread: a
        // hand-run with the wrong `--rpc-url` deployed a real lender distributor on the wrong chain, and the only
        // sign was a chainId field in the report nobody diffs. Same default as DeployV8, same failure text.
        uint256 expectChainId = vm.envOr("V2_EXPECT_CHAIN_ID", CHAIN_ID_4663);
        require(
            block.chainid == expectChainId,
            string.concat("chain id ", vm.toString(block.chainid), ", expected ", vm.toString(expectChainId))
        );
        preflight(in_);

        uint256 pk = vm.envOr("DEPLOYER_PK", uint256(0));
        Signer memory deployer = pk != 0 ? Signer(pk, vm.addr(pk)) : Signer(0, vm.envAddress("V2_DEPLOYER"));

        _startBroadcast(deployer);
        lender = new RewardsDistributor(in_.token, in_.manager, in_.treasury);
        vm.stopBroadcast();

        // What was actually built, read back off the deployed contract rather than assumed from the arguments.
        require(address(lender.usdg()) == address(in_.token), "deployed lender does not hold the STONKHOUSE token");
        require(lender.authority() == in_.manager, "deployed lender is not on the v8 AccessManager");
        require(lender.treasury() == in_.treasury, "deployed lender does not pay the Treasury Safe");

        _report(in_, lender);
    }

    /*//////////////////////////////////////////////////////////////
                              PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @notice Everything that must be true before a single byte is deployed. Each failure names its own cause.
    function preflight(Inputs memory in_) public view {
        address token = address(in_.token);

        // 1. The token is a contract. `RewardsDistributor`'s own constructor refuses a code-less token
        //    (`UnsupportedAsset`, RewardsDistributor.sol:78), but a script that only finds out inside the
        //    constructor reports a bare selector to the operator instead of the variable that was wrong.
        _code(token, "V2_STONKHOUSE_TOKEN");

        // 2 and 3. Re-derived from the token itself, never from a document.
        uint8 decimals_ = IERC20Metadata(token).decimals();
        require(
            decimals_ == WANT_DECIMALS,
            string.concat(
                "V2_STONKHOUSE_TOKEN ",
                vm.toString(token),
                " reports ",
                vm.toString(uint256(decimals_)),
                " decimals, not 18: a 6-decimal token here would pay a millionth of every lender reward"
            )
        );
        string memory symbol_ = IERC20Metadata(token).symbol();
        require(
            _eq(symbol_, WANT_SYMBOL),
            string.concat("V2_STONKHOUSE_TOKEN ", vm.toString(token), " is ", symbol_, ", not ", WANT_SYMBOL)
        );

        // 3b. The flywheel already pins the token as the v4 pool's currency1. When that variable is present the two
        //     must agree: two different STONKHOUSE addresses in one environment is a typo, not a configuration.
        address pooled = vm.envOr("V2_TOKEN_POOL_CURRENCY1", address(0));
        require(
            pooled == address(0) || pooled == token,
            string.concat(
                "V2_TOKEN_POOL_CURRENCY1 ",
                vm.toString(pooled),
                " and V2_STONKHOUSE_TOKEN ",
                vm.toString(token),
                " are two different tokens"
            )
        );

        // 4. The authority is the v8 AccessManager, not an EOA and not some other manager. An EOA authority would
        //    make every `restricted` call revert and could never be replaced, because `setAuthority` is callable
        //    only by the authority itself (`src/v2/access/Managed.sol`).
        _code(in_.manager, "V2_ACCESS_MANAGER");
        require(
            AccessManager(in_.manager).ADMIN_ROLE() == 0
                && AccessManager(in_.manager).PUBLIC_ROLE() == type(uint64).max,
            string.concat("V2_ACCESS_MANAGER ", vm.toString(in_.manager), " does not answer as an AccessManager")
        );
        // 4b. And it is THE manager the rest of v8 is on, proven against the core instance when the environment
        //     names it, rather than against a pinned address.
        address core = vm.envOr("V2_REWARDS_DISTRIBUTOR", address(0));
        if (core != address(0) && core.code.length != 0) {
            require(
                RewardsDistributor(core).authority() == in_.manager,
                "V2_ACCESS_MANAGER is not the manager the core RewardsDistributor is already on"
            );
        }

        // 5. The treasury is the Safe. Mirrors DeployV8.s.sol:302-303: on chain 4663 the treasury must be the Safe,
        //    because it is the only address `defund` can ever pay.
        _code(in_.treasury, "V2_TREASURY_SAFE");

        // 6. Three different addresses.
        require(
            token != in_.manager && token != in_.treasury && in_.manager != in_.treasury,
            "V2_STONKHOUSE_TOKEN, V2_ACCESS_MANAGER and V2_TREASURY_SAFE must be three different addresses"
        );

        _ok("preflight: 18-decimal STONKHOUSE, an AccessManager authority and a Safe treasury");
    }

    /*//////////////////////////////////////////////////////////////
                      THE SELECTOR MAP, AS CALLDATA
    //////////////////////////////////////////////////////////////*/

    /// @notice The `setTargetFunctionRole` calls the Safe must execute so the lender instance carries the same
    ///         three rows the core instance does. One call per signature: the manager's own signature takes an
    ///         array, and one selector per call keeps each row independently reviewable in the Safe UI.
    /// @dev Roles and signatures are READ from `.targets.RewardsDistributor`; nothing here is typed.
    function mappingCalls(address lender) public view returns (Call[] memory calls) {
        string memory json = rolesJson();
        string[] memory sigs = targetSigs(json, TARGET);
        require(sigs.length != 0, "roles.v8.json lists no selectors for RewardsDistributor");
        calls = new Call[](sigs.length);
        for (uint256 i; i < sigs.length; ++i) {
            string memory roleName = roleNameOfSig(json, TARGET, sigs[i]);
            bytes4[] memory one = new bytes4[](1);
            one[0] = selectorOf(sigs[i]);
            calls[i] = Call({
                to: address(0), // filled by the caller: the manager address is an input, not a manifest value
                data: abi.encodeCall(AccessManager.setTargetFunctionRole, (lender, one, roleIdOf(json, roleName))),
                what: string.concat(TARGET, "(lender).", sigs[i], " -> ", roleName)
            });
        }
    }

    /*//////////////////////////////////////////////////////////////
                               REPORT
    //////////////////////////////////////////////////////////////*/

    function _report(Inputs memory in_, RewardsDistributor lender) internal {
        Call[] memory calls = mappingCalls(address(lender));

        console2.log("");
        console2.log("THE SAFE MUST STILL MAP THE LENDER INSTANCE. roles.v8.json cannot carry a second instance of a");
        console2.log("contract it already keys, so these are not in the manifest and DeployV8 will not send them:");
        for (uint256 i; i < calls.length; ++i) {
            console2.log(string.concat("  ", calls[i].what));
            console2.log(string.concat("    to   ", vm.toString(in_.manager)));
            console2.log(string.concat("    data ", vm.toString(calls[i].data)));
        }
        console2.log("");

        string[] memory rows = new string[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            string memory key = string.concat("call", vm.toString(i));
            vm.serializeString(key, "what", calls[i].what);
            vm.serializeAddress(key, "to", in_.manager);
            rows[i] = vm.serializeBytes(key, "data", calls[i].data);
        }

        vm.serializeAddress("out", "lenderRewardsDistributor", address(lender));
        vm.serializeAddress("out", "token", address(in_.token));
        vm.serializeAddress("out", "accessManager", in_.manager);
        vm.serializeAddress("out", "treasury", in_.treasury);
        vm.serializeUint("out", "deployBlock", block.number);
        vm.serializeUint("out", "chainId", block.chainid);
        string memory json = vm.serializeString("out", "pendingTargetFunctionRole", rows);
        console2.log(json);

        string memory outPath = vm.envOr("V2_LENDER_DEPLOY_OUT", string(""));
        if (bytes(outPath).length != 0) {
            vm.writeJson(json, outPath);
            console2.log("wrote %s", outPath);
        }
    }
}
