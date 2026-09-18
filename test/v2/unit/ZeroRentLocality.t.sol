// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployV2Fixture} from "./DeployV2Fixture.t.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {VerifyV2} from "../../../script/v2/VerifyV2.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice `RegisterMarkets` as a `forge script` run sees itself: {V2DeployBase._inTestContext} false.
/// @dev The override only ever TIGHTENS -- nothing in this repository overrides `_inTestContext` to true -- so
///      pointing `forge script` at this double refuses exactly like pointing it at the real script.
contract ScriptRunRegisterMarkets is RegisterMarkets {
    function _inTestContext() internal pure override returns (bool) {
        return false;
    }
}

/// @notice `VerifyV2` as a `forge script` run sees itself. See {ScriptRunRegisterMarkets}.
contract ScriptRunVerifyV2 is VerifyV2 {
    function _inTestContext() internal pure override returns (bool) {
        return false;
    }
}

/// @notice The production {V2DeployBase._inTestContext}, callable from a test.
contract ContextProbe is V2DeployBase {
    function inTestContext() external view returns (bool) {
        return _inTestContext();
    }

    function allowed(bool requested) external view returns (bool) {
        return zeroRentAllowed(requested);
    }
}

/// @notice The zero-rent opt-in is a TEST-ONLY code path: no `forge script` run reaches it, whatever the RPC, the
///         chain id, the broadcast state or the environment, and the fixtures keep it.
/// @dev The hole this closes (codex review, accepted 2026-09-17, DECISIONS-2026-09-17 §11): before this,
///      `V2_ALLOW_ZERO_RENT` was refused only by `DeployV2Batch.sh` when combined with `--broadcast`, so a direct
///      `forge script RegisterMarkets --rpc-url <live 4663> --broadcast` with the variable exported could still
///      register a market that charges its writers nothing, and a read-only `VerifyV2` against live 4663 could still
///      accept one. A "this is the local harness" marker cannot prove RPC locality; the forge subcommand can, and a
///      fork of 4663 keeps chain id 4663 so the chain id alone proves nothing.
///
///      The ENVIRONMENT half of the same guard lives in test/v2/unit/DeployV2Env.t.sol, which owns the `V2_*`
///      process environment (it is the one suite allowed to `vm.setEnv` those names).
contract ZeroRentLocalityTest is DeployV2Fixture {
    V2DeployBase.Contracts internal d;

    /// @dev Robinhood Chain, and what an anvil fork of it also reports.
    uint256 internal constant LIVE_CHAIN_ID = 4663;

    ScriptRunRegisterMarkets internal scriptRegister;
    ScriptRunVerifyV2 internal scriptVerify;
    ContextProbe internal probe;

    function setUp() public override {
        super.setUp();
        d = _deploy();
        scriptRegister = new ScriptRunRegisterMarkets();
        scriptVerify = new ScriptRunVerifyV2();
        probe = new ContextProbe();
    }

    /*//////////////////////////////////////////////////////////////
                        (a) A BROADCASTING REGISTER
    //////////////////////////////////////////////////////////////*/

    /// @notice A `RegisterMarkets` run that opted in, on the live chain id, while broadcasting: refused.
    /// @dev The refusal lands in the preflight, before `_execute` starts a broadcast of its own, so nothing is sent.
    function test_register_scriptRunBroadcastingCannotOptIn() public {
        vm.chainId(LIVE_CHAIN_ID);
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = 0; // TSLA
        in_.allowZeroRent = true;

        vm.startBroadcast(admin);
        vm.expectRevert(bytes(_zeroRentRefusal("TSLA")));
        scriptRegister.runWith(in_, _signer(admin));
        vm.stopBroadcast();

        assertEq(
            Clearinghouse(d.clearinghouse).market(address(tsla)).strikeTick, 0, "TSLA was not registered at zero rent"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    (b) A REGISTER THAT ONLY SIMULATES
    //////////////////////////////////////////////////////////////*/

    /// @notice The same run WITHOUT broadcasting, on the live chain id: still refused.
    /// @dev A dry run is how an operator finds out whether a broadcast would go through, so it has to answer the same
    ///      way; and the guard is the subcommand, not the broadcast state, so there is nothing left to toggle.
    function test_register_scriptRunOnTheLiveChainCannotOptIn() public {
        vm.chainId(LIVE_CHAIN_ID);
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = 0;
        in_.allowZeroRent = true;
        vm.expectRevert(bytes(_zeroRentRefusal("TSLA")));
        scriptRegister.runWith(in_, _signer(admin));
    }

    /// @notice And on a chain id that is NOT 4663: the guard is the forge subcommand, never the chain.
    /// @dev An anvil fork of 4663 reports 4663 and a devnet reports whatever it was started with, so a chain-id test
    ///      would be both too strict (it would refuse a devnet) and too loose (it would accept a fork of the live
    ///      chain, and a fork's RPC is one flag away from the live one).
    function test_register_scriptRunOffChainIdCannotOptInEither() public {
        vm.chainId(31_337);
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = 0;
        in_.allowZeroRent = true;
        vm.expectRevert(bytes(_zeroRentRefusal("TSLA")));
        scriptRegister.runWith(in_, _signer(admin));
    }

    /*//////////////////////////////////////////////////////////////
                        (c) A READ-ONLY VERIFY
    //////////////////////////////////////////////////////////////*/

    /// @notice `VerifyV2` against the live chain id FAILs a live market at zero rent however the run opted in.
    /// @dev VerifyV2 broadcasts nothing, so the batch's `--broadcast` refusal never covered it at all: this is the
    ///      half of the hole that could have signed off a zero-rent market already on chain.
    function test_verify_scriptRunOnTheLiveChainFailsAZeroRentMarket() public {
        _setTslaRentToZeroOnChain();
        vm.chainId(LIVE_CHAIN_ID);

        VerifyV2.Inputs memory in_ = _verifyInputs(d, false);
        in_.mintFeePpm[1] = 0; // the registry asks for 0 as well: still not a drift line
        in_.allowZeroRent = true;
        (, uint256 failed) = scriptVerify.check(in_);
        assertEq(failed, 1, "a script run FAILs TSLA at zero rent even though it opted in");

        in_.allowZeroRent = false;
        (, failed) = scriptVerify.check(in_);
        assertEq(failed, 1, "and the same without the opt-in: the opt-in changed nothing");
    }

    /*//////////////////////////////////////////////////////////////
                    (d) THE LOCAL HARNESS STILL WORKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Under `forge test` the opt-in still works, which is the one place it is legitimate.
    /// @dev The fixtures register a zero-rent market and verify it clean, exactly as before this guard.
    function test_fixtures_keepTheOptIn() public {
        assertTrue(probe.inTestContext(), "forge test is the TestGroup context");
        assertTrue(probe.allowed(true), "and the opt-in is honoured there");
        assertFalse(probe.allowed(false), "a run that did not ask never opts in");

        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = 0;
        in_.allowZeroRent = true;
        registerScript.runWith(in_, _signer(admin));
        assertEq(Clearinghouse(d.clearinghouse).market(address(tsla)).mintFeePpm, 0, "the fixture registered at 0");

        VerifyV2.Inputs memory v = _verifyInputs(d, false);
        v.mintFeePpm[1] = 0;
        v.allowZeroRent = true;
        (, uint256 failed) = verifyScript.check(v);
        assertEq(failed, 0, "and the fixture verifies clean");
    }

    /// @notice The same fixture inputs through a script run: refused at register and FAILed at verify.
    /// @dev One test, both sides, so the difference between the two contexts is the only variable.
    function test_theOnlyDifferenceIsTheForgeSubcommand() public {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = 0;
        in_.allowZeroRent = true;
        registerScript.runWith(in_, _signer(admin)); // test context: through

        VerifyV2.Inputs memory v = _verifyInputs(d, false);
        v.mintFeePpm[1] = 0;
        v.allowZeroRent = true;
        (, uint256 testFailed) = verifyScript.check(v);
        (, uint256 scriptFailed) = scriptVerify.check(v);
        assertEq(testFailed, 0, "the fixtures accept it");
        assertEq(scriptFailed, 1, "a script run does not");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Register both markets, then drop TSLA's rent to 0 on chain, so the verifier meets a live zero-rent market.
    function _setTslaRentToZeroOnChain() internal {
        registerScript.runWith(_registerInputs(d), _signer(admin));
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        V2Types.MarketConfig memory cfg = ch.market(address(tsla));
        cfg.mintFeePpm = 0;
        vm.prank(admin);
        ch.setMarketConfig(address(tsla), cfg);
    }

    /// @dev The refusal a market with no writer rent gets from the RegisterMarkets preflight (DECISIONS §11).
    function _zeroRentRefusal(string memory ticker) internal pure returns (string memory) {
        return string.concat(
            ticker,
            ": mintFeePpm is 0. INTERFACE_VERSION 7 charges the writer collateral rent at mint and premiumFeeBps is 0"
            " at launch, so this market would charge writers nothing. Set the registry's v2.mintFeePpm (v7 design"
            " 5.1). The zero-rent opt-in is honoured only under forge test (the fixtures); no forge script run"
            " reaches it, whatever the RPC, the chain id or the flags."
        );
    }
}
