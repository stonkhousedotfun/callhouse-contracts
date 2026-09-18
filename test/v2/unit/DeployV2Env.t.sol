// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployV2} from "../../../script/v2/DeployV2.s.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {VerifyV2} from "../../../script/v2/VerifyV2.s.sol";
import {ScriptRunRegisterMarkets, ScriptRunVerifyV2} from "./ZeroRentLocality.t.sol";

/// @notice The environment contract of the three v2 deploy scripts, the way `script/v2/DeployV2Batch.sh` exports it:
///         every `V2_*` name is read into the right field, the launch defaults apply when a tunable is unset, an
///         override wins, a market without V2_MARKET_<T>_POOL is Chainlink only, and a value too wide for its field is
///         refused by name.
/// @dev ONE test function that sets and blanks the environment. Only `V2_*` names are touched, which no other test
///      reads (test/unit/DeploySoloPreflight.t.sol and FreezeV1.t.sol use other names), and no key variable: the
///      scripts' `run()` reads DEPLOYER_PK / ADMIN_PK, which DeploySoloPreflight sets on a parallel thread, so `run()`
///      is left to the fork rehearsal and the tests call `inputsFromEnv()`.
contract DeployV2EnvTest is Test {
    string[] internal names;

    function _set(string memory name, string memory value) internal {
        vm.setEnv(name, value);
        names.push(name);
    }

    function test_env_everyVariableInOrder() public {
        address a = makeAddr("admin");
        address pool = makeAddr("pool");
        _set("V2_ADMIN", vm.toString(a));
        _set("V2_GUARDIAN", vm.toString(makeAddr("guardian")));
        _set("V2_FEE_RECIPIENT", vm.toString(makeAddr("fee")));
        _set("V2_CRANKER", vm.toString(makeAddr("cranker")));
        _set("V2_PRICER", vm.toString(makeAddr("pricer")));
        _set("V2_MM_QUOTER", vm.toString(makeAddr("quoter")));
        _set("V2_USDG", "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168");
        _set("V2_SWAP_ROUTER02", "0xcaf681a66d020601342297493863e78c959e5cb2");
        _set("V2_UNIV3_FACTORY", "0x1f7d7550b1b028f7571e69a784071f0205fd2efa");
        _set("V2_DATA_STREAMS_VERIFIER", "0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7");
        _set("V2_PREMIUM_FEE_BPS", "500");
        _set("V2_RESALE_FEE_BPS", "0");
        _set("V2_TAKER_FEE_FLAT", "100000");
        _set("V2_TAKER_FEE_CAP_BPS", "1000");
        _set("V2_MAKER_REBATE_BPS", "5000");
        _set("V2_EXERCISE_FEE_BPS", "25");
        _set("V2_HOLIDAYS", "20454,20472,20703");
        _set("V2_BOUNTY_ROLL", "7");
        // INTERFACE_VERSION 7: the shared rent rate, one per-market override, and one of the two new tunables set to
        // prove the override path while the other falls back to its LAUNCH_ constant.
        _set("V2_MINT_FEE_PPM", "40");
        _set("V2_MARKET_NVDA_MINT_FEE_PPM", "80");
        _set("V2_VAULT_MAX_DAILY_OUTFLOW", "1234000000");
        _set("V2_CLEARINGHOUSE", vm.toString(makeAddr("clearinghouse")));
        _set("V2_TICKERS", "NVDA,TSLA");
        _set("V2_MARKET_NVDA_ASSET", "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC");
        _set("V2_MARKET_NVDA_FEED", "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15");
        _set("V2_MARKET_NVDA_POOL", vm.toString(pool));
        _set("V2_MARKET_NVDA_MIN_LIQUIDITY", "1700000000000000000");
        _set("V2_MARKET_NVDA_POOL_FEE", "500");
        _set("V2_MARKET_NVDA_STRIKE_TICK", "2500000");
        _set("V2_MARKET_NVDA_MAX_DEVIATION_BPS", "150");
        _set("V2_MARKET_NVDA_UNCORROBORATED_DELAY_S", "21600");
        _set("V2_MARKET_NVDA_SPOT_MAX_AGE_S", "3600");
        _set("V2_MARKET_TSLA_ASSET", "0x322F0929c4625eD5bAd873c95208D54E1c003b2d");
        _set("V2_MARKET_TSLA_FEED", "0x4A1166a659A55625345e9515b32adECea5547C38");
        _set("V2_MARKET_TSLA_STRIKE_TICK", "2500000");
        _set("V2_MARKET_TSLA_MAX_DEVIATION_BPS", "150");
        _set("V2_MARKET_TSLA_UNCORROBORATED_DELAY_S", "7200");
        _set("V2_MARKET_TSLA_SPOT_MAX_AGE_S", "14400");
        _set("V2_EXPECT_FRESH", "false");
        _set("V2_UNREGISTERED_ASSETS", string.concat(vm.toString(makeAddr("aapl")), ",", vm.toString(makeAddr("msft"))));

        // ---------------------------------------------------------------- DeployV2
        DeployV2 deploy = new DeployV2();
        DeployV2.Inputs memory d = deploy.inputsFromEnv();
        assertEq(d.roles.admin, a, "V2_ADMIN");
        assertEq(d.roles.mmQuoter, makeAddr("quoter"), "V2_MM_QUOTER");
        assertEq(
            d.ext.swapRouter02, 0xCaf681a66D020601342297493863E78C959E5cb2, "V2_SWAP_ROUTER02 (lowercase accepted)"
        );
        assertEq(d.params.fees.premiumFeeBps, 500);
        assertEq(d.params.fees.takerFeeFlat, 100_000);
        assertEq(d.params.fees.makerRebateBps, 5000);
        assertEq(d.params.exerciseFeeBps, 25);
        assertEq(d.params.bountyRoll, 7, "override wins");
        assertEq(d.params.bountySnapshot, deploy.LAUNCH_BOUNTY_SNAPSHOT(), "launch default");
        assertEq(d.params.bountyRedeem, 20_000, "launch default");
        assertEq(d.params.dailyCap, 100e6, "launch default");
        assertEq(d.params.payoutSlippageBps, 30, "launch default");
        assertEq(d.params.vaultLimits.maxTotalNotional, 250_000e6, "launch default");
        assertEq(d.params.bountyCancelStale, 20_000, "V2_BOUNTY_CANCEL_STALE launch default (v7 c16)");
        assertEq(
            d.params.vaultLimits.maxDailyOutflow, 1_234_000_000, "V2_VAULT_MAX_DAILY_OUTFLOW override wins (v7 c21)"
        );
        assertEq(deploy.LAUNCH_VAULT_MAX_DAILY_OUTFLOW(), 2_500e6, "the launch default the override replaced (v7 c21)");
        assertEq(d.params.baseUri, "https://app.stonkhouse.fun/api/token/", "launch default");
        assertEq(d.holidays.length, 3);
        assertEq(d.holidays[2], 20703);
        assertEq(d.existing.clearinghouse, makeAddr("clearinghouse"), "resume address");
        assertEq(d.existing.orderBook, address(0), "not given");
        assertEq(d.expectChainId, 4663, "V2_EXPECT_CHAIN_ID default");

        // ---------------------------------------------------------------- RegisterMarkets
        RegisterMarkets register = new RegisterMarkets();
        RegisterMarkets.Inputs memory r = register.inputsFromEnv();
        assertEq(r.admin, a);
        assertEq(r.exerciseFeeBps, 25);
        assertEq(r.maxFeedAge, 4 days, "V2_MAX_FEED_AGE_S default");
        assertEq(r.markets.length, 2);
        assertEq(r.markets[0].ticker, "NVDA");
        assertEq(r.markets[0].pool, pool);
        assertEq(r.markets[0].minLiquidity, 1.7e18);
        assertEq(r.markets[0].poolFee, 500);
        assertEq(r.markets[0].strikeTick, 2_500_000);
        assertEq(r.markets[1].ticker, "TSLA");
        assertEq(r.markets[1].asset, 0x322F0929c4625eD5bAd873c95208D54E1c003b2d);
        assertEq(r.markets[1].pool, address(0), "no V2_MARKET_TSLA_POOL: Chainlink only");
        assertEq(r.markets[1].minLiquidity, 0);
        assertEq(r.markets[1].uncorroboratedDelay, 7200, "per-market override");
        assertEq(r.markets[1].spotMaxAge, 14_400, "per-market override");
        assertEq(r.c.clearinghouse, makeAddr("clearinghouse"));
        // INTERFACE_VERSION 7 (c05): the rent rates are parallel to `markets`, per-market over shared over 0.
        assertEq(r.mintFeePpm.length, 2, "one rent rate per ticker");
        assertEq(r.mintFeePpm[0], 80, "V2_MARKET_NVDA_MINT_FEE_PPM wins over V2_MINT_FEE_PPM");
        assertEq(r.mintFeePpm[1], 40, "TSLA has no override: the shared V2_MINT_FEE_PPM");

        // ---------------------------------------------------------------- VerifyV2
        VerifyV2 verify = new VerifyV2();
        VerifyV2.Inputs memory v = verify.inputsFromEnv();
        assertFalse(v.expectFresh, "V2_EXPECT_FRESH=false");
        assertEq(v.unregistered.length, 2);
        assertEq(v.unregistered[1], makeAddr("msft"));
        assertEq(v.markets.length, 2);
        assertEq(v.deployer, address(0), "V2_DEPLOYER unset");
        assertEq(v.mintFeePpm.length, 2, "VerifyV2 reads the same rent rates");
        assertEq(v.mintFeePpm[0], 80, "NVDA override");
        assertEq(v.mintFeePpm[1], 40, "TSLA shared default");

        // ---------------------------------------------------------------- refusals by name
        vm.setEnv("V2_PREMIUM_FEE_BPS", "70000");
        vm.expectRevert(bytes("V2_PREMIUM_FEE_BPS does not fit uint16"));
        deploy.inputsFromEnv();
        vm.setEnv("V2_PREMIUM_FEE_BPS", "500");
        vm.setEnv("V2_MARKET_TSLA_POOL_FEE", "16777216");
        vm.expectRevert(bytes("V2_MARKET_TSLA_POOL_FEE does not fit uint24"));
        register.inputsFromEnv();
        names.push("V2_MARKET_TSLA_POOL_FEE");
        vm.setEnv("V2_MARKET_TSLA_POOL_FEE", "500");
        vm.setEnv("V2_MARKET_NVDA_MINT_FEE_PPM", "4294967296");
        vm.expectRevert(bytes("V2_MARKET_NVDA_MINT_FEE_PPM does not fit uint32"));
        register.inputsFromEnv();
        vm.setEnv("V2_MARKET_NVDA_MINT_FEE_PPM", "80");

        // INTERFACE_VERSION 7 release blocker (DECISIONS-2026-09-17 §11): with premiumFeeBps 0 at launch the rent is
        // the only writer fee, so a missing rate must never default to 0 on a path that can broadcast. Unsetting both
        // the per-market and the shared variable is refused by name, an explicit 0 is refused as well, and only
        // V2_ALLOW_ZERO_RENT brings the old default back (DeployV2Batch.sh refuses that flag with --broadcast).
        vm.setEnv("V2_MARKET_NVDA_MINT_FEE_PPM", "");
        vm.setEnv("V2_MINT_FEE_PPM", "");
        vm.expectRevert(bytes(_noRate("NVDA", "V2_MARKET_NVDA_MINT_FEE_PPM")));
        register.inputsFromEnv();
        vm.expectRevert(bytes(_noRate("NVDA", "V2_MARKET_NVDA_MINT_FEE_PPM")));
        verify.inputsFromEnv();
        vm.setEnv("V2_MINT_FEE_PPM", "0");
        vm.expectRevert(bytes(_zeroRate("NVDA")));
        register.inputsFromEnv();
        vm.setEnv("V2_MINT_FEE_PPM", "40");
        vm.setEnv("V2_MARKET_NVDA_MINT_FEE_PPM", "0");
        vm.expectRevert(bytes(_zeroRate("NVDA")));
        register.inputsFromEnv();

        _set("V2_ALLOW_ZERO_RENT", "true");
        RegisterMarkets.Inputs memory zero = register.inputsFromEnv();
        assertTrue(zero.allowZeroRent, "V2_ALLOW_ZERO_RENT rides into the preflight");
        assertEq(zero.mintFeePpm[0], 0, "and only then is an explicit 0 read back");
        assertTrue(verify.inputsFromEnv().allowZeroRent, "VerifyV2 reads the same opt-in");

        // THE SAME ENVIRONMENT IN A SCRIPT RUN (codex review, DECISIONS-2026-09-17 §11). Until this guard,
        // V2_ALLOW_ZERO_RENT was refused only by DeployV2Batch.sh and only together with --broadcast, so a direct
        // `forge script RegisterMarkets --rpc-url <live 4663> --broadcast` with the variable exported registered a
        // market that charges its writers nothing, and a read-only VerifyV2 of live 4663 accepted one. The opt-in is
        // now honoured only under the forge test runner, and these doubles answer the way `forge script` does.
        ScriptRunRegisterMarkets scriptRegister = new ScriptRunRegisterMarkets();
        ScriptRunVerifyV2 scriptVerify = new ScriptRunVerifyV2();
        assertFalse(scriptRegister.allowZeroRentFromEnv(), "a script run never reads the opt-in out of the environment");
        assertFalse(scriptVerify.allowZeroRentFromEnv(), "neither does a read-only verify");
        vm.expectRevert(bytes(_zeroRate("NVDA")));
        scriptRegister.inputsFromEnv();
        vm.expectRevert(bytes(_zeroRate("NVDA")));
        scriptVerify.inputsFromEnv();
        assertTrue(register.allowZeroRentFromEnv(), "and the fixtures keep it");

        vm.setEnv("V2_ALLOW_ZERO_RENT", "false");
        vm.expectRevert(bytes(_zeroRate("NVDA")));
        register.inputsFromEnv();
        vm.setEnv("V2_ALLOW_ZERO_RENT", "");
        vm.expectRevert(bytes(_zeroRate("NVDA")));
        register.inputsFromEnv();
        vm.setEnv("V2_MARKET_NVDA_MINT_FEE_PPM", "80");

        vm.setEnv("V2_VAULT_MAX_DAILY_OUTFLOW", "340282366920938463463374607431768211456");
        vm.expectRevert(bytes("V2_VAULT_MAX_DAILY_OUTFLOW does not fit uint128"));
        deploy.inputsFromEnv();
        vm.setEnv("V2_VAULT_MAX_DAILY_OUTFLOW", "1234000000");

        for (uint256 i; i < names.length; ++i) {
            vm.setEnv(names[i], "");
        }
    }

    /// @dev The refusal of a market whose rent rate is set nowhere (INTERFACE_VERSION 7, DECISIONS §11).
    function _noRate(string memory ticker, string memory key) internal pure returns (string memory) {
        return string.concat(
            ticker, ": no collateral rent rate: neither ", key, " nor V2_MINT_FEE_PPM is set. ", _whyRentIsMandatory()
        );
    }

    /// @dev The refusal of a market whose rent rate is an explicit 0.
    function _zeroRate(string memory ticker) internal pure returns (string memory) {
        return string.concat(ticker, ": collateral rent rate is 0. ", _whyRentIsMandatory());
    }

    function _whyRentIsMandatory() internal pure returns (string memory) {
        return "INTERFACE_VERSION 7 charges the writer collateral rent at mint and premiumFeeBps is 0 at launch, so"
            " this market would charge writers nothing. Set the rate (v7 design 5.1). The zero-rent opt-in is honoured"
            " only under forge test (the fixtures); no forge script run reaches it, whatever the RPC, the chain id or"
            " the flags.";
    }
}
