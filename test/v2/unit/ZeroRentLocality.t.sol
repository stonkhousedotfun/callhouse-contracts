// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployV2Fixture} from "./DeployV2Fixture.t.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";

/// @notice `RegisterMarkets` as a `forge script` run sees itself: {V2DeployBase._inTestContext} false.
/// @dev The override only ever TIGHTENS -- nothing in this repository overrides `_inTestContext` to true -- so
///      pointing `forge script` at this double refuses exactly like pointing it at the real script.
contract ScriptRunRegisterMarkets is RegisterMarkets {
    function _inTestContext() internal pure override returns (bool) {
        return false;
    }
}

/// @notice `VerifyV8` as a `forge script` run sees itself. See {ScriptRunRegisterMarkets}.
/// @dev Kept for test/v2/unit/DeployV2Env.t.sol, which drives the environment half of the same guard through both
///      doubles. The verifier's own rent rule is C8-10b's (`VerifyV8`); this file no longer asserts on it.
contract ScriptRunVerifyV2 is VerifyV8 {
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
        return rentAllowed(requested);
    }
}

/// @notice The collateral-rent opt-in is a TEST-ONLY code path: no `forge script` run reaches it, whatever the RPC,
///         the chain id, the broadcast state or the environment, and the fixtures keep it.
/// @dev INTERFACE_VERSION 8 INVERTED THE GUARD AND KEPT THE MACHINERY (V8-DESIGN.md §4.3). v7 refused a rent rate of
///      0, because `premiumFeeBps` was 0 and the rent was the only writer fee. v8 takes 5% of the premium on first
///      sale and launches rent at 0 on every market, so the dangerous value is now a NON-ZERO one: rent is turned on
///      through `Clearinghouse.setMarketFees` in the MARKET_FEE_MANAGER lane, where it waits 72 h in the open and the
///      guardian can cancel it. A deploy script is immediate and unreviewed, so it must not be able to set it at all.
///
///      The hole the machinery closes is the v7 one (codex review, accepted 2026-09-17, DECISIONS-2026-09-17 §11):
///      before it, the opt-in was refused only by `DeployV2Batch.sh` and only together with `--broadcast`, so a
///      direct `forge script RegisterMarkets --rpc-url <live 4663> --broadcast` with the variable exported went
///      through. A "this is the local harness" marker cannot prove RPC locality; the forge subcommand can, and a
///      fork of 4663 keeps chain id 4663 so the chain id alone proves nothing.
///
///      WHY THESE CASES DRIVE `preflightMarket` AND NOT `runWith`. The guard lives in the preflight, which is the
///      point: it fires before `_execute` can start a broadcast, so nothing is sent. Driving `runWith` would also
///      drag in `preflightSet`, whose `_adminOf` still asks each target for `IAccessControl.hasRole` -- v7 plumbing
///      that C8-09 replaces with the manager's `canCall`, and that reverts against a v8 target for reasons that have
///      nothing to do with rent. TSLA is the market used throughout because it has no Uniswap pool, so its preflight
///      touches nothing the payout surface owns either.
///
///      The ENVIRONMENT half of the same guard lives in test/v2/unit/DeployV2Env.t.sol, which owns the `V2_*`
///      process environment (it is the one suite allowed to `vm.setEnv` those names).
contract ZeroRentLocalityTest is DeployV2Fixture {
    V2DeployBase.Contracts internal d;

    /// @dev Robinhood Chain, and what an anvil fork of it also reports.
    uint256 internal constant LIVE_CHAIN_ID = 4663;

    /// @dev A rate the 72 h lane would be a perfectly good way to set, and a deploy script never is.
    uint32 internal constant SOME_RENT = 300;

    ScriptRunRegisterMarkets internal scriptRegister;
    ContextProbe internal probe;

    function setUp() public override {
        super.setUp();
        d = _deploy();
        scriptRegister = new ScriptRunRegisterMarkets();
        probe = new ContextProbe();
    }

    /*//////////////////////////////////////////////////////////////
              (a) THE LAUNCH VALUE NEEDS NO OPT-IN AT ALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Rent 0 is the v8 launch value, so it passes the preflight with no opt-in, in either context.
    /// @dev THIS IS THE CASE THAT PROVES THE `ppm == 0` TERM IS LOAD-BEARING. Delete that term from
    ///      `RegisterMarkets.preflightMarket` and this test goes red while every other case in this file stays
    ///      green, because all of them are already refused by the second term.
    function test_rentZero_isTheLaunchValueAndNeedsNoOptIn() public view {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        assertEq(in_.mintFeePpm[1], 0, "the fixture launches TSLA at 0 rent");
        assertFalse(in_.allowRent, "and asks for no opt-in");
        registerScript.preflightMarket(in_, in_.markets[1]);
        scriptRegister.preflightMarket(in_, in_.markets[1]);
    }

    /*//////////////////////////////////////////////////////////////
                        (b) A BROADCASTING REGISTER
    //////////////////////////////////////////////////////////////*/

    /// @notice A `RegisterMarkets` run that opted in to rent, on the live chain id, while broadcasting: refused.
    /// @dev The refusal lands in the preflight, before `_execute` starts a broadcast of its own, so nothing is sent.
    function test_register_scriptRunBroadcastingCannotOptIn() public {
        vm.chainId(LIVE_CHAIN_ID);
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = SOME_RENT; // TSLA
        in_.allowRent = true;

        vm.startBroadcast(adminSafe);
        vm.expectRevert(bytes(_rentRefusal("TSLA", SOME_RENT)));
        scriptRegister.preflightMarket(in_, in_.markets[1]);
        vm.stopBroadcast();
    }

    /*//////////////////////////////////////////////////////////////
                    (c) A REGISTER THAT ONLY SIMULATES
    //////////////////////////////////////////////////////////////*/

    /// @notice The same run WITHOUT broadcasting, on the live chain id: still refused.
    /// @dev A dry run is how an operator finds out whether a broadcast would go through, so it has to answer the same
    ///      way; and the guard is the subcommand, not the broadcast state, so there is nothing left to toggle.
    function test_register_scriptRunOnTheLiveChainCannotOptIn() public {
        vm.chainId(LIVE_CHAIN_ID);
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = SOME_RENT;
        in_.allowRent = true;
        vm.expectRevert(bytes(_rentRefusal("TSLA", SOME_RENT)));
        scriptRegister.preflightMarket(in_, in_.markets[1]);
    }

    /// @notice And on a chain id that is NOT 4663: the guard is the forge subcommand, never the chain.
    /// @dev An anvil fork of 4663 reports 4663 and a devnet reports whatever it was started with, so a chain-id test
    ///      would be both too strict (it would refuse a devnet) and too loose (it would accept a fork of the live
    ///      chain, and a fork's RPC is one flag away from the live one).
    function test_register_scriptRunOffChainIdCannotOptInEither() public {
        vm.chainId(31_337);
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = SOME_RENT;
        in_.allowRent = true;
        vm.expectRevert(bytes(_rentRefusal("TSLA", SOME_RENT)));
        scriptRegister.preflightMarket(in_, in_.markets[1]);
    }

    /// @notice A script run that did NOT ask for the opt-in is refused by exactly the same message.
    /// @dev So the refusal never depends on the operator having remembered the variable: a rent-bearing registry row
    ///      alone is enough to stop the run.
    function test_register_scriptRunWithoutTheOptInIsRefusedIdentically() public {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = SOME_RENT;
        in_.allowRent = false;
        vm.expectRevert(bytes(_rentRefusal("TSLA", SOME_RENT)));
        scriptRegister.preflightMarket(in_, in_.markets[1]);
    }

    /*//////////////////////////////////////////////////////////////
                    (d) THE LOCAL HARNESS STILL WORKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Under `forge test` the opt-in still works, which is the one place it is legitimate: the fixtures have
    ///         to be able to build a rent-bearing market to test the rent code at all.
    function test_fixtures_keepTheOptIn() public view {
        assertTrue(probe.inTestContext(), "forge test is the TestGroup context");
        assertTrue(probe.allowed(true), "and the opt-in is honoured there");
        assertFalse(probe.allowed(false), "a run that did not ask never opts in");

        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = SOME_RENT;
        in_.allowRent = true;
        registerScript.preflightMarket(in_, in_.markets[1]);
    }

    /// @notice The same inputs, the same contract, the same chain: only the forge subcommand differs, and only the
    ///         script context refuses.
    /// @dev One test, both sides, so that difference is the only variable in it.
    function test_theOnlyDifferenceIsTheForgeSubcommand() public {
        RegisterMarkets.Inputs memory in_ = _registerInputs(d);
        in_.mintFeePpm[1] = SOME_RENT;
        in_.allowRent = true;
        registerScript.preflightMarket(in_, in_.markets[1]); // test context: through
        vm.expectRevert(bytes(_rentRefusal("TSLA", SOME_RENT)));
        scriptRegister.preflightMarket(in_, in_.markets[1]); // script context: refused
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The refusal a rent-bearing market gets from the RegisterMarkets preflight. The tail is
    ///      `V2DeployBase._WHY_RENT` verbatim: it is `internal constant`, so a test cannot read it, and the two
    ///      copies drifting apart is what this assertion would catch.
    function _rentRefusal(string memory ticker, uint32 ppm) internal pure returns (string memory) {
        return string.concat(
            ticker,
            ": mintFeePpm is ",
            vm.toString(uint256(ppm)),
            ", not 0. ",
            "INTERFACE_VERSION 8 charges 5% of the premium on first sale and launches collateral rent at 0 on every market"
            " (V8-DESIGN 4.3), so a deploy script must never put a rent-bearing market on chain: turn rent on afterwards"
            " through Clearinghouse.setMarketFees under the 72 h MARKET_FEE_MANAGER lane. The rent opt-in is honoured only"
            " under forge test (the fixtures); no forge script run reaches it, whatever the RPC, the chain id or the flags."
        );
    }
}
