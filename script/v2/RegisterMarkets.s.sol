// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {V2Constants} from "../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../src/v2/interfaces/V2Types.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {Clearinghouse} from "../../src/v2/Clearinghouse.sol";
import {ChainlinkFeedSource} from "../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../src/v2/oracle/UniV3TwapSource.sol";
import {IUniV3PoolFactory} from "../../src/v2/periphery/PayoutDeps.sol";
import {IPayoutRouter} from "../../src/v2/interfaces/IPayoutRouter.sol";
import {PayoutRouter} from "../../src/v2/periphery/PayoutRouter.sol";
import {UniV3PayoutAdapter} from "../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {V4Currency, V4PoolKey} from "../../src/v2/periphery/v4/V4Types.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @notice The Uniswap v3 pool reads the registration preflight makes (v3-core IUniswapV3PoolImmutables / State /
///         DerivedState).
interface IUniV3PoolView {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice Registers markets on a deployed v2 set, registry-driven: for every ticker in V2_TICKERS, a preflight of its
///         token, feed and pool, then its price sources, its SettlementOracle config, its USDG payout route and last its
///         Clearinghouse registration. One admin transaction per step that the chain does not already hold.
/// @dev Driven by `script/v2/DeployV2Batch.sh`, ONE ticker per forge run, so the registry write-back
///      (`markets[i].v2.registeredAt` / `registerTx`) follows each market. By hand:
///        ADMIN_PK=... V2_TICKERS=NVDA V2_MARKET_NVDA_ASSET=0x... <the rest of V2_*> \
///          forge script script/v2/RegisterMarkets.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching
///      With no ADMIN_PK the calls are sent from V2_ADMIN, which only an anvil node that unlocked it accepts.
///
///      LAUNCH DAY: THE DEPLOYER SIGNS DIRECTLY, INSIDE THE DEFERRED WINDOW (T-OP-162, verified at 576f2fc1; owner
///      decision 05:50Z, T-OP-153 / T-OP-161). On 4663 `V2_ADMIN` from the registry is the 2-of-3 Admin Safe, which
///      holds LISTING at 1 h and CONFIG_ADMIN at 24 h and has no key on any machine -- so the path above cannot
///      register the launch set on the day. DeployV8 step 4 grants the DEPLOYER those two roles at execution delay
///      0 and, under `V2_DEFER_HANDBACK`, keeps them until HandBack. In that window the driver runs THIS script
///      with, for the register step only:
///        V2_ADMIN=<the deployer's address>   ADMIN_PK=<the DEPLOYER_PK value>   V2_SCHEDULE / V2_SCHEDULE_PHASE unset
///      and nothing here changes: `run()` checks ADMIN_PK's address == V2_ADMIN (it does), {_signerCanList} reads
///      the deployer's execution delays off the AccessManager (0 and 0, so no V2_SCHEDULE is demanded), and
///      {_executeScheduled} takes the single-run path -- {_requireImmediate} asks `canCall` per call, then
///      {V2DeployBase._execute} sends them from the deployer. WHY OVERRIDING V2_ADMIN IS SAFE, stated because it is
///      the question: this script reads `V2_ADMIN` in exactly two places, `inputsFromEnv` and the signer check in
///      `run()`, and in both it means "the address that signs this run" -- never "the Admin Safe". Every later stage
///      takes the `Signer`. FAIL-CLOSED BY THE MANAGER, not by any flag: after HandBack the same environment dies
///      in {_signerCanList} with "signer <deployer> does not hold LISTING on the accessManager" before anything is
///      sent, and a signer that holds the roles at a delay dies with "a delayed signer cannot register in a single
///      run". The Safe-scheduled path (V2_SCHEDULE=true, two runs) stays for every post-launch listing.
///      `test/v2/unit/RegisterMarketsPreflight.t.sol` pins both the direct path and the two refusals.
///
///      PER MARKET, the environment (the batch fills it from the registry row):
///        V2_MARKET_<T>_ASSET          `asset`, the 18-dp Stock Token
///        V2_MARKET_<T>_FEED           `feed`, the Chainlink proxy (8 dp)
///        V2_MARKET_<T>_POOL           `v2.univ3Pool`; unset or zero = Chainlink only and no payout route
///        V2_MARKET_<T>_MIN_LIQUIDITY  `v2.univ3MinLiquidity` (pool L units), with the pool only
///        V2_MARKET_<T>_POOL_FEE       the pool's fee tier from v2-sources.json; 0 = read from the pool
///        V2_MARKET_<T>_STRIKE_TICK    `v2.strikeTick`
///        V2_MARKET_<T>_MAX_DEVIATION_BPS, _UNCORROBORATED_DELAY_S, _SPOT_MAX_AGE_S   `v2.defaults` + `v2.overrides`
///        V2_MARKET_<T>_MINT_FEE_PPM   `v2.mintFeePpm`, over the shared V2_MINT_FEE_PPM, over 0. v8 launches every
///                                     market at 0 and REFUSES a non-zero rate here (V8-DESIGN 4.3)
///      shared: V2_ADMIN, V2_USDG, V2_EXERCISE_FEE_BPS (registry `v2.fees`), V2_CLEARINGHOUSE, V2_SETTLEMENT_ORACLE,
///      V2_SOURCE_CHAINLINK, V2_SOURCE_UNIV3, V2_SOURCE_DATA_STREAMS, V2_PAYOUT_ROUTER; V2_MAX_FEED_AGE_S (default 4
///      days); V2_MINT_FEE_PPM (default 0, the rate every market without an override is registered with);
///      V2_EXPECT_CHAIN_ID (default 4663).
///
///      PREFLIGHT per market, each refusal naming the value read and the value expected, before anything is sent:
///        token   symbol == ticker, 18 decimals, `uiMultiplier()` answers > 0, `oraclePaused()` answers false
///        feed    description contains the ticker, 8 decimals, roundId != 0, answer > 0, updatedAt within
///                V2_MAX_FEED_AGE_S
///        config  strikeTick a non-zero multiple of PRICE_TICK; exercise fee <= EXERCISE_FEE_CEIL_BPS; deviation, delay
///                and spot age inside SettlementOracle's bounds; mintFeePpm <= MINT_FEE_CEIL_PPM (v7), so
///                registerMarket cannot revert CeilingExceeded mid-run
///        pool    (when set) code, tokens {asset, USDG}, `fee()` equal to V2_MARKET_<T>_POOL_FEE when given and at most
///                V2Constants.MAX_ROUTE_FEE_TIER (10000, 1 %: the pool is also the market's payout route, and the
///                Clearinghouse counts at most MAX_ROUTE_FEE_BPS of a route's fee, so a costlier route would pay every
///                conversion in kind; UniV3PayoutAdapter.setRoute refuses it), the
///                adapter's factory returns this pool for (asset, USDG, fee), `liquidity()` > 0, `observe([1800, 0])`
///                answers (a 30-minute TWAP is possible), `slot0().observationCardinality` at least
///                V2Constants.MIN_POOL_OBSERVATION_CARDINALITY (2401) (a shallower ring can be flooded past a snapshot's
///                window, sweep contracts-c10, and UniV3TwapSource.setPool refuses it), a floor > 0; a pool below its
///                floor only WARNs: its source then reports not-ok and settlement falls back to Chainlink with the
///                uncorroborated delay, the designed failure (callhouse ops/markets/README.md)
///        chain   not registered yet, or registered with exactly this config (then nothing is sent for it)
///        probe   (SEC-12, after every market's preflight, only for a market not registered yet) a simulated deposit
///                and withdrawal of one share move exactly the amount, on the fork, then are reverted
///                ({probeTransfers})
///      Once, for the set: every contract has code, the Clearinghouse's usdg is V2_USDG, V2_ADMIN holds
///      DEFAULT_ADMIN_ROLE on the Clearinghouse, the oracle, both sources and the adapter, and the oracle names the
///      Clearinghouse (the only caller of SettlementOracle.pin, without which createSeries reverts).
///
///      CALLS per market, in this order, each only when the chain differs:
///        chainlinkSource.setOracle(oracle, true), univ3Source.setOracle(oracle, true) (with a pool)   normally wired
///                                                                             by DeployV2 already: nothing to send
///        chainlinkSource.setFeed(asset, feed, DEFAULT_MAX_STALE, DEFAULT_MAX_ROUND_JUMP_BPS)
///        univ3Source.setPool(asset, pool, minLiquidity, DEFAULT_WINDOW)       (with a pool)
///        settlementOracle.setMarket(asset, [chainlink] | [chainlink, univ3], deviation, delay, spot age)
///        univ3Source.setPool(asset, 0)            (removes a pool the registry has not, once the list no longer names it)
///        payoutAdapter.setRoute(asset, poolFee)                               (or clears a route the registry has not)
///        clearinghouse.registerMarket(asset, strikeTick, enabled)             LAST. v8 (03-INTERFACES 2.1): the
///                                            exercise fee, the rent and the oracle come from the CONTRACT DEFAULTS
///                                            DeployV8 set, so each is followed by its own setter only when the
///                                            registry row differs -- LISTING (1 h), MARKET_FEE_MANAGER (72 h) and
///                                            CONFIG_ADMIN (24 h) are three different lanes and cannot be one call
///        clearinghouse.setMarketListing / setMarketFees   --resync of an already registered market: reconcile
///                                            enabled; tick/rent only while currently disabled
///      DataStreamsSource is never configured (C2-12: owner-gated) and never listed; its feed id for the market is only
///      reported.
///
///      LISTED SOURCES ARE CONFIGURED (INTERFACE_VERSION 6). Pinning fails closed: SettlementOracle.pin reverts, and
///      with it every first series of an expiry, while the market's list names a source that has no configuration
///      for the asset (V2Errors.SourceNotPinned(source, NoSource)) or does not list the oracle (NotAuthorized). So a
///      source is configured and accepts the oracle's pins before the list names it, and is unconfigured only after
///      the list dropped it: no step of a run leaves a live market unable to create series.
contract RegisterMarkets is V2DeployBase {
    struct Inputs {
        address admin;
        address usdg;
        uint16 exerciseFeeBps;
        uint32 maxFeedAge;
        Contracts c;
        MarketIn[] markets;
        uint256 expectChainId;
        /// @dev INTERFACE_VERSION 7: the collateral-rent rate registered per market, parallel to `markets`. Read from
        ///      `V2_MARKET_<T>_MINT_FEE_PPM`, falling back to the shared `V2_MINT_FEE_PPM` and then to 0, which is the
        ///      registry's `v2.overrides` over `v2.defaults` shape. It lives here rather than in MarketIn because
        ///      MarketIn belongs to V2DeployBase, which this work package does not own.
        uint32[] mintFeePpm;
        /// @dev INTERFACE_VERSION 8 (V8-DESIGN.md §4.3): registering a market whose rent rate is NOT 0 is refused,
        ///      because rent launches at 0 everywhere and is turned on later in the 72 h MARKET_FEE_MANAGER lane. An
        ///      opt-in asked for here is only granted under the forge TEST runner ({V2DeployBase.rentAllowed}), so
        ///      this field cannot open a `forge script` run -- not a `--broadcast`, not a dry run against live 4663,
        ///      not a `--resume`. The fixtures are the one place it is honoured.
        bool allowRent;
        /// @dev C3-102: `V2_RESYNC` / DeployV2Batch.sh `--resync`. Reconciles `enabled` to the registry status.
        ///      strikeTick and mintFeePpm may change only while the market is currently disabled. Exercise fee and
        ///      oracle of a registered market are never changed here.
        bool resync;
    }

    /*//////////////////////////////////////////////////////////////
                                  ENTRY
    //////////////////////////////////////////////////////////////*/

    function run() external returns (uint256 registered, uint256 sent) {
        Inputs memory in_ = inputsFromEnv();
        uint256 adminPk = vm.envOr("ADMIN_PK", uint256(0));
        Signer memory admin = adminPk != 0 ? Signer(adminPk, vm.addr(adminPk)) : Signer(0, in_.admin);
        require(
            admin.addr == in_.admin,
            string.concat(
                "ADMIN_PK is not V2_ADMIN's key: it signs as ",
                vm.toString(admin.addr),
                ", V2_ADMIN is ",
                vm.toString(in_.admin)
            )
        );
        // T-182 / F-SCRIPTS-11, the half {_signerCanList} cannot see. `pk == 0` means "an address the node has
        // unlocked" (V2DeployBase.Signer), which is how `DeployV2Batch.sh --rehearse` impersonates the registry
        // admin on an anvil fork. `--broadcast` unsets ADMIN_PK too, so a real run reached here with `pk == 0` and
        // a V2_ADMIN that is a SAFE -- an address no key on the machine can sign for. The roles preflight PASSED,
        // because the Safe genuinely holds LISTING and CONFIG_ADMIN, and the run then died inside forge's signing
        // step with a message about a missing wallet that named nothing about admin keys or Safes.
        //
        // `V2_UNLOCKED_ADMIN` is set by the batch in `--rehearse` and only there, so this refuses exactly the case
        // it means to and the rehearsal path is untouched. It defaults FALSE: a hand-run that forgets it is
        // refused with an instruction, rather than run with an impersonation the chain will not honour.
        require(
            admin.pk != 0 || vm.envOr("V2_UNLOCKED_ADMIN", false),
            string.concat(
                "no ADMIN_PK and V2_UNLOCKED_ADMIN is not set: this run would broadcast by IMPERSONATING ",
                vm.toString(in_.admin),
                ", which only a node that has unlocked it accepts. On a real chain the admin is a Safe and holds"
                " no key here: send the LISTING and CONFIG_ADMIN calls from the Safe, or set ADMIN_PK to a key"
                " that itself holds those roles."
            )
        );
        // C3-102 fail-closed: log enabled BEFORE the chain-id check so a hand-run with
        // V2_MARKET_<T>_ENABLED unset still proves the default (false) without a node.
        for (uint256 i; i < in_.markets.length; ++i) {
            console2.log(string.concat(in_.markets[i].ticker, " enabled=", in_.markets[i].enabled ? "true" : "false"));
        }
        require(
            block.chainid == in_.expectChainId,
            string.concat("chain id ", vm.toString(block.chainid), ", expected ", vm.toString(in_.expectChainId))
        );
        (registered, sent) = runWith(in_, admin);
        console2.log("");
        console2.log(
            string.concat(
                "REGISTER DONE: ",
                vm.toString(in_.markets.length),
                " market(s), ",
                vm.toString(registered),
                " registerMarket call(s), ",
                vm.toString(sent),
                " admin call(s) sent"
            )
        );
    }

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.admin = vm.envAddress("V2_ADMIN");
        in_.usdg = vm.envAddress("V2_USDG");
        in_.exerciseFeeBps = _u16(vm.envUint("V2_EXERCISE_FEE_BPS"), "V2_EXERCISE_FEE_BPS");
        in_.maxFeedAge = _u32(vm.envOr("V2_MAX_FEED_AGE_S", uint256(DEFAULT_MAX_FEED_AGE)), "V2_MAX_FEED_AGE_S");
        in_.c = contractsFromEnv();
        in_.markets = marketsFromEnv();
        in_.expectChainId = vm.envOr("V2_EXPECT_CHAIN_ID", CHAIN_ID_4663);
        in_.allowRent = allowRentFromEnv();
        in_.mintFeePpm = mintFeePpmFromEnv(in_.markets);
        in_.resync = vm.envOr("V2_RESYNC", false);
    }

    /// @notice Preflight every market first, then configure and register them one by one.
    /// @return registered registerMarket calls sent
    /// @return sent       admin calls sent in total
    function runWith(Inputs memory in_, Signer memory admin) public returns (uint256 registered, uint256 sent) {
        require(in_.markets.length != 0, "V2_TICKERS is empty");
        preflightSet(in_, admin);
        for (uint256 i; i < in_.markets.length; ++i) {
            for (uint256 j; j < i; ++j) {
                require(!_eq(in_.markets[i].ticker, in_.markets[j].ticker), "duplicate ticker in V2_TICKERS");
                require(in_.markets[i].asset != in_.markets[j].asset, "two tickers share one asset");
            }
            preflightMarket(in_, in_.markets[i]);
        }
        // SEC-12: only a market this run would REGISTER is probed. One already listed gains nothing from it, and a
        // --resync must not fail because its issuer has paused transfers for a while.
        for (uint256 i; i < in_.markets.length; ++i) {
            if (Clearinghouse(in_.c.clearinghouse).market(in_.markets[i].asset).strikeTick == 0) {
                probeTransfers(in_, in_.markets[i]);
            }
        }
        for (uint256 i; i < in_.markets.length; ++i) {
            MarketIn memory m = in_.markets[i];
            console2.log(string.concat("register ", m.ticker));
            (Call[] memory calls, bool registers) = plan(in_, m);
            for (uint256 k; k < calls.length; ++k) {
                console2.log(string.concat("  call  ", calls[k].what));
            }
            // The schedule phase sends no target call, so nothing it queues is on chain yet: counting
            // it as registered, or post-checking it, would report work that has not happened.
            if (!_executeScheduled(in_, admin, calls)) continue;
            sent += calls.length;
            if (registers) ++registered;
            _postCheck(in_, m);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @notice The contract set and the admin's roles on it.
    /// @dev T-182 / F-SCRIPTS-11: takes the `Signer` so {_signerCanList} can preflight the address that will
    ///      actually broadcast rather than whatever `V2_ADMIN` names. Nothing outside this file called it.
    function preflightSet(Inputs memory in_, Signer memory s) public view {
        console2.log("preflight (contract set)");
        Contracts memory c = in_.c;
        _code(c.clearinghouse, "V2_CLEARINGHOUSE");
        _code(c.settlementOracle, "V2_SETTLEMENT_ORACLE");
        _code(c.chainlinkSource, "V2_SOURCE_CHAINLINK");
        _code(c.univ3Source, "V2_SOURCE_UNIV3");
        _code(c.dataStreamsSource, "V2_SOURCE_DATA_STREAMS");
        _code(c.payoutRouter, "V2_PAYOUT_ROUTER");
        _ok("clearinghouse, oracle, sources and payout adapter have code");
        address chUsdg = Clearinghouse(c.clearinghouse).usdg();
        require(
            chUsdg == in_.usdg,
            string.concat("clearinghouse.usdg() ", vm.toString(chUsdg), " is not V2_USDG ", vm.toString(in_.usdg))
        );
        require(UniV3TwapSource(c.univ3Source).usdg() == in_.usdg, "univ3Source.usdg() is not V2_USDG");
        require(PayoutRouter(c.payoutRouter).usdg() == in_.usdg, "payoutRouter.usdg() is not V2_USDG");
        _ok("clearinghouse, univ3 source and payout adapter all use V2_USDG");
        _signerCanList(c, s);
        _ok("the signer holds LISTING and CONFIG_ADMIN on the accessManager, and all five targets share it");
        address pinCaller = SettlementOracle(c.settlementOracle).clearinghouse();
        require(
            pinCaller == c.clearinghouse,
            string.concat(
                "settlementOracle.clearinghouse() ",
                vm.toString(pinCaller),
                " is not V2_CLEARINGHOUSE: every createSeries would revert in oracle.pin (run the deploy wiring first)"
            )
        );
        _ok("settlementOracle.clearinghouse() is the Clearinghouse (createSeries can pin)");
        require(
            in_.exerciseFeeBps <= V2Constants.EXERCISE_FEE_CEIL_BPS,
            "V2_EXERCISE_FEE_BPS above EXERCISE_FEE_CEIL_BPS (200)"
        );
        _ok(string.concat("exercise fee ", vm.toString(in_.exerciseFeeBps), " bps <= 200"));
    }

    /// @dev The rent rate `m` is registered with: `in_.mintFeePpm` is parallel to `in_.markets`, and an Inputs built
    ///      by hand without it (the preflight suites do that) reads as 0, the v6 behaviour.
    function _cfgMatches(V2Types.MarketConfig memory cur, Inputs memory in_, MarketIn memory m, uint32 ppm)
        internal
        view
        returns (bool)
    {
        return cur.enabled == m.enabled && cur.strikeTick == m.strikeTick && cur.exerciseFeeBps == in_.exerciseFeeBps
            && cur.oracle == in_.c.settlementOracle && cur.mintFeePpm == ppm;
    }

    function _mintFeePpmOf(Inputs memory in_, MarketIn memory m) internal pure returns (uint32) {
        for (uint256 i; i < in_.markets.length && i < in_.mintFeePpm.length; ++i) {
            if (_eq(in_.markets[i].ticker, m.ticker)) return in_.mintFeePpm[i];
        }
        return 0;
    }

    /// @dev INTERFACE_VERSION 8, AND THIS REPLACED A CALL THAT REVERTED. v7 asked each target
    ///      `hasRole(DEFAULT_ADMIN_ROLE, admin)`. Every target here is `Managed`, i.e. `AccessManaged`: it has no
    ///      `hasRole` and no ERC-165, so that staticcall did not return false -- it REVERTED, and took the whole
    ///      preflight with it before a single market could be registered against a v8 deployment. (Found by C8-10B
    ///      while building VerifyV8; C8-10A shipped the deploy rewrite without grepping this path. The failure looked
    ///      like a broken test rather than a broken script, which is why it survived.)
    ///
    ///      The v8 question is not "does the admin hold a role on the target" -- targets hold no roles at all -- but
    ///      "can the signer send what this script sends". `registerMarket` and `setMarketListing` are LISTING, which
    ///      every run needs, so that is what is asserted; the resync path additionally needs MARKET_FEE_MANAGER and
    ///      CONFIG_ADMIN and says so where it queues those calls. The role id comes from `roles.v8.json`, never typed.
    ///
    /// @dev T-182 / F-SCRIPTS-11. IT TAKES THE SIGNER, NOT `V2_ADMIN`, AND THAT IS THE FIX. This used to be called
    ///      `_signerCanList(c, in_.admin)` -- it read the roles of the address the ENVIRONMENT names as admin while
    ///      an entirely different address did the broadcasting. `runWith` is public and takes its `Signer`
    ///      explicitly, so the two are only equal on the `run()` path, where a `require` pins them; every other
    ///      caller got a preflight of a party that was not sending anything. A check that reads the wrong subject
    ///      passes for the wrong reason, which is the same shape as F-DCON-07 one file over.
    ///
    ///      WHAT IT STILL CANNOT SEE, said rather than implied: whether the node will SIGN for `s.addr`. A `pk == 0`
    ///      signer is an address the node is expected to have unlocked, and `run()` is where that is refused.
    function _signerCanList(Contracts memory c, Signer memory s) internal view {
        address admin = s.addr;
        address authority_ = Clearinghouse(c.clearinghouse).authority();
        require(authority_ != address(0), "clearinghouse has no authority: it is not Managed");
        AccessManager mgr = AccessManager(authority_);
        (bool isMember, uint32 listingDelay) = mgr.hasRole(roleIdOf(rolesJson(), "LISTING"), admin);
        require(isMember, string.concat("signer ", vm.toString(admin), " does not hold LISTING on the accessManager"));
        // LISTING alone is not enough to finish a registration. Every run also configures the market's
        // oracle (`setMarketOracle`, CONFIG_ADMIN on the Clearinghouse) and a payout route is
        // `setRouteV3`/`setRouteV4`, CONFIG_ADMIN on the PayoutRouter -- both per roles.v8.json.
        // Preflighting only LISTING let a run get as far as sending calls before the second lane
        // refused it, which on a delayed manager means half the operations scheduled and half not.
        (bool isConfigMember, uint32 configDelay) = mgr.hasRole(roleIdOf(rolesJson(), "CONFIG_ADMIN"), admin);
        require(
            isConfigMember,
            string.concat(
                "signer ",
                vm.toString(admin),
                " does not hold CONFIG_ADMIN on the accessManager: setMarketOracle and the payout route need it"
            )
        );
        // THE EXECUTION DELAY IS HALF THE ANSWER `hasRole` GIVES, AND IT USED TO BE DROPPED HERE. Both reads above
        // discarded their second return value, so a preflight that passed said only "the signer is a member" -- and
        // a delayed member cannot register in one run. The delay has to reach a branch decision, and this is the
        // earliest one available: refusing here costs nothing, while letting it through means the run broadcasts,
        // takes `AccessManagerNotScheduled` from the first target, and leaves the operator reading a revert that
        // never mentions a delay. The manifest's own `.delaysS` is the source (LISTING 1 h, CONFIG_ADMIN 24 h after
        // handover); nothing is typed here, and a manager that really is instant for this signer is unaffected.
        if (listingDelay != 0 || configDelay != 0) {
            require(
                _scheduleEnabled(),
                string.concat(
                    "signer ",
                    vm.toString(admin),
                    " holds LISTING at ",
                    vm.toString(uint256(listingDelay)),
                    "s and CONFIG_ADMIN at ",
                    vm.toString(uint256(configDelay)),
                    "s: a delayed signer cannot register in a single run. Re-run with V2_SCHEDULE=true and",
                    " V2_SCHEDULE_PHASE=schedule, move the node clock past the delay, then run again with",
                    " V2_SCHEDULE_PHASE=execute."
                )
            );
        }
        // All five targets must be gated by the SAME manager, or a LISTING grant on one says nothing about another.
        require(SettlementOracle(c.settlementOracle).authority() == authority_, "settlementOracle: other authority");
        require(ChainlinkFeedSource(c.chainlinkSource).authority() == authority_, "chainlinkSource: other authority");
        require(UniV3TwapSource(c.univ3Source).authority() == authority_, "univ3Source: other authority");
        require(PayoutRouter(c.payoutRouter).authority() == authority_, "payoutRouter: other authority");
    }

    /// @notice One market's token, feed, parameters, pool and on-chain registration state.
    function preflightMarket(Inputs memory in_, MarketIn memory m) public view {
        console2.log(string.concat("preflight ", m.ticker));
        require(bytes(m.ticker).length != 0, "empty ticker in V2_TICKERS");
        _asset(m);
        _feed(m, in_.maxFeedAge);

        require(
            m.strikeTick != 0 && m.strikeTick % V2Constants.PRICE_TICK == 0,
            string.concat(m.ticker, ": strikeTick ", vm.toString(m.strikeTick), " must be a non-zero multiple of 100")
        );
        _ok(string.concat("strikeTick ", vm.toString(m.strikeTick), " (USDG base units per share)"));
        require(
            m.maxDeviationBps != 0 && m.maxDeviationBps <= 1000,
            string.concat(m.ticker, ": maxDeviationBps outside [1, 1000]")
        );
        require(
            m.uncorroboratedDelay >= 30 minutes && m.uncorroboratedDelay <= 24 hours,
            string.concat(m.ticker, ": uncorroboratedDelay outside [1800, 86400] s")
        );
        require(
            m.spotMaxAge != 0 && m.spotMaxAge <= 4 days, string.concat(m.ticker, ": spotMaxAge outside [1, 345600] s")
        );
        _ok(
            string.concat(
                "oracle: deviation ",
                vm.toString(m.maxDeviationBps),
                " bps, uncorroborated delay ",
                vm.toString(m.uncorroboratedDelay),
                " s, spot max age ",
                vm.toString(m.spotMaxAge),
                " s"
            )
        );

        // INTERFACE_VERSION 7 (c05): the collateral-rent rate the market is registered with. The Clearinghouse would
        // revert CeilingExceeded above MINT_FEE_CEIL_PPM; refusing here names the ticker and the variable, before
        // anything is broadcast.
        uint32 ppm = _mintFeePpmOf(in_, m);
        // THE v7 GUARD, INVERTED (V8-DESIGN.md §4.3). v7 refused a rate of 0, because `premiumFeeBps` was 0 and the
        // rent was then the only writer fee. v8 takes 5% of the premium on first sale and launches rent at 0 on
        // every market, so 0 is the expected value and a NON-ZERO one is what must never reach the chain from a
        // script: rent is turned on afterwards through `Clearinghouse.setMarketFees` in the MARKET_FEE_MANAGER lane,
        // where it waits 72 h in the open and the guardian can cancel it. A deploy script is immediate and
        // unreviewed and is the wrong instrument for that. The machinery is the same unspoofable one -- the opt-in
        // runs through `rentAllowed`, which is false in every `forge script` context, so this refusal stands on a
        // direct `forge script RegisterMarkets --rpc-url <live 4663> --broadcast` with `V2_ALLOW_RENT` exported, and
        // on the same run without `--broadcast`, because the forge subcommand is the gate and no flag changes it.
        require(
            ppm == 0 || rentAllowed(in_.allowRent),
            string.concat(m.ticker, ": mintFeePpm is ", vm.toString(uint256(ppm)), ", not 0. ", _WHY_RENT)
        );
        require(
            ppm <= V2Constants.MINT_FEE_CEIL_PPM,
            string.concat(
                m.ticker,
                ": mintFeePpm ",
                vm.toString(uint256(ppm)),
                " is above MINT_FEE_CEIL_PPM (",
                vm.toString(V2Constants.MINT_FEE_CEIL_PPM),
                "): lower ",
                _mk(m.ticker, "MINT_FEE_PPM"),
                " or V2_MINT_FEE_PPM"
            )
        );
        _ok(
            string.concat(
                "mintFeePpm ",
                vm.toString(uint256(ppm)),
                " <= ",
                vm.toString(V2Constants.MINT_FEE_CEIL_PPM),
                " (millionths of locked collateral per 7 days of remaining life)"
            )
        );

        if (m.pool != address(0)) {
            _pool(in_, m);
        } else {
            require(m.minLiquidity == 0, string.concat(m.ticker, ": univ3MinLiquidity set without a pool"));
            _ok("no pool: Chainlink only, ITM call payouts in kind");
        }

        V2Types.MarketConfig memory cur = Clearinghouse(in_.c.clearinghouse).market(m.asset);
        if (cur.strikeTick == 0) {
            _ok("not registered on the Clearinghouse yet");
        } else if (_cfgMatches(cur, in_, m, ppm)) {
            _ok("already registered on the Clearinghouse with this config");
        } else {
            string memory drift = string.concat(
                m.ticker,
                ": already registered on the Clearinghouse with another config (enabled ",
                cur.enabled ? "true" : "false",
                ", strikeTick ",
                vm.toString(cur.strikeTick),
                ", exerciseFeeBps ",
                vm.toString(cur.exerciseFeeBps),
                ", mintFeePpm ",
                vm.toString(uint256(cur.mintFeePpm)),
                ", oracle ",
                vm.toString(cur.oracle)
            );
            require(in_.resync, string.concat(drift, "): change a live market with setMarketConfig by hand, not here"));
            require(
                !cur.enabled || cur.strikeTick == m.strikeTick,
                string.concat(
                    m.ticker,
                    ": enabled tick changes refused (strikeTick ",
                    vm.toString(cur.strikeTick),
                    " -> ",
                    vm.toString(m.strikeTick),
                    "): disable the market first"
                )
            );
            require(
                !cur.enabled || cur.mintFeePpm == ppm,
                string.concat(
                    m.ticker,
                    ": enabled mintFeePpm changes refused (mintFeePpm ",
                    vm.toString(uint256(cur.mintFeePpm)),
                    " -> ",
                    vm.toString(uint256(ppm)),
                    "): disable the market first"
                )
            );
            require(
                cur.exerciseFeeBps == in_.exerciseFeeBps && cur.oracle == in_.c.settlementOracle,
                string.concat(drift, "): exercise fee and oracle of a registered market are never changed here")
            );
            _ok("--resync will setMarketConfig (enabled from v2.status; tick/rent only while disabled)");
        }
        bytes32 feedId = DataStreamsSource(in_.c.dataStreamsSource).feedIdOf(m.asset);
        console2.log(
            string.concat(
                "  info  DataStreamsSource feed id ", feedId == bytes32(0) ? "none (disabled)" : vm.toString(feedId)
            )
        );
    }

    /// @dev The Stock Token: DeploySolo.s.sol's checks (a token without the two issuer views is not a Stock Token).
    function _asset(MarketIn memory m) internal view {
        _code(m.asset, _mk(m.ticker, "ASSET"));
        string memory symbol = IERC20Metadata(m.asset).symbol();
        require(
            _eq(symbol, m.ticker),
            string.concat(
                "asset symbol mismatch: ",
                _mk(m.ticker, "ASSET"),
                " ",
                vm.toString(m.asset),
                " is \"",
                symbol,
                "\", ticker is \"",
                m.ticker,
                "\""
            )
        );
        _ok(string.concat("asset symbol == ticker (", symbol, ")"));
        require(IERC20Metadata(m.asset).decimals() == 18, string.concat(m.ticker, ": asset decimals != 18"));
        _ok("asset decimals == 18");
        (bool ok, bytes memory data) = m.asset.staticcall(abi.encodeWithSelector(IStockToken.uiMultiplier.selector));
        require(
            ok && data.length == 32,
            string.concat(m.ticker, ": asset uiMultiplier() probe failed: not a Robinhood Stock Token?")
        );
        require(abi.decode(data, (uint256)) > 0, string.concat(m.ticker, ": asset uiMultiplier() == 0"));
        _ok(string.concat("asset uiMultiplier() answers, > 0 (", vm.toString(abi.decode(data, (uint256))), ")"));
        (ok, data) = m.asset.staticcall(abi.encodeWithSelector(IStockToken.oraclePaused.selector));
        require(
            ok && data.length == 32,
            string.concat(m.ticker, ": asset oraclePaused() probe failed: not a Robinhood Stock Token?")
        );
        require(
            !abi.decode(data, (bool)),
            string.concat(m.ticker, ": asset oraclePaused() is true: the issuer has halted its oracle")
        );
        _ok("asset oraclePaused() answers, false");
    }

    /// @dev The Chainlink proxy of the ticker, live.
    function _feed(MarketIn memory m, uint32 maxAge) internal view {
        _code(m.feed, _mk(m.ticker, "FEED"));
        IChainlinkFeed f = IChainlinkFeed(m.feed);
        string memory description = f.description();
        require(
            _contains(description, m.ticker),
            string.concat(
                "feed description mismatch: ",
                _mk(m.ticker, "FEED"),
                " ",
                vm.toString(m.feed),
                " is \"",
                description,
                "\", ticker is \"",
                m.ticker,
                "\""
            )
        );
        _ok(string.concat("feed description contains the ticker (\"", description, "\")"));
        require(f.decimals() == 8, string.concat(m.ticker, ": unexpected feed decimals"));
        _ok("feed decimals == 8");
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = f.latestRoundData();
        require(roundId != 0, string.concat(m.ticker, ": feed roundId == 0"));
        require(answer > 0, string.concat(m.ticker, ": feed answer <= 0"));
        require(
            updatedAt != 0 && updatedAt <= block.timestamp,
            string.concat(m.ticker, ": feed updatedAt is zero or in the future")
        );
        uint256 age = block.timestamp - updatedAt;
        require(
            age <= maxAge,
            string.concat(
                m.ticker,
                ": feed is stale: age ",
                vm.toString(age),
                " s > V2_MAX_FEED_AGE_S ",
                vm.toString(uint256(maxAge))
            )
        );
        _ok(string.concat("feed answer ", vm.toString(answer), " (8 dp), age ", vm.toString(age), " s"));
    }

    /// @dev The registry's Uniswap v3 pool: the pair, the factory's own pool at its fee, live liquidity, 30-minute
    ///      observations, and its floor.
    function _pool(Inputs memory in_, MarketIn memory m) internal view {
        IUniV3PoolView pool = IUniV3PoolView(m.pool);
        _code(m.pool, _mk(m.ticker, "POOL"));
        address t0 = pool.token0();
        address t1 = pool.token1();
        require(
            (t0 == m.asset && t1 == in_.usdg) || (t0 == in_.usdg && t1 == m.asset),
            string.concat(m.ticker, ": pool tokens ", vm.toString(t0), ", ", vm.toString(t1), " are not {asset, USDG}")
        );
        _ok("pool tokens are {asset, USDG}");
        uint24 fee = pool.fee();
        require(
            m.poolFee == 0 || m.poolFee == fee,
            string.concat(
                m.ticker,
                ": pool fee() ",
                vm.toString(uint256(fee)),
                " is not ",
                _mk(m.ticker, "POOL_FEE"),
                " ",
                vm.toString(uint256(m.poolFee))
            )
        );
        require(
            fee <= V2Constants.MAX_ROUTE_FEE_TIER,
            string.concat(
                m.ticker,
                ": pool fee tier ",
                vm.toString(uint256(fee)),
                " is above 10000 (1 %): the Clearinghouse counts at most MAX_ROUTE_FEE_BPS (100 bps) of a payout",
                " route's fee, so every conversion through this pool would pay in kind, and",
                " UniV3PayoutAdapter.setRoute refuses it (CeilingExceeded)"
            )
        );
        _ok(
            string.concat(
                "pool fee tier ", vm.toString(uint256(fee)), " <= 10000 (a payout route the floor allows for)"
            )
        );
        // INTERFACE_VERSION 8: the payout leg is the PayoutRouter, whose v3 factory getter is `v3Factory()`.
        // The v7 `UniV3PayoutAdapter.factory()` cast compiles against any address and REVERTS on a v8 deployment.
        address factory = PayoutRouter(in_.c.payoutRouter).v3Factory();
        address canonical = IUniV3PoolFactory(factory).getPool(m.asset, in_.usdg, fee);
        require(
            canonical == m.pool,
            string.concat(
                m.ticker,
                ": the Uniswap v3 factory's (asset, USDG) pool at fee ",
                vm.toString(uint256(fee)),
                " is ",
                vm.toString(canonical),
                ", not the registry pool"
            )
        );
        _ok(string.concat("pool is the factory's (asset, USDG) pool at fee ", vm.toString(uint256(fee))));
        uint128 liquidity = pool.liquidity();
        require(liquidity > 0, string.concat(m.ticker, ": pool liquidity() == 0"));
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;
        (bool ok,) = m.pool.staticcall(abi.encodeCall(IUniV3PoolView.observe, (ago)));
        require(ok, string.concat(m.ticker, ": pool observe([1800, 0]) failed: no 30-minute TWAP"));
        _ok("pool observe([1800, 0]) answers");
        (,,, uint16 cardinality,,,) = pool.slot0();
        // The named threshold UniV3TwapSource.setPool itself enforces (owner sign-off c10, DECISIONS-2026-09-17 §7):
        // every launch pool but NVDA's and SPCX's is below it and is registered Chainlink-only instead, so this
        // refusal has to fire before anything is broadcast.
        uint256 minCardinality = V2Constants.MIN_POOL_OBSERVATION_CARDINALITY;
        require(
            cardinality >= minCardinality,
            string.concat(
                m.ticker,
                ": pool observationCardinality ",
                vm.toString(uint256(cardinality)),
                " is below ",
                vm.toString(minCardinality),
                " (SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1): one dust mint or burn per second could overwrite an",
                " expiry's window before the snapshot grace ends, and UniV3TwapSource.setPool refuses the pool",
                " (UnsupportedAsset); call increaseObservationCardinalityNext(",
                vm.toString(minCardinality),
                ") on the pool and wait until slot0().observationCardinality reaches it"
            )
        );
        _ok(
            string.concat(
                "pool observationCardinality ",
                vm.toString(uint256(cardinality)),
                " >= ",
                vm.toString(minCardinality),
                " (outlasts a flood through the snapshot grace)"
            )
        );
        require(m.minLiquidity > 0, string.concat(m.ticker, ": univ3MinLiquidity must be > 0 with a pool"));
        if (liquidity < m.minLiquidity) {
            _warn(
                string.concat(
                    "pool liquidity ",
                    vm.toString(liquidity),
                    " is below univ3MinLiquidity ",
                    vm.toString(m.minLiquidity),
                    ": its source will report not-ok until it recovers (Chainlink-only settlement)"
                )
            );
        } else {
            _ok(
                string.concat(
                    "pool liquidity ", vm.toString(liquidity), " >= univ3MinLiquidity ", vm.toString(m.minLiquidity)
                )
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                         TRANSFER PROBE (SEC-12)
    //////////////////////////////////////////////////////////////*/

    /// @notice What {probeTransfers} moves: one whole share (1e18 base units of an 18-dp Stock Token).
    /// @dev A percentage fee rounds to nothing on a small probe (1 wei * bps / 10_000 == 0), so a 1-wei round trip
    ///      would pass a fee-charging token. At 1e18 any fee of at least 1e-18 of the amount moves a balance.
    uint256 public constant TRANSFER_PROBE_AMOUNT = 1e18;

    /// @notice The simulated holder {probeTransfers} seeds and pranks: a fixed address nobody holds a key for.
    address public constant TRANSFER_PROBE_HOLDER =
        address(uint160(uint256(keccak256("RegisterMarkets.transferProbe"))));

    /// @notice SEC-12: refuses a token whose transfers do not move EXACTLY the amount, before anything is sent.
    /// @dev WHY THIS LIVES HERE AND NOT IN {Clearinghouse.registerMarket}. The Clearinghouse books every outflow as
    ///      exactly `amount` ({withdraw}, a redemption's transfer, {sweepFees}); only {deposit} and {convertPayout}
    ///      measure. So a token that debits the sender more than the amount leaves other holders' credit unbacked
    ///      (invariant I2'). The contract cannot probe for that at registration: it holds none of the token yet, and
    ///      on the delayed LISTING lane its caller may be the AccessManager. This script can: it runs on a fork of the
    ///      chain it is about to send to, so it simulates the two legs the Clearinghouse actually takes and throws
    ///      the simulation away.
    ///        1. seed TRANSFER_PROBE_HOLDER with twice TRANSFER_PROBE_AMOUNT by writing its balance slot (the slot
    ///           `balanceOf` reads; a balance computed from more than one slot, as a rebasing token's is, cannot be
    ///           seeded and is refused);
    ///        2. deposit leg: the holder approves the Clearinghouse, which pulls with transferFrom;
    ///        3. outflow leg: the Clearinghouse transfers the amount back;
    ///      each leg must debit the sender and credit the recipient by exactly the amount, and a revert or a `false`
    ///      return is a refusal too. The state is then reverted to the snapshot taken before step 1, so nothing the
    ///      probe did survives into the calls this script sends or into a test's later assertions.
    ///      STRICTER THAN I2' NEEDS, ON PURPOSE. A fee the recipient absorbs does not break I2' (the contract is still
    ///      debited `amount`), but it is refused here too: the listed universe is plain Stock Tokens, and "moves
    ///      exactly the amount" is one rule an operator can read.
    ///      WHAT IT CANNOT SEE: anything that happens after this block. An issuer can upgrade a Stock Token's beacon,
    ///      burn from any address (`adminBurn`) or pause and blocklist; a later rebase or wipe breaks I2' with no
    ///      transfer at all. Those are accepted issuer risks, not listing mistakes. And a LISTING call sent outside
    ///      this script (a Safe transaction built by hand) skips the probe entirely.
    /// @param in_ The run inputs; only `in_.c.clearinghouse` is read.
    /// @param m The market whose asset is probed.
    function probeTransfers(Inputs memory in_, MarketIn memory m) public {
        address ch = in_.c.clearinghouse;
        address holder = TRANSFER_PROBE_HOLDER;
        uint256 amount = TRANSFER_PROBE_AMOUNT;
        uint256 snapshot = vm.snapshotState();

        // Twice the amount, so a token that charges the sender on top shows as a wrong debit, not as a revert.
        _seedProbeBalance(m, holder, 2 * amount);
        uint256 chBefore = IERC20(m.asset).balanceOf(ch);

        vm.prank(holder);
        _probeCall(m, abi.encodeCall(IERC20.approve, (ch, amount)), "approve");
        vm.prank(ch);
        _probeCall(m, abi.encodeCall(IERC20.transferFrom, (holder, ch, amount)), "transferFrom into the Clearinghouse");
        _probeLeg(m, "deposit", holder, amount, ch, chBefore + amount);

        vm.prank(ch);
        _probeCall(m, abi.encodeCall(IERC20.transfer, (holder, amount)), "transfer out of the Clearinghouse");
        _probeLeg(m, "outflow", ch, chBefore, holder, 2 * amount);

        vm.revertToState(snapshot);
        _ok(string.concat("asset moves exactly the amount, both legs (", vm.toString(amount), " base units)"));
    }

    /// @dev Writes `amount` into the one slot `balanceOf(holder)` reads. Tries the slots the read touched, last
    ///      first (a proxy's own reads come before the balance), and puts back any slot that did not answer.
    function _seedProbeBalance(MarketIn memory m, address holder, uint256 amount) private {
        vm.record();
        IERC20(m.asset).balanceOf(holder);
        (bytes32[] memory reads,) = vm.accesses(m.asset);
        vm.stopRecord();
        for (uint256 i = reads.length; i != 0; --i) {
            bytes32 slot = reads[i - 1];
            bytes32 prev = vm.load(m.asset, slot);
            vm.store(m.asset, slot, bytes32(amount));
            try IERC20(m.asset).balanceOf(holder) returns (uint256 got) {
                if (got == amount) return;
            } catch {}
            vm.store(m.asset, slot, prev);
        }
        revert(
            string.concat(
                m.ticker,
                ": asset transfer probe cannot seed a balance: balanceOf is not one storage slot (a rebasing or"
                " computed balance?)"
            )
        );
    }

    /// @dev One pranked token call; a revert or a `false` return is a refusal naming the step.
    function _probeCall(MarketIn memory m, bytes memory data, string memory step) private {
        (bool ok, bytes memory ret) = m.asset.call(data);
        require(
            ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool)))),
            string.concat(m.ticker, ": asset transfer probe: ", step, " reverted or returned false")
        );
    }

    /// @dev After one leg, `from` must hold exactly `fromAfter` and `to` exactly `toAfter`.
    function _probeLeg(
        MarketIn memory m,
        string memory leg,
        address from,
        uint256 fromAfter,
        address to,
        uint256 toAfter
    ) private view {
        uint256 fromGot = IERC20(m.asset).balanceOf(from);
        uint256 toGot = IERC20(m.asset).balanceOf(to);
        require(
            fromGot == fromAfter && toGot == toAfter,
            string.concat(
                m.ticker,
                ": asset does not transfer exactly: the ",
                leg,
                " leg left the sender ",
                vm.toString(fromGot),
                " (expected ",
                vm.toString(fromAfter),
                ") and the recipient ",
                vm.toString(toGot),
                " (expected ",
                vm.toString(toAfter),
                ")"
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                                   PLAN
    //////////////////////////////////////////////////////////////*/

    /// @notice The admin calls that bring one market to its registry config, and whether they include registerMarket.
    function plan(Inputs memory in_, MarketIn memory m) public view returns (Call[] memory calls, bool registers) {
        // At most: two source setOracle, setFeed, setPool (or its removal), setMarket, setRoute, then the
        // Clearinghouse's registerMarket plus setMarketFees plus setMarketOracle. INTERFACE_VERSION 8 split the one
        // v7 `registerMarket` tuple into up to three calls, so the v7 buffer of 7 is no longer enough.
        Call[] memory buf = new Call[](10);
        uint256 n;
        Contracts memory c = in_.c;
        ChainlinkFeedSource chainlink = ChainlinkFeedSource(c.chainlinkSource);
        UniV3TwapSource univ3 = UniV3TwapSource(c.univ3Source);
        SettlementOracle oracle = SettlementOracle(c.settlementOracle);
        PayoutRouter router = PayoutRouter(c.payoutRouter);

        // The sources the market lists must accept the oracle's pins before the registration makes series possible.
        // DeployV2 wires this for the whole set, so a normal run plans nothing here.
        if (!chainlink.isOracle(c.settlementOracle)) {
            buf[n++] = Call(
                c.chainlinkSource,
                abi.encodeCall(chainlink.setOracle, (c.settlementOracle, true)),
                "chainlinkSource.setOracle(settlementOracle, true)"
            );
        }
        if (m.pool != address(0) && !univ3.isOracle(c.settlementOracle)) {
            buf[n++] = Call(
                c.univ3Source,
                abi.encodeCall(univ3.setOracle, (c.settlementOracle, true)),
                "univ3Source.setOracle(settlementOracle, true)"
            );
        }

        uint32 maxStale = chainlink.DEFAULT_MAX_STALE();
        uint16 maxJump = chainlink.DEFAULT_MAX_ROUND_JUMP_BPS();
        (address feed, uint32 stale, uint16 jump) = chainlink.feeds(m.asset);
        if (feed != m.feed || stale != maxStale || jump != maxJump) {
            buf[n++] = Call(
                c.chainlinkSource,
                abi.encodeCall(chainlink.setFeed, (m.asset, m.feed, maxStale, maxJump)),
                string.concat("chainlinkSource.setFeed(", m.ticker, ", feed, 26 h, 2000 bps)")
            );
        }

        uint32 window = univ3.DEFAULT_WINDOW();
        (address pool,,, uint32 curWindow, uint128 curFloor) = univ3.pools(m.asset);
        if (m.pool != address(0) && (pool != m.pool || curWindow != window || curFloor != m.minLiquidity)) {
            buf[n++] = Call(
                c.univ3Source,
                abi.encodeCall(univ3.setPool, (m.asset, m.pool, m.minLiquidity, window)),
                string.concat("univ3Source.setPool(", m.ticker, ", pool, ", vm.toString(m.minLiquidity), " L, 300 s)")
            );
        }

        address[] memory want = new address[](m.pool == address(0) ? 1 : 2);
        want[0] = c.chainlinkSource;
        if (m.pool != address(0)) want[1] = c.univ3Source;
        (address[] memory sources, uint16 dev, uint32 delay, uint32 age) = oracle.marketConfig(m.asset);
        if (
            !_sameList(sources, want) || dev != m.maxDeviationBps || delay != m.uncorroboratedDelay
                || age != m.spotMaxAge
        ) {
            buf[n++] = Call(
                c.settlementOracle,
                abi.encodeCall(
                    oracle.setMarket, (m.asset, want, m.maxDeviationBps, m.uncorroboratedDelay, m.spotMaxAge)
                ),
                string.concat(
                        "settlementOracle.setMarket(",
                        m.ticker,
                        m.pool == address(0) ? ", [chainlink], " : ", [chainlink, univ3], ",
                        vm.toString(m.maxDeviationBps),
                        " bps, ",
                        vm.toString(m.uncorroboratedDelay),
                        " s, ",
                        vm.toString(m.spotMaxAge),
                        " s)"
                    )
            );
        }

        // After setMarket: while the oracle's list still names the pool source, removing its pool would refuse every
        // first series of an expiry (pinning fails closed).
        if (m.pool == address(0) && pool != address(0)) {
            buf[n++] = Call(
                c.univ3Source,
                abi.encodeCall(univ3.setPool, (m.asset, address(0), 0, 0)),
                string.concat("univ3Source.setPool(", m.ticker, ", 0): remove a pool the registry does not list")
            );
        }

        // INTERFACE_VERSION 8 ROUTE API. Payout is markets[].v2.payoutRoute (O8-03), NOT the
        // settlement univ3Pool. A null payoutRoute is reported and the market is still
        // registered; it is never skipped. clearRoute is GUARDIAN and is not sent from here.
        IPayoutRouter.Route memory route = router.routes(m.asset);
        uint8 venue = _payoutVenue(m);
        if (venue == 0) {
            console2.log(
                string.concat("  info  ", m.ticker, " payoutRoute null: registered with no route, not skipped")
            );
        } else if (venue == 1) {
            uint24 fee = _u24(vm.envUint(_mk(m.ticker, "PAYOUT_FEE")), _mk(m.ticker, "PAYOUT_FEE"));
            if (route.venue != IPayoutRouter.Venue.V3 || route.fee != fee) {
                buf[n++] = Call(
                    c.payoutRouter,
                    abi.encodeCall(PayoutRouter.setRouteV3, (m.asset, fee)),
                    string.concat(
                        "payoutRouter.setRouteV3(",
                        m.ticker,
                        ", fee ",
                        vm.toString(uint256(fee)),
                        "): CONFIG_ADMIN lane, 24 h"
                    )
                );
            }
        } else {
            uint24 fee = _u24(vm.envUint(_mk(m.ticker, "PAYOUT_FEE")), _mk(m.ticker, "PAYOUT_FEE"));
            int24 ts = _i24(vm.envInt(_mk(m.ticker, "PAYOUT_TICK_SPACING")), _mk(m.ticker, "PAYOUT_TICK_SPACING"));
            // THE PINNED POOL IS THE POINT. setRouteV4 takes (fee, tickSpacing) and REBUILDS the
            // PoolKey itself; it never sees the poolId O8-03 pinned. A wrong fee or tickSpacing
            // therefore does not revert -- it silently routes every winning payout through a
            // different pool. Rebuild the same key here and require it to hash to the pin.
            _requirePinnedPool(in_, m, fee, ts);
            if (route.venue != IPayoutRouter.Venue.V4 || route.fee != fee || route.tickSpacing != ts) {
                buf[n++] = Call(
                    c.payoutRouter,
                    abi.encodeCall(PayoutRouter.setRouteV4, (m.asset, fee, ts)),
                    string.concat(
                        "payoutRouter.setRouteV4(",
                        m.ticker,
                        ", fee ",
                        vm.toString(uint256(fee)),
                        ", tickSpacing ",
                        vm.toString(int256(ts)),
                        "): CONFIG_ADMIN lane, 24 h"
                    )
                );
            }
        }

        n = _clearinghouseCalls(in_, m, buf, n);
        registers = _isRegisterCall(buf, n);
        require(n <= buf.length, "plan buffer too small");
        calls = _trim(buf, n);
    }

    /// @dev `V2_MARKET_<T>_PAYOUT_VENUE`: unset/empty/none/null = 0, v3 = 1, v4 = 2. Parallel to
    ///      MarketIn because that struct lives in V2DeployBase, which this task must not edit.
    function _payoutVenue(MarketIn memory m) internal view returns (uint8) {
        if (!vm.envExists(_mk(m.ticker, "PAYOUT_VENUE"))) return 0;
        string memory v = vm.envString(_mk(m.ticker, "PAYOUT_VENUE"));
        if (bytes(v).length == 0 || _eq(v, "none") || _eq(v, "null")) return 0;
        if (_eq(v, "v3")) return 1;
        if (_eq(v, "v4")) return 2;
        revert(string.concat(m.ticker, ": PAYOUT_VENUE must be none|v3|v4, got ", v));
    }

    /// @dev The three values `V2_SCHEDULE_PHASE` may take, and what each one sends.
    uint8 internal constant PHASE_BOTH = 0;
    uint8 internal constant PHASE_SCHEDULE = 1;
    uint8 internal constant PHASE_EXECUTE = 2;

    /// @dev `V2_SCHEDULE_PHASE`: unset = one run (only legal when no selected call is delayed),
    ///      `schedule` = AccessManager.schedule the delayed calls and stop, `execute` = call the
    ///      targets of calls scheduled by an earlier run.
    function _schedulePhase() internal view virtual returns (uint8) {
        string memory p = vm.envOr("V2_SCHEDULE_PHASE", string(""));
        if (bytes(p).length == 0) return PHASE_BOTH;
        if (_eq(p, "schedule")) return PHASE_SCHEDULE;
        if (_eq(p, "execute")) return PHASE_EXECUTE;
        revert(string.concat("V2_SCHEDULE_PHASE must be schedule or execute (or unset), got ", p));
    }

    /// @dev Whether this run goes through the manager's schedule at all (`V2_SCHEDULE`).
    ///
    ///      IT IS A `virtual` SEAM RATHER THAN A BARE `vm.envOr` BECAUSE THE ENVIRONMENT IS PROCESS-WIDE AND FORGE
    ///      RUNS TEST CASES CONCURRENTLY. A fixture that drove this with `vm.setEnv` would race every other case in
    ///      the same `forge test` process -- measured, not assumed: the first version of
    ///      `test/v2/unit/AccessManagerDelays.t.sol` did exactly that and three of its six cases failed, each one
    ///      reading the `false` that a sibling case had just written. Overriding the seam gives a test its own
    ///      answer without touching anything global; a real run still reads the environment, here, in one place.
    function _scheduleEnabled() internal view virtual returns (bool) {
        return vm.envOr("V2_SCHEDULE", false);
    }

    /// @dev `V2_MARKET_<T>_PAYOUT_POOL_ID` is the v4 pool O8-03 pinned for this asset. It is what the
    ///      registry promises payouts will swap through, and it is the only value that ties the
    ///      (fee, tickSpacing) pair to a specific pool: {V4Currency.key} sorts the two currencies and
    ///      fixes `hooks` to the zero address, so the id is fully determined by asset, usdg, fee and
    ///      tickSpacing. An unset pin is allowed (a registry that pins nothing promises nothing) and
    ///      is reported, never silently skipped.
    function _requirePinnedPool(Inputs memory in_, MarketIn memory m, uint24 fee, int24 tickSpacing) internal view {
        string memory name = _mk(m.ticker, "PAYOUT_POOL_ID");
        if (!vm.envExists(name)) {
            console2.log(
                string.concat(
                    "  WARN  ",
                    m.ticker,
                    " v4 route has no pinned poolId: nothing checks the pool this fee/tickSpacing resolves to"
                )
            );
            return;
        }
        bytes32 pinned = vm.envBytes32(name);
        if (pinned == bytes32(0)) {
            console2.log(
                string.concat(
                    "  WARN  ",
                    m.ticker,
                    " v4 route pin is zero: nothing checks the pool this fee/tickSpacing resolves to"
                )
            );
            return;
        }
        V4PoolKey memory k = V4Currency.key(m.asset, in_.usdg, fee, tickSpacing);
        bytes32 built = V4Currency.id(k);
        require(
            built == pinned,
            string.concat(
                m.ticker,
                ": setRouteV4(fee ",
                vm.toString(uint256(fee)),
                ", tickSpacing ",
                vm.toString(int256(tickSpacing)),
                ") resolves to pool ",
                vm.toString(built),
                ", not the pinned ",
                vm.toString(pinned),
                " -- payouts would swap through a different pool and nothing on chain would say so"
            )
        );
        console2.log(
            string.concat("  ok    ", m.ticker, " v4 route resolves to the pinned poolId ", vm.toString(pinned))
        );
    }

    /// @dev The `AccessManager` this run's targets answer to: the explicit `V2_ACCESS_MANAGER` when the inputs carry
    ///      one, otherwise the Clearinghouse's own authority. Resolved in ONE place because BOTH branches of
    ///      {_executeScheduled} need it now -- the scheduling branch to plan the operations, and the single-run
    ///      branch to prove a single run is legal at all.
    function _manager(Inputs memory in_) internal view returns (AccessManager) {
        address mgrAddr = in_.c.accessManager;
        if (mgrAddr == address(0)) mgrAddr = Clearinghouse(in_.c.clearinghouse).authority();
        require(
            mgrAddr != address(0),
            "no accessManager: V2_ACCESS_MANAGER is unset and the clearinghouse reports no authority"
        );
        return AccessManager(mgrAddr);
    }

    /// @dev One call's single-run legality, asked of the manager rather than assumed. `canCall` is the SAME query
    ///      `Managed._checkCanCall` makes on the target (`src/v2/access/Managed.sol:66`), for the same
    ///      (caller, target, selector) triple, so agreeing with it here is the point: the script refuses before it
    ///      broadcasts anything instead of discovering the delay from a revert in the middle of a batch.
    ///
    ///      THE TWO NEGATIVE ANSWERS ARE NOT THE SAME FAULT and must not share a message. `(false, delay != 0)` is a
    ///      delayed member -- the role is right, the operation is missing, and the fix is two runs. `(false, 0)` is
    ///      no permission at all -- an unmapped (target, selector) or a signer without the role -- and no amount of
    ///      waiting fixes it.
    function _requireImmediate(AccessManager mgr, Signer memory s, Call memory c) internal view {
        require(c.data.length >= 4, string.concat("empty calldata: ", c.what));
        // casting to 'bytes4' keeps the leading four bytes on purpose: they are the call's selector
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool immediate, uint32 delay) = mgr.canCall(s.addr, c.to, bytes4(c.data));
        if (immediate) return;
        require(
            delay == 0,
            string.concat(
                "a delayed admin call cannot be sent by a single run: ",
                c.what,
                " waits ",
                vm.toString(uint256(delay)),
                "s. Re-run with V2_SCHEDULE=true V2_SCHEDULE_PHASE=schedule, move the node clock past the delay,",
                " then run again with V2_SCHEDULE_PHASE=execute."
            )
        );
        revert(
            string.concat(
                "the signer cannot make this call at all: ",
                c.what,
                " -- canCall answers neither immediate nor delayed, so the (target, selector) is unmapped or ",
                vm.toString(s.addr),
                " does not hold its role"
            )
        );
    }

    /// @dev After AccessManager handover, LISTING is 1 h and CONFIG_ADMIN is 24 h
    ///      (`roles.v8.json` `.delaysS`, never typed). A direct target call is not immediate, so
    ///      the run must schedule → wait → call the TARGET from the Safe (06-QUIRKS §D.2:
    ///      `manager.execute` would make the target see `msg.sender == manager`). `V2_SCHEDULE`
    ///      is exported by the wrapper whenever a run registers or lists; without it THIS SCRIPT
    ///      refuses, in {_requireImmediate}, before anything is broadcast. It used to send the call
    ///      raw and leave the refusal to AccessManager, which reached the operator as
    ///      "admin call reverted: <what>" from {V2DeployBase._execute} with no mention of a delay --
    ///      and, worse, only after earlier calls in the same batch had already landed.
    ///
    ///      THE WAIT IS A SEPARATE PROCESS, NOT A CHEATCODE. `vm.warp` moves the script's own EVM
    ///      and nothing else: under `--broadcast` forge simulates first and replays the collected
    ///      transactions on the node afterwards, where the AccessManager still sees the delay
    ///      unexpired and reverts. So scheduling and executing are two forge invocations with a
    ///      NODE-clock jump between them (`evm_increaseTime` + `evm_mine` on a rehearsal fork; on
    ///      mainnet, the operator simply comes back a day later). A single-run attempt at a
    ///      delayed call is refused below rather than reverting on chain halfway through.
    /// @return executed true when the targets were actually called (any phase but `schedule`).
    function _executeScheduled(Inputs memory in_, Signer memory s, Call[] memory calls)
        internal
        returns (bool executed)
    {
        uint8 phase = _schedulePhase();
        if (calls.length == 0) return phase != PHASE_SCHEDULE;
        AccessManager mgr = _manager(in_);
        if (!_scheduleEnabled()) {
            require(
                phase == PHASE_BOTH,
                "V2_SCHEDULE_PHASE without V2_SCHEDULE: there is nothing to schedule and nothing to execute"
            );
            // THE SINGLE-RUN PATH NOW ASKS THE QUESTION THE TARGET IS ABOUT TO ASK. Until this loop existed, the
            // `V2_SCHEDULE` unset branch fell straight into {_execute}, which sends every call raw -- so the
            // partition below never ran and immediacy was ASSUMED rather than read. The doc above says a single-run
            // attempt at a delayed call "is refused below rather than reverting on chain halfway through", and that
            // refusal did exist -- on the other branch, the one this path skips. Against a delayed manager the run
            // therefore sent the first call, took `AccessManagerNotScheduled` from the target's own `restricted`,
            // and surfaced it as "admin call reverted: <what>" from {V2DeployBase._execute} with the delay nowhere
            // in the message. A precondition that is only written in a comment is not a guard.
            for (uint256 i; i < calls.length; ++i) {
                _requireImmediate(mgr, s, calls[i]);
            }
            _execute(s, calls);
            return true;
        }
        for (uint256 i; i < calls.length; ++i) {
            require(calls[i].data.length >= 4, string.concat("empty calldata: ", calls[i].what));
            // casting to 'bytes4' keeps the leading four bytes on purpose: they are the call's selector
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 sel = bytes4(calls[i].data);
            (bool immediate, uint32 delay) = mgr.canCall(s.addr, calls[i].to, sel);
            if (immediate) {
                // An immediate call has no operation to schedule, so the schedule phase has nothing
                // to do for it and the execute phase sends it.
                if (phase == PHASE_SCHEDULE) continue;
                _startBroadcast(s);
                (bool ok,) = calls[i].to.call(calls[i].data);
                vm.stopBroadcast();
                require(ok, string.concat("admin call reverted: ", calls[i].what));
                continue;
            }
            require(
                delay != 0,
                string.concat(
                    "registration attempted without the LISTING schedule: ",
                    calls[i].what,
                    " is not immediate and has no delay"
                )
            );
            require(
                phase != PHASE_BOTH,
                string.concat(
                    "a delayed admin call cannot be scheduled and executed by one run: ",
                    calls[i].what,
                    " waits ",
                    vm.toString(uint256(delay)),
                    "s, and that wait is a node-clock jump between two forge invocations. Run with",
                    " V2_SCHEDULE_PHASE=schedule, move the node clock past the delay, then run again",
                    " with V2_SCHEDULE_PHASE=execute."
                )
            );
            if (phase == PHASE_SCHEDULE) {
                _startBroadcast(s);
                // schedule() returns (operationId, nonce) -- NOT the ready time. readyAt is read back
                // with getSchedule so the number printed here is the one the manager will enforce.
                (bytes32 opId, uint32 nonce) = mgr.schedule(calls[i].to, calls[i].data, 0);
                vm.stopBroadcast();
                console2.log(string.concat("  scheduled ", calls[i].what));
                console2.log("  opId", vm.toString(opId));
                console2.log("  nonce", vm.toString(uint256(nonce)));
                console2.log("  delayS", vm.toString(uint256(delay)));
                console2.log("  readyAt", vm.toString(uint256(mgr.getSchedule(opId))));
                continue;
            }
            _startBroadcast(s);
            (bool ok,) = calls[i].to.call(calls[i].data);
            vm.stopBroadcast();
            require(ok, string.concat("delayed admin call reverted: ", calls[i].what));
            console2.log(string.concat("  executed ", calls[i].what));
        }
        return phase != PHASE_SCHEDULE;
    }

    /// @dev The Clearinghouse half of one market's plan: the registration, or the `--resync` reconciliation of an
    ///      already-registered market.
    ///
    ///      INTERFACE_VERSION 8 SPLIT THE ONE-TUPLE SURFACE. v7 had
    ///      `registerMarket(address,(bool,bool,uint64,uint16,address,uint32))` and `setMarketConfig`; commit 07d6304
    ///      deleted both. v8 has `registerMarket(address underlying, uint64 strikeTick, bool enabled)`
    ///      (src/v2/Clearinghouse.sol:225) plus three narrow setters, each in its OWN role lane. The registration
    ///      composes the rest of the config from the CONTRACT DEFAULTS (`_defaultExerciseFeeBps`, `defaultOracle`,
    ///      `_defaultMintFeePpm`; :233-241), which `DeployV8` sets for the whole set, so a market whose registry row
    ///      differs from those defaults needs its own `setMarketFees` / `setMarketOracle` right after.
    function _clearinghouseCalls(Inputs memory in_, MarketIn memory m, Call[] memory buf, uint256 n)
        internal
        view
        returns (uint256)
    {
        Contracts memory c = in_.c;
        Clearinghouse ch = Clearinghouse(c.clearinghouse);
        V2Types.MarketConfig memory cur = ch.market(m.asset);
        uint32 ppm = _mintFeePpmOf(in_, m);
        if (cur.strikeTick == 0) {
            buf[n++] = Call(
                c.clearinghouse,
                abi.encodeCall(ch.registerMarket, (m.asset, m.strikeTick, m.enabled)),
                string.concat(
                    "clearinghouse.registerMarket(",
                    m.ticker,
                    ", strikeTick ",
                    vm.toString(m.strikeTick),
                    m.enabled ? ", enabled" : ", disabled",
                    "): LISTING lane, 1 h"
                )
            );
            // The freshly registered market carries the contract defaults, so compare against THOSE, not against
            // `cur` (which is still the empty tuple). Anything the registry asks for that the defaults do not give
            // is a second call, in its own lane.
            (uint16 defFee, uint32 defPpm) = ch.defaultMarketFees();
            n = _feeCall(in_, m, buf, n, defFee, defPpm, ppm);
            if (ch.defaultOracle() != c.settlementOracle) {
                buf[n++] = Call(
                    c.clearinghouse,
                    abi.encodeCall(ch.setMarketOracle, (m.asset, c.settlementOracle)),
                    string.concat(
                        "clearinghouse.setMarketOracle(", m.ticker, ", settlementOracle): CONFIG_ADMIN lane, 24 h"
                    )
                );
            }
            return n;
        }
        if (_cfgMatches(cur, in_, m, ppm)) return n;
        // --resync. The listing fields and the fee fields are SEPARATE calls in SEPARATE lanes, and queueing only
        // the first is the bug this replaces: `_cfgMatches` compares mintFeePpm and exerciseFeeBps too, so a rent or
        // exercise-fee drift on a disabled market (which the preflight above explicitly permits) used to be dropped
        // silently while the log claimed a `setMarketConfig(..., mintFeePpm N)` that no longer exists. The next run
        // then mismatched again, for ever.
        if (cur.enabled != m.enabled || cur.strikeTick != m.strikeTick) {
            buf[n++] = Call(
                c.clearinghouse,
                abi.encodeCall(ch.setMarketListing, (m.asset, m.enabled, m.strikeTick)),
                string.concat(
                    "clearinghouse.setMarketListing(",
                    m.ticker,
                    m.enabled ? ", enabled" : ", disabled",
                    ", strikeTick ",
                    vm.toString(m.strikeTick),
                    "): LISTING lane, 1 h"
                )
            );
        }
        return _feeCall(in_, m, buf, n, cur.exerciseFeeBps, cur.mintFeePpm, ppm);
    }

    /// @dev `setMarketFees(asset, exerciseFeeBps, mintFeePpm)` when either fee field differs from `haveFee`/`havePpm`.
    ///      Its own lane: MARKET_FEE_MANAGER waits 72 h, three times the LISTING lane's hour, which is why it can
    ///      never be folded back into the listing call.
    function _feeCall(
        Inputs memory in_,
        MarketIn memory m,
        Call[] memory buf,
        uint256 n,
        uint16 haveFee,
        uint32 havePpm,
        uint32 wantPpm
    ) internal pure returns (uint256) {
        if (haveFee == in_.exerciseFeeBps && havePpm == wantPpm) return n;
        buf[n++] = Call(
            in_.c.clearinghouse,
            abi.encodeCall(Clearinghouse.setMarketFees, (m.asset, in_.exerciseFeeBps, wantPpm)),
            string.concat(
                "clearinghouse.setMarketFees(",
                m.ticker,
                ", exerciseFeeBps ",
                vm.toString(in_.exerciseFeeBps),
                ", mintFeePpm ",
                vm.toString(uint256(wantPpm)),
                "): MARKET_FEE_MANAGER lane, 72 h"
            )
        );
        return n;
    }

    /// @dev Whether the last call planned is the registration itself, which is what `runWith` counts.
    function _isRegisterCall(Call[] memory buf, uint256 n) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (buf[i].data.length < 4) continue;
            // casting to 'bytes4' keeps the leading four bytes on purpose: they are the call's selector
            // forge-lint: disable-next-line(unsafe-typecast)
            if (bytes4(buf[i].data) == Clearinghouse.registerMarket.selector) return true;
        }
        return false;
    }

    function _sameList(address[] memory a, address[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// @dev After the calls (the simulation under `forge script`; VerifyV2 is the gate against the chain).
    function _postCheck(Inputs memory in_, MarketIn memory m) internal view {
        (Call[] memory left,) = plan(in_, m);
        require(left.length == 0, string.concat(m.ticker, ": post-check: config still differs after the admin calls"));
        (bool ok, uint256 price,) = SettlementOracle(in_.c.settlementOracle).trySpot(m.asset);
        console2.log(
            string.concat(
                "  post-check: ",
                m.ticker,
                " registered and configured; oracle trySpot ",
                ok ? "ok " : "not ok (a quiet feed older than spotMaxAge; informational) ",
                vm.toString(price)
            )
        );
    }
}
