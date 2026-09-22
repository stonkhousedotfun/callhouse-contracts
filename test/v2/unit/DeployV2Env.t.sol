// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployV8} from "../../../script/v2/DeployV8.s.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";
import {ScriptRunRegisterMarkets, ScriptRunVerifyV2} from "./ZeroRentLocality.t.sol";

/// @notice The environment contract of the v2/v8 deploy scripts, the way `script/v2/DeployV2Batch.sh` exports it:
///         every `V2_*` name is read into the right field, the launch defaults apply when a tunable is unset, an
///         override wins, a market without V2_MARKET_<T>_POOL is Chainlink only, and a value too wide for its field is
///         refused by name.
/// @dev ONE test function that sets and blanks the environment. Only `V2_*` names are touched, which no other test
///      reads (test/unit/DeploySoloPreflight.t.sol and FreezeV1.t.sol use other names), and no key variable: the
///      scripts' `run()` reads DEPLOYER_PK / ADMIN_PK, which DeploySoloPreflight sets on a parallel thread, so `run()`
///      is left to the fork rehearsal and the tests call `inputsFromEnv()`.
///
///      THE PREFIX STAYS `V2_`. INTERFACE_VERSION 8 renamed the script (`DeployV8`) and added names
///      (`V2_ADMIN_SAFE`, `V2_TREASURY_SAFE`, `V2_ACCESS_MANAGER`, `V2_PAYOUT_ROUTER`, the flywheel block); it renamed
///      none, because 03-INTERFACES §4 keeps the registry block called `v2` and the batch's `KEEP_OVERRIDES` handling
///      is written against these spellings.
contract DeployV2EnvTest is Test {
    string[] internal names;

    function _set(string memory name, string memory value) internal {
        vm.setEnv(name, value);
        names.push(name);
    }

    function test_env_everyVariableInOrder() public {
        address safe = makeAddr("adminSafe");
        address pool = makeAddr("pool");
        _set("V2_ADMIN_SAFE", vm.toString(safe));
        _set("V2_TREASURY_SAFE", vm.toString(makeAddr("treasurySafe")));
        _set("V2_GUARDIAN", vm.toString(makeAddr("guardian")));
        _set("V2_PRICER", vm.toString(makeAddr("pricer")));
        _set("V2_MM_QUOTER", vm.toString(makeAddr("quoter")));
        _set("V2_CRANKER", vm.toString(makeAddr("cranker")));
        _set("V2_FEE_RECIPIENT", vm.toString(makeAddr("splitter")));
        // `RegisterMarkets` still reads `V2_ADMIN` for the single signer of its Safe batch. v8 splits that principal
        // into V2_ADMIN_SAFE and V2_TREASURY_SAFE for the deploy, but the register script's own signer model is
        // C8-09's to change, so the name is still exported and still read.
        _set("V2_ADMIN", vm.toString(safe));
        _set("V2_USDG", "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168");
        _set("V2_SWAP_ROUTER02", "0xcaf681a66d020601342297493863e78c959e5cb2");
        _set("V2_UNIV3_FACTORY", "0x1f7d7550b1b028f7571e69a784071f0205fd2efa");
        _set("V2_DATA_STREAMS_VERIFIER", "0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7");
        _set("V2_V4_POOL_MANAGER", vm.toString(makeAddr("v4PoolManager")));
        _set("V2_V4_STATE_VIEW", vm.toString(makeAddr("v4StateView")));
        // INTERFACE_VERSION 8 (V8-DESIGN.md §4): 5% of the premium on first sale, nothing on a true resale. v7 would
        // have refused this exact pair (`premiumFeeBps <= resaleFeeBps`); v8 launches with it.
        _set("V2_PREMIUM_FEE_BPS", "500");
        _set("V2_RESALE_FEE_BPS", "0");
        _set("V2_TAKER_FEE_FLAT", "100000");
        _set("V2_TAKER_FEE_CAP_BPS", "1000");
        _set("V2_MAKER_REBATE_BPS", "5000");
        _set("V2_EXERCISE_FEE_BPS", "25");
        _set("V2_HOLIDAYS", "20454,20472,20703");
        _set("V2_BOUNTY_ROLL", "7");
        _set("V2_VAULT_MAX_DAILY_OUTFLOW", "1234000000");
        // The flywheel block (V8-DESIGN.md §6): the splitter's two dials and the venue the buyback executor pins.
        _set("V2_WETH", vm.toString(makeAddr("weth")));
        _set("V2_BUYBACK_V3_POOL", vm.toString(makeAddr("usdgWethPool")));
        _set("V2_TOKEN_POOL_CURRENCY1", vm.toString(makeAddr("stonkhouse")));
        _set("V2_TOKEN_POOL_FEE", "0");
        _set("V2_TOKEN_POOL_TICK_SPACING", "200");
        _set("V2_TOKEN_POOL_HOOKS", vm.toString(makeAddr("launchHook")));
        _set("V2_BURN_BPS", "5000");
        _set("V2_ACCESS_MANAGER", vm.toString(makeAddr("accessManager")));
        _set("V2_CLEARINGHOUSE", vm.toString(makeAddr("clearinghouse")));
        _set("V2_PAYOUT_ROUTER", vm.toString(makeAddr("payoutRouter")));
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
        _set("V2_MARKET_NVDA_ENABLED", "true");
        _set("V2_MARKET_TSLA_ASSET", "0x322F0929c4625eD5bAd873c95208D54E1c003b2d");
        _set("V2_MARKET_TSLA_FEED", "0x4A1166a659A55625345e9515b32adECea5547C38");
        _set("V2_MARKET_TSLA_STRIKE_TICK", "2500000");
        _set("V2_MARKET_TSLA_MAX_DEVIATION_BPS", "150");
        _set("V2_MARKET_TSLA_UNCORROBORATED_DELAY_S", "7200");
        _set("V2_MARKET_TSLA_SPOT_MAX_AGE_S", "14400");
        _set("V2_MARKET_TSLA_ENABLED", "false");
        _set("V2_EXPECT_FRESH", "false");
        _set("V2_UNREGISTERED_ASSETS", string.concat(vm.toString(makeAddr("aapl")), ",", vm.toString(makeAddr("msft"))));

        // ---------------------------------------------------------------- DeployV8
        DeployV8 deploy = new DeployV8();
        DeployV8.Inputs memory d = deploy.inputsFromEnv();
        assertEq(d.roles.adminSafe, safe, "V2_ADMIN_SAFE");
        assertEq(d.roles.treasurySafe, makeAddr("treasurySafe"), "V2_TREASURY_SAFE");
        assertEq(d.roles.quoterKey, makeAddr("quoter"), "V2_MM_QUOTER");
        assertEq(d.roles.crankerKey, makeAddr("cranker"), "V2_CRANKER (BUYBACK in v8, no role in v7)");
        assertEq(d.roles.deployer, address(0), "V2_DEPLOYER unset: run() fills it from DEPLOYER_PK");
        assertEq(
            d.ext.swapRouter02, 0xCaf681a66D020601342297493863E78C959E5cb2, "V2_SWAP_ROUTER02 (lowercase accepted)"
        );
        assertEq(d.ext.v4PoolManager, makeAddr("v4PoolManager"), "V2_V4_POOL_MANAGER");
        assertEq(d.ext.v4StateView, makeAddr("v4StateView"), "V2_V4_STATE_VIEW");
        assertEq(d.params.fees.premiumFeeBps, 500);
        assertEq(d.params.fees.resaleFeeBps, 0);
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
        assertEq(d.existing.accessManager, makeAddr("accessManager"), "V2_ACCESS_MANAGER resume address");
        assertEq(d.existing.clearinghouse, makeAddr("clearinghouse"), "resume address");
        assertEq(
            d.existing.payoutRouter, makeAddr("payoutRouter"), "V2_PAYOUT_ROUTER is its own name, added not renamed"
        );
        assertEq(d.existing.orderBook, address(0), "not given");
        assertEq(d.expectChainId, 4663, "V2_EXPECT_CHAIN_ID default");

        // the flywheel block
        assertEq(d.flywheel.burnBps, 5000, "V2_BURN_BPS");
        assertEq(d.flywheel.conversionSlippageBps, 30, "launch default");
        assertEq(d.flywheel.weth, makeAddr("weth"), "V2_WETH");
        assertEq(d.flywheel.v3UsdgWethPool, makeAddr("usdgWethPool"), "V2_BUYBACK_V3_POOL");
        assertEq(d.flywheel.poolKey.currency0, address(0), "native ETH by default");
        assertEq(d.flywheel.poolKey.currency1, makeAddr("stonkhouse"), "V2_TOKEN_POOL_CURRENCY1");
        assertEq(d.flywheel.poolKey.tickSpacing, int24(200), "V2_TOKEN_POOL_TICK_SPACING");
        assertEq(d.flywheel.poolKey.hooks, makeAddr("launchHook"), "V2_TOKEN_POOL_HOOKS");
        assertEq(d.flywheel.maxTotalFeeBps, 250, "launch default");
        assertEq(d.flywheel.twapWindow, 300, "launch default");
        assertEq(d.flywheel.minLiquidity, 1e18, "launch default");

        // ---------------------------------------------------------------- RegisterMarkets
        RegisterMarkets register = new RegisterMarkets();
        RegisterMarkets.Inputs memory r = register.inputsFromEnv();
        assertEq(r.exerciseFeeBps, 25);
        assertEq(r.maxFeedAge, 4 days, "V2_MAX_FEED_AGE_S default");
        assertEq(r.markets.length, 2);
        assertEq(r.markets[0].ticker, "NVDA");
        assertEq(r.markets[0].pool, pool);
        assertEq(r.markets[0].minLiquidity, 1.7e18);
        assertEq(r.markets[0].poolFee, 500);
        assertEq(r.markets[0].strikeTick, 2_500_000);
        assertTrue(r.markets[0].enabled, "V2_MARKET_NVDA_ENABLED=true");
        assertEq(r.markets[1].ticker, "TSLA");
        assertEq(r.markets[1].asset, 0x322F0929c4625eD5bAd873c95208D54E1c003b2d);
        assertEq(r.markets[1].pool, address(0), "no V2_MARKET_TSLA_POOL: Chainlink only");
        assertEq(r.markets[1].minLiquidity, 0);
        assertEq(r.markets[1].uncorroboratedDelay, 7200, "per-market override");
        assertEq(r.markets[1].spotMaxAge, 14_400, "per-market override");
        assertFalse(r.markets[1].enabled, "V2_MARKET_TSLA_ENABLED=false (fail-closed default is also false)");
        assertEq(r.c.clearinghouse, makeAddr("clearinghouse"));
        // INTERFACE_VERSION 8 (V8-DESIGN.md §4.3): rent launches at 0 on every market, so NEITHER variable being set
        // is the normal case and reads back as 0. v7 refused exactly this and demanded a rate.
        assertEq(r.mintFeePpm.length, 2, "one rent rate per ticker");
        assertEq(r.mintFeePpm[0], 0, "no V2_MARKET_NVDA_MINT_FEE_PPM and no V2_MINT_FEE_PPM: 0, the launch value");
        assertEq(r.mintFeePpm[1], 0, "same for TSLA");
        assertFalse(r.allowRent, "and nothing asked for the rent opt-in");

        // ---------------------------------------------------------------- VerifyV8
        VerifyV8 verify = new VerifyV8();
        VerifyV8.Inputs memory v = verify.inputsFromEnv();
        assertFalse(v.expectFresh, "V2_EXPECT_FRESH=false");
        assertEq(v.unregistered.length, 2);
        assertEq(v.unregistered[1], makeAddr("msft"));
        assertEq(v.markets.length, 2);
        assertTrue(v.markets[0].enabled, "VerifyV8 reads V2_MARKET_NVDA_ENABLED");
        assertFalse(v.markets[1].enabled, "VerifyV8 reads V2_MARKET_TSLA_ENABLED");
        assertEq(v.deployer, address(0), "V2_DEPLOYER unset");
        assertEq(v.mintFeePpm.length, 2, "VerifyV8 reads the same rent rates");
        assertEq(v.mintFeePpm[0], 0, "and the same launch value");

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

        // ---------------------------------------------------------------- the INVERTED rent guard
        // v7 refused an ABSENT or ZERO rate; v8 refuses a NON-ZERO one (V8-DESIGN.md §4.3). Rent is turned on
        // afterwards through `Clearinghouse.setMarketFees` in the 72 h MARKET_FEE_MANAGER lane, where it waits in
        // the open and the guardian can cancel it -- never by a deploy script, which is immediate and unreviewed.
        _set("V2_MINT_FEE_PPM", "40");
        vm.expectRevert(bytes(_rentRate("NVDA", 40)));
        register.inputsFromEnv();
        vm.expectRevert(bytes(_rentRate("NVDA", 40)));
        verify.inputsFromEnv();
        _set("V2_MARKET_NVDA_MINT_FEE_PPM", "80");
        vm.expectRevert(bytes(_rentRate("NVDA", 80)));
        register.inputsFromEnv();

        // The per-market override can also bring a market back to the launch value while the shared default does
        // not: then NVDA passes and TSLA, which still falls back to the shared 40, is the one refused.
        vm.setEnv("V2_MARKET_NVDA_MINT_FEE_PPM", "0");
        vm.expectRevert(bytes(_rentRate("TSLA", 40)));
        register.inputsFromEnv();

        // Only the opt-in lets a rate through, and only under the forge test runner.
        vm.setEnv("V2_MARKET_NVDA_MINT_FEE_PPM", "80");
        _set("V2_ALLOW_RENT", "true");
        RegisterMarkets.Inputs memory rent = register.inputsFromEnv();
        assertTrue(rent.allowRent, "V2_ALLOW_RENT rides into the preflight");
        assertEq(rent.mintFeePpm[0], 80, "and only then is a non-zero rate read back");
        assertEq(rent.mintFeePpm[1], 40, "TSLA falls back to the shared V2_MINT_FEE_PPM");
        assertTrue(verify.inputsFromEnv().allowRent, "VerifyV8 reads the same opt-in");

        // THE SAME ENVIRONMENT IN A SCRIPT RUN (the v7 guard, kept whole). Until it existed the opt-in was refused
        // only by DeployV2Batch.sh and only together with --broadcast, so a direct
        // `forge script RegisterMarkets --rpc-url <live 4663> --broadcast` with the variable exported went through.
        // The opt-in is honoured only under the forge test runner, and these doubles answer the way `forge script`
        // does -- which is the ONE fact the inversion did not change.
        ScriptRunRegisterMarkets scriptRegister = new ScriptRunRegisterMarkets();
        ScriptRunVerifyV2 scriptVerify = new ScriptRunVerifyV2();
        assertFalse(scriptRegister.allowRentFromEnv(), "a script run never reads the opt-in out of the environment");
        assertFalse(scriptVerify.allowRentFromEnv(), "neither does a read-only verify");
        vm.expectRevert(bytes(_rentRate("NVDA", 80)));
        scriptRegister.inputsFromEnv();
        vm.expectRevert(bytes(_rentRate("NVDA", 80)));
        scriptVerify.inputsFromEnv();
        assertTrue(register.allowRentFromEnv(), "and the fixtures keep it");

        vm.setEnv("V2_ALLOW_RENT", "false");
        vm.expectRevert(bytes(_rentRate("NVDA", 80)));
        register.inputsFromEnv();
        vm.setEnv("V2_ALLOW_RENT", "");
        vm.expectRevert(bytes(_rentRate("NVDA", 80)));
        register.inputsFromEnv();
        vm.setEnv("V2_MARKET_NVDA_MINT_FEE_PPM", "");
        vm.setEnv("V2_MINT_FEE_PPM", "");

        vm.setEnv("V2_VAULT_MAX_DAILY_OUTFLOW", "340282366920938463463374607431768211456");
        vm.expectRevert(bytes("V2_VAULT_MAX_DAILY_OUTFLOW does not fit uint128"));
        deploy.inputsFromEnv();
        vm.setEnv("V2_VAULT_MAX_DAILY_OUTFLOW", "1234000000");

        for (uint256 i; i < names.length; ++i) {
            vm.setEnv(names[i], "");
        }
    }

    /// @dev The refusal of a market whose rent rate is not 0 (V8-DESIGN.md §4.3). The tail is
    ///      `V2DeployBase._WHY_RENT` verbatim: it is `internal constant`, so a test cannot read it, and the two
    ///      copies drifting apart is what this assertion would catch.
    function _rentRate(string memory ticker, uint256 ppm) internal pure returns (string memory) {
        return string.concat(
            ticker,
            ": collateral rent rate is ",
            vm.toString(ppm),
            ", not 0. ",
            "INTERFACE_VERSION 8 charges 5% of the premium on first sale and launches collateral rent at 0 on every market"
            " (V8-DESIGN 4.3), so a deploy script must never put a rent-bearing market on chain: turn rent on afterwards"
            " through Clearinghouse.setMarketFees under the 72 h MARKET_FEE_MANAGER lane. The rent opt-in is honoured only"
            " under forge test (the fixtures); no forge script run reaches it, whatever the RPC, the chain id or the flags."
        );
    }
}
