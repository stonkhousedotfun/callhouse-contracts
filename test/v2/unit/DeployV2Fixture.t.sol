// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployV8} from "../../../script/v2/DeployV8.s.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {V4PoolKey} from "../../../src/v2/periphery/BuybackDeps.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockRoundFeed} from "../../../src/v2/mocks/MockRoundFeed.sol";
import {MockUniV3Pool} from "../../../src/v2/mocks/MockUniV3Pool.sol";
import {MockPayoutV3Factory} from "../../../src/v2/mocks/MockPayoutV3Factory.sol";
import {MockPayoutSwapRouter} from "../../../src/v2/mocks/MockPayoutSwapRouter.sol";
import {MockVerifierProxy} from "../../../src/v2/mocks/MockVerifierProxy.sol";
import {MockBuybackV3Pool} from "../mocks/MockBuybackV3Pool.sol";
import {MockPonsLaunchHook} from "../mocks/MockPonsLaunchHook.sol";
import {MockV4PoolManager} from "../mocks/MockV4PoolManager.sol";
import {MockV4StateView} from "../mocks/MockV4StateView.sol";
import {MockWeth9} from "../mocks/MockWeth9.sol";

/// @notice A 2-of-3 Safe double: canonical singleton in slot 0, three owners, no module, no guard.
/// @dev T-426. THE PREVIOUS VERSION OF THIS DOUBLE ANSWERED `isSafe()` AND NOTHING ELSE, and the fixture's happy
///      path passed because `DeployV8` asked only `code.length != 0`. That made this double the reason the gap was
///      invisible: every deploy test proved that a contract with code can be handed ADMIN, which is exactly the
///      property the row found to be wrong. `DeployV8._assertAdminSafeIsARealSafe` now probes the Safe's own
///      identity and topology before the renounce, so the double has to MODEL a Safe rather than merely have code.
///
///      WHAT IT MODELS AND WHY EACH PART IS HERE, mirrored from the probe rather than guessed:
///        slot 0                 -- the singleton. A Safe proxy holds its singleton there; an inert contract holds
///                                  zero, which is how the probe tells the two apart.
///        getThreshold/getOwners -- 2-of-3, the v8 design. A 1-of-1 double would be refused, correctly.
///        getModulesPaginated    -- an empty page. A module executes with no owner signatures.
///        guard / fallback slots -- left at zero, which the probe accepts as "none". This double never writes them,
///                                  so that pass is a real answer about this contract and not an accident of layout.
///      `isSafe()` IS DELIBERATELY GONE. It is the forbidden fix: a public forwarder answers it too.
contract MockSafe {
    /// @dev MIRRORED from `script/v2/DeployV8.s.sol` (`SAFE_L2_141`), which mirrors `script/Verify.s.sol:79`.
    address internal constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    /// @dev Slot 0 is the singleton and is written by {_setSingleton}, so nothing may be declared before this
    ///      line: the first state variable of this contract occupies slot 1 onwards only because slot 0 is
    ///      deliberately left to the Safe layout.
    uint256 private slot0Reserved;

    uint256 internal threshold = 2;
    address[] internal owners = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    address[] internal modules;

    constructor() {
        _setSingleton(SAFE_L2_141);
    }

    /// @dev `sstore` rather than a state variable, because what is being modelled is the SLOT, not a field: a Safe
    ///      proxy holds its singleton at slot 0 and the probe reads it with `vm.load`. Writing it explicitly also
    ///      means adding a field above cannot silently move it.
    function _setSingleton(address singleton) internal {
        assembly {
            sstore(0, singleton)
        }
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getModulesPaginated(address start, uint256) external view returns (address[] memory, address) {
        return (modules, start);
    }
}

/// @notice A Safe double whose topology is WRONG in exactly one way, for the refusal tests.
/// @dev One double with three knobs rather than three doubles: each test states the single property it breaks, so
///      a reader can see that the probe's branches are tested one at a time and not by a double that is broken in
///      several ways at once. The knobs are deliberately NOT on {MockSafe} -- the happy-path double should have no
///      way to be weakened by a later edit.
contract MockTweakableSafe is MockSafe {
    function setThreshold(uint256 t) external {
        threshold = t;
    }

    function setOwners(uint256 n) external {
        delete owners;
        for (uint256 i; i < n; ++i) {
            owners.push(address(uint160(0xA11CE + i)));
        }
    }

    function enableModule(address module) external {
        modules.push(module);
    }

    function setSingleton(address singleton) external {
        _setSingleton(singleton);
    }
}

/// @notice A contract with code and a plausible-sounding Safe answer, and nothing else. T-426 forbidden fix (a).
/// @dev It exists so a test can prove the refusal is about Safe IDENTITY and not about having code: this double
///      would pass any `code.length != 0` or `isSafe()` check, and `DeployV8` must still refuse to renounce to it.
contract MockNotASafe {
    function isSafe() external pure returns (bool) {
        return true;
    }
}

/// @notice A public forwarder: it answers every Safe read by forwarding to a real Safe, and it lets ANYONE execute.
/// @dev T-426 F-05-01 names the forwarder explicitly. `getThreshold()`, `getOwners()` and `getModulesPaginated()`
///      all answer correctly here -- they are the real Safe's answers -- so a probe built only from those three
///      reads would pass it. What it cannot fake is its own singleton slot, which holds nothing, because it is not
///      a Safe proxy. That is why the probe reads slot 0 first and why that read is not optional.
contract MockSafeForwarder {
    address internal immutable REAL;

    constructor(address real) {
        REAL = real;
    }

    function getThreshold() external view returns (uint256) {
        return MockSafe(REAL).getThreshold();
    }

    function getOwners() external view returns (address[] memory) {
        return MockSafe(REAL).getOwners();
    }

    function getModulesPaginated(address start, uint256 pageSize) external view returns (address[] memory, address) {
        return MockSafe(REAL).getModulesPaginated(start, pageSize);
    }

    /// @dev The part that makes it a forwarder and not a Safe: no signatures, no owners, no threshold.
    function execute(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, "forwarded call reverted");
        return ret;
    }
}

/// @notice A stand-in for a manifest target this deploy does not create.
/// @dev `roles.v8.json` `.targets` names twenty-one contracts. `DeployV8` deploys sixteen of them and expects the
///      other six by address, because they are deployed by their own tasks -- the list is mirrored from
///      `DeployV8._externallySupplied` (script/v2/DeployV8.s.sol:1306-1309), not re-derived here. A run that is not
///      given one SKIPS it and says so, and `VerifyV8`'s manifest walk then FAILS on every selector that stayed
///      unmapped. That is the designed behaviour and it is why the fixture has to supply them.
///
///      CODE IS NOT ENOUGH, and the first version of this double got that wrong. `VerifyV8` reads two things off a
///      supplied target, both as probing staticcalls so an unconverted target is a named FAIL rather than a revert:
///        `authority()` -- must answer, and must be the AccessManager (script/v2/VerifyV8.s.sol:928-938)
///        `treasury()`  -- for the money lane only, and must be V2_TREASURY_SAFE (:1289-1307)
///      A bare contract passes neither. Those are the two properties the real HouseVault, HouseVaultFactory, Hedger,
///      RewardsDistributorLender, EarnVault and StockVenueAdapter carry, so a double that carries them is modelling
///      the target rather than evading the check.
///
///      WHY NOT THE REAL CONTRACTS. All six exist in `src/v2` and deploying them here was the first thing I tried.
///      They cannot be built before the run: each takes the core addresses -- the AccessManager above all -- and the
///      AccessManager does not exist until `runWith` creates it, while `existing` has to be complete before it is
///      called. That ordering is not an accident of the fixture, it is the real sequence: these six are deployed by
///      their own tasks AFTER the core and pointed at the AccessManager then. {_pointExternalTargets} models exactly
///      that second step and nothing more.
contract MockExternalTarget {
    /// @dev T-426 F-05-03. WHICH of the six this double is standing in for. Before this row one double answered
    ///      for all six, which is precisely the property the finding is about: the script was given six raw
    ///      addresses and asserted only that they had code, so nothing -- in the script or in this fixture --
    ///      could tell the EarnVault's address from the Hedger's. `DeployV8._probe` now asks each supplied target
    ///      for getters its own source declares, so the double has to answer for ONE name and refuse the rest.
    enum Kind {
        HouseVault,
        HouseVaultFactory,
        Hedger,
        EarnVault,
        StockVenueAdapter,
        RewardsDistributorLender
    }

    Kind public immutable kind;

    /// @dev The AccessManager this target answers to. `VerifyV8` probes `authority()` by staticcall rather than a
    ///      typed call, so the name and the zero default both matter: unset reads as "still on v7 AccessControl".
    address public authority;
    /// @dev Only read for the money-lane targets (RewardsDistributorLender and Hedger, of these six). Left zero on
    ///      the others because nothing reads it there, and a zero that is never read is honest about its scope.
    ///      It is NOT gated by {kind}: the money-lane walk reads it on two of the six, so gating it would make
    ///      this double refuse a call the real contracts answer.
    address public treasury;

    /// @dev T-OP-171 (T-OP-166 F1). The selectors this double REFUSES A STRANGER on, exactly as the real `Managed`
    ///      contract does (`V2Errors.NotAuthorized`). VerifyV8's stranger probe has a positive control -- every
    ///      `roles.v8.json` selector of a target must refuse a stranger, or the target is not the contract the
    ///      manifest names and the group FAILS -- and before this field the six doubles refused nobody, so the
    ///      suite's "clean" baseline was a set that enforced nothing. {_pointExternalTargets} gates each double
    ///      with its own manifest rows, read from `roles.v8.json` through the verifier's resolvers, never typed.
    bytes4[] internal gated;

    /// @dev T-OP-171. The HouseVault identity VerifyV8's per-ticker group reads (`underlying()`, `clearinghouse()`,
    ///      `orderBook()`, `splitter()`), settable so a test can stand a double in for ONE ticker's vault -- or
    ///      deliberately for the wrong one.
    address internal underlyingOf;
    address internal clearinghouseOf;
    address internal orderBookOf;
    address internal splitterOf;

    constructor(Kind kind_) {
        kind = kind_;
    }

    function point(address authority_, address treasury_) external {
        authority = authority_;
        treasury = treasury_;
    }

    /// @notice The manifest selectors this double refuses a stranger on.
    function gate(bytes4[] calldata sels) external {
        delete gated;
        for (uint256 i; i < sels.length; ++i) {
            gated.push(sels[i]);
        }
    }

    /// @notice The vault identity a HouseVault double answers with.
    function setVaultIdentity(address underlying_, address clearinghouse_, address orderBook_, address splitter_)
        external
        asKind(Kind.HouseVault)
    {
        underlyingOf = underlying_;
        clearinghouseOf = clearinghouse_;
        orderBookOf = orderBook_;
        splitterOf = splitter_;
    }

    /// @dev A gated selector refuses the way `Managed._checkCanCall` refuses an unauthorised caller; anything else
    ///      not declared above is accepted with no return, which the stranger probe reads as "not gated".
    fallback() external {
        // casting to 'bytes4' keeps the leading four bytes on purpose: they are the call's selector
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 sel = bytes4(msg.data);
        for (uint256 i; i < gated.length; ++i) {
            if (gated[i] == sel) revert V2Errors.NotAuthorized();
        }
    }

    /// @dev A double standing in for one name must not answer another name's interface, or the probe it exists to
    ///      exercise would pass on the wrong contract.
    modifier asKind(Kind k) {
        require(kind == k, "MockExternalTarget: wrong kind for this getter");
        _;
    }

    // The signatures are mirrored from the real sources, named in `DeployV8._assertSuppliedTargetsAreWhatTheir-
    // NameClaims`. The VALUES are not modelled -- the probe asserts that the contract answers, not what it says.
    function underlying() external view asKind(Kind.HouseVault) returns (address) {
        return underlyingOf;
    }

    function clearinghouse() external view asKind(Kind.HouseVault) returns (address) {
        return clearinghouseOf;
    }

    function orderBook() external view asKind(Kind.HouseVault) returns (address) {
        return orderBookOf;
    }

    function splitter() external view asKind(Kind.HouseVault) returns (address) {
        return splitterOf;
    }

    function vaults() external view asKind(Kind.HouseVaultFactory) returns (address[] memory) {
        return new address[](0);
    }

    function notional() external view asKind(Kind.Hedger) returns (uint256, uint256) {
        return (0, 0);
    }

    function loan() external view asKind(Kind.Hedger) returns (address) {
        return address(0);
    }

    function queue() external view asKind(Kind.EarnVault) returns (uint256, uint256) {
        return (0, 0);
    }

    function adapter() external view asKind(Kind.EarnVault) returns (address) {
        return address(0);
    }

    function venue() external view asKind(Kind.StockVenueAdapter) returns (address) {
        return address(0);
    }

    function enabled() external view asKind(Kind.StockVenueAdapter) returns (bool) {
        return false;
    }

    function usdg() external view asKind(Kind.RewardsDistributorLender) returns (address) {
        return address(0);
    }
}

/// @notice The world the three v2 deploy scripts run against in their unit tests: USDG and two Stock Tokens named like
///         the registry's (symbols NVDA and TSLA, which the preflights compare with the ticker), Chainlink-shaped round
///         feeds with the chain's descriptions, a USDG/NVDA Uniswap v3 pool known to a factory, a SwapRouter02 stand-in
///         on that factory, a Data Streams VerifierProxy, and -- from INTERFACE_VERSION 8 -- the flywheel's venue: a
///         Uniswap v4 PoolManager with its StateView lens, WETH, a USDG/WETH v3 pool and one ETH/STONKHOUSE v4 pool
///         behind a launch hook. TSLA has no pool (Chainlink only), as the fork rehearsal registers it.
/// @dev Inputs are built explicitly and the scripts are driven through their `runWith` / `check` entries: `vm.setEnv`
///      writes the process environment every test thread shares (test/unit/DeploySoloPreflight.t.sol explains), so the
///      one env-driven test of these scripts (DeployV2Env.t.sol) uses only `V2_*` names, which nothing else sets.
///
///      ONE SIGNER. v7 deployed from `deployer` and wired from `admin`, because every constructor granted
///      DEFAULT_ADMIN_ROLE to the admin. v8 has a single signer: the deployer is the AccessManager's initial ADMIN,
///      grants itself the working roles, wires, hands the roles to the Safes and the bot keys and renounces. After
///      {_deploy} the deployer holds nothing, which is exactly what the scripts assert.
abstract contract DeployV2Fixture is Test {
    uint256 internal constant START = 1_789_000_000;
    int256 internal constant NVDA_ANSWER = 220_00000000;
    int256 internal constant TSLA_ANSWER = 358_04000000;
    /// @dev 220.0012 USDG per share with USDG as token0 (SettlementOracleSources.t.sol).
    int24 internal constant TICK_220 = 222385;
    uint128 internal constant POOL_LIQUIDITY = 1e19;
    uint128 internal constant NVDA_FLOOR = 1.7e18;
    uint64 internal constant TICK_2_50 = 2_500_000;

    /// @dev The live v3 USDG/WETH pool's tick and in-range liquidity at the C3-602 fork block, and its 0.01 % tier.
    ///      Copied from test/v2/unit/V4BuybackExecutorBase.t.sol so the buyback venue the deploy pins is the same
    ///      venue the executor's own suites exercise.
    int24 internal constant V3_TICK = -197_537;
    uint128 internal constant V3_LIQUIDITY = 4_893_766_857_630_448_658;
    uint24 internal constant V3_FEE = 100;

    address internal adminSafe;
    address internal treasurySafe;
    address internal guardianKey = makeAddr("guardianKey");
    address internal pricerKey = makeAddr("pricerKey");
    address internal quoterKey = makeAddr("quoterKey");
    address internal crankerKey = makeAddr("crankerKey");
    address internal deployer = makeAddr("deployer");

    /// @dev Filled in by {_deploy}: the fee recipient IS the FeeSplitter the run creates, and no caller can know its
    ///      address before the run. Zero until then, which is what `DeployV8` reads as "whatever this run creates".
    address internal feeRecipient;

    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockStockToken internal tsla;
    MockRoundFeed internal nvdaFeed;
    MockRoundFeed internal tslaFeed;
    MockUniV3Pool internal pool;
    MockPayoutV3Factory internal factory;
    MockPayoutSwapRouter internal router;
    MockVerifierProxy internal verifier;

    MockV4PoolManager internal v4Manager;
    MockV4StateView internal v4Lens;
    MockPonsLaunchHook internal hook;
    MockWeth9 internal weth;
    MockBuybackV3Pool internal usdgWethPool;
    MockERC20 internal stonk;
    V4PoolKey internal tokenKey;

    /// @dev The six manifest targets `DeployV8` does not deploy, supplied through `Inputs.existing`. Named for the
    ///      `V2DeployBase.Contracts` fields they fill, so the mapping from fixture to input is one to one.
    address internal houseVault;
    address internal houseVaultFactory;
    address internal hedger;
    address internal rewardsDistributorLender;
    address internal earnVault;
    address internal stockVenueAdapter;

    DeployV8 internal deployScript;
    RegisterMarkets internal registerScript;
    VerifyV8 internal verifyScript;

    function setUp() public virtual {
        vm.warp(START);
        adminSafe = address(new MockSafe());
        treasurySafe = address(new MockSafe());
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockStockToken("NVIDIA Stock Token", "NVDA");
        tsla = new MockStockToken("Tesla Stock Token", "TSLA");
        nvdaFeed = _feed("RHNVDA / USD", NVDA_ANSWER);
        tslaFeed = _feed("Robinhood TSLA / USD", TSLA_ANSWER);
        pool = new MockUniV3Pool(address(usdg), address(nvda), 500);
        // casting to 'uint40' is safe because START - 2 days is a 2026 unix time
        // forge-lint: disable-next-line(unsafe-typecast)
        pool.pushState(uint40(START - 2 days), TICK_220, POOL_LIQUIDITY);
        factory = new MockPayoutV3Factory();
        factory.setPool(address(nvda), address(usdg), 500, address(pool));
        router = new MockPayoutSwapRouter(address(factory));
        verifier = new MockVerifierProxy();
        _flywheelVenue();
        _externalTargets();
        deployScript = new DeployV8();
        registerScript = new RegisterMarkets();
        verifyScript = new VerifyV8();
    }

    /// @dev One stand-in per externally deployed manifest target. Separate instances on purpose: a shared address
    ///      would make six targets indistinguishable in `VerifyV8`'s output and would hide a mapping that went to
    ///      the wrong one.
    function _externalTargets() internal {
        houseVault = address(new MockExternalTarget(MockExternalTarget.Kind.HouseVault));
        houseVaultFactory = address(new MockExternalTarget(MockExternalTarget.Kind.HouseVaultFactory));
        hedger = address(new MockExternalTarget(MockExternalTarget.Kind.Hedger));
        rewardsDistributorLender = address(new MockExternalTarget(MockExternalTarget.Kind.RewardsDistributorLender));
        earnVault = address(new MockExternalTarget(MockExternalTarget.Kind.EarnVault));
        stockVenueAdapter = address(new MockExternalTarget(MockExternalTarget.Kind.StockVenueAdapter));
    }

    /// @dev The flywheel's venue, shaped like the live one: WETH as token0 of a 0.01 % USDG/WETH v3 pool, and one
    ///      ETH/STONKHOUSE v4 pool whose launch hook is registered for that pool id with the token as `currency1`
    ///      and native ETH as its quote. `V4BuybackExecutor`'s constructor checks every one of those facts, so a
    ///      fixture that got any of them wrong would fail the deploy rather than a later assertion.
    function _flywheelVenue() internal {
        v4Manager = new MockV4PoolManager();
        v4Lens = new MockV4StateView(address(v4Manager));
        hook = new MockPonsLaunchHook(address(v4Manager));
        weth = new MockWeth9();
        stonk = new MockERC20("STONKHOUSE", "STONK", 18);
        // The live pool's order: WETH is token0 and USDG token1.
        usdgWethPool = new MockBuybackV3Pool(address(weth), address(usdg), V3_FEE);
        // forge-lint: disable-next-line(unsafe-typecast)
        usdgWethPool.pushState(uint40(START - 1 days), V3_TICK, V3_LIQUIDITY);
        tokenKey = V4PoolKey({
            currency0: address(0), currency1: address(stonk), fee: 0, tickSpacing: 200, hooks: address(hook)
        });
        hook.setLaunch(
            keccak256(abi.encode(tokenKey)),
            MockPonsLaunchHook.Launch({
                registered: true,
                memecoinIsCurrency0: false,
                memecoin: address(stonk),
                quoteToken: address(0),
                creatorTaxBps: 100,
                hookFeeBps: 100
            })
        );
        v4Manager.setPool(tokenKey, uint160(1 << 96), 0, 0, 0);
    }

    /// @dev Twelve hourly rounds, the last one an hour old.
    function _feed(string memory description, int256 answer) internal returns (MockRoundFeed f) {
        f = new MockRoundFeed(8, description);
        for (uint256 i; i < 12; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            f.push(answer - 11_000_000 + int256(i) * 1_000_000, START - (12 - i) * 1 hours);
        }
    }

    function _holidays() internal pure returns (uint32[] memory h) {
        h = new uint32[](2);
        h[0] = 20703; // Labor Day 2026-09-07
        h[1] = 20783; // Thanksgiving 2026-11-26
    }

    function _roles() internal view returns (V2DeployBase.Roles memory) {
        return V2DeployBase.Roles({
            adminSafe: adminSafe,
            treasurySafe: treasurySafe,
            guardianKey: guardianKey,
            pricerKey: pricerKey,
            quoterKey: quoterKey,
            crankerKey: crankerKey,
            feeRecipient: feeRecipient,
            deployer: deployer
        });
    }

    function _external() internal view returns (V2DeployBase.External memory) {
        return V2DeployBase.External({
            usdg: address(usdg),
            swapRouter02: address(router),
            univ3Factory: address(factory),
            dataStreamsVerifier: address(verifier),
            v4PoolManager: address(v4Manager),
            v4StateView: address(v4Lens)
        });
    }

    /// @dev The registry's v2.fees and the launch values of everything else.
    ///      INTERFACE_VERSION 8 (V8-DESIGN.md §4): `premiumFeeBps` is 500 and `resaleFeeBps` 0 -- 5% of the premium
    ///      on first sale, nothing on a true resale. v7 refused exactly that shape (`premiumFeeBps <= resaleFeeBps`,
    ///      the c05 resale dodge); the owner's decision was to leave the dodge open and charge no rent for it, so
    ///      `V2DeployBase._checkFees` no longer carries that require and this is the launch table.
    function _params() internal pure returns (V2DeployBase.Params memory p) {
        p.fees = V2Types.FeeParams({
            premiumFeeBps: 500, resaleFeeBps: 0, takerFeeFlat: 100_000, takerFeeCapBps: 1000, makerRebateBps: 5000
        });
        p.exerciseFeeBps = 25;
        p.payoutSlippageBps = 30;
        p.bountySnapshot = 50_000;
        p.bountyFinalize = 50_000;
        p.bountySettle = 50_000;
        p.bountyRedeem = 20_000;
        p.bountyRoll = 50_000;
        p.bountyCancelStale = 20_000;
        p.dailyCap = 100e6;
        p.vaultLimits = MakerVault.Limits({
            maxSeriesUnits: 10_000,
            maxTotalNotional: 250_000e6,
            askToleranceBps: 100,
            maxBidBpsOfSpot: 1000,
            maxOrderLifetime: 0,
            maxDailyOutflow: 2_500e6
        });
        p.baseUri = "https://app.stonkhouse.fun/api/token/";
    }

    function _flywheel() internal view returns (V2DeployBase.Flywheel memory f) {
        f.burnBps = 5000; // 50/50 burn and treasury (V8-DESIGN.md §0 row 5)
        f.conversionSlippageBps = 30;
        f.weth = address(weth);
        f.v3UsdgWethPool = address(usdgWethPool);
        f.poolKey = tokenKey;
        f.maxTotalFeeBps = 250;
        f.maxSlippageBps = 51;
        f.twapWindow = 300;
        f.minLiquidity = 1e18;
    }

    function _deployInputs() internal view returns (DeployV8.Inputs memory in_) {
        in_.roles = _roles();
        in_.ext = _external();
        in_.params = _params();
        in_.flywheel = _flywheel();
        in_.holidays = _holidays();
        in_.existing = _externallyDeployed();
        in_.expectChainId = block.chainid;
    }

    /// @dev The six targets `roles.v8.json` names and `DeployV8` does not create. Every other field of `Contracts`
    ///      stays zero, which is what tells the script to deploy the sixteen it owns: `runWith` starts from
    ///      `d = in_.existing` (script/v2/DeployV8.s.sol:466) and creates only what is missing.
    ///
    ///      WITHOUT THIS THE LAUNCH GATE'S OWN SUITE IS RED, and it is worth saying why rather than leaving the
    ///      next reader to find it. Leave any of these at zero and `_mapTarget` skips that target with a warning,
    ///      its selectors stay unmapped, and `VerifyV8` fails on each of them -- correctly. The failure is real;
    ///      the fixture was the thing that was wrong. DO NOT answer a red run here by relaxing an expected-clean
    ///      assertion or by narrowing the manifest walk: that turns the launch gate into a check that passes
    ///      because it can no longer see what it is for.
    function _externallyDeployed() internal view returns (V2DeployBase.Contracts memory c) {
        c.houseVault = houseVault;
        c.houseVaultFactory = houseVaultFactory;
        c.hedger = hedger;
        c.rewardsDistributorLender = rewardsDistributorLender;
        c.earnVault = earnVault;
        c.stockVenueAdapter = stockVenueAdapter;
    }

    function _signer(address who) internal pure returns (V2DeployBase.Signer memory) {
        return V2DeployBase.Signer({pk: 0, addr: who});
    }

    /// @dev The whole set, deployed and handed over by `deployer`. The fee recipient is recorded afterwards because
    ///      it is the FeeSplitter this very run created.
    function _deploy() internal returns (V2DeployBase.Contracts memory d) {
        (d,) = deployScript.runWith(_deployInputs(), _signer(deployer));
        feeRecipient = d.feeSplitter;
        _pointExternalTargets(d.accessManager);
    }

    /// @dev The second step of the real sequence: the six externally deployed targets are pointed at the
    ///      AccessManager the run just created. It cannot happen in {setUp} because that address does not exist
    ///      until the run returns.
    ///
    ///      TREASURY IS SET ON EXACTLY TWO of them, and the list is read off the check rather than guessed:
    ///      `VerifyV8`'s money lane is feeSplitter, keeperRewards, makerVault, rewardsDistributor,
    ///      rewardsDistributorLender and hedger -- the first four this run deploys, so only the last two are ours.
    function _pointExternalTargets(address accessManager) internal {
        MockExternalTarget(houseVault).point(accessManager, address(0));
        MockExternalTarget(houseVaultFactory).point(accessManager, address(0));
        MockExternalTarget(hedger).point(accessManager, treasurySafe);
        MockExternalTarget(rewardsDistributorLender).point(accessManager, treasurySafe);
        MockExternalTarget(earnVault).point(accessManager, address(0));
        MockExternalTarget(stockVenueAdapter).point(accessManager, address(0));
        // T-OP-171. Each double refuses a stranger on ITS manifest rows, read from roles.v8.json through the
        // verifier's own resolvers, so the stranger probe's positive control passes for the right reason.
        _gate(houseVault, "HouseVault");
        _gate(houseVaultFactory, "HouseVaultFactory");
        _gate(hedger, "Hedger");
        _gate(rewardsDistributorLender, "RewardsDistributorLender");
        _gate(earnVault, "EarnVault");
        _gate(stockVenueAdapter, "StockVenueAdapter");
    }

    /// @dev The manifest selectors of `targetName`, as a double's gated set.
    function _gate(address target, string memory targetName) internal {
        string memory json = verifyScript.rolesJson();
        string[] memory sigs = verifyScript.targetSigs(json, targetName);
        bytes4[] memory sels = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; ++i) {
            sels[i] = verifyScript.selectorOf(sigs[i]);
        }
        MockExternalTarget(target).gate(sels);
    }

    function _nvdaMarket() internal view returns (V2DeployBase.MarketIn memory) {
        return V2DeployBase.MarketIn({
            ticker: "NVDA",
            asset: address(nvda),
            feed: address(nvdaFeed),
            pool: address(pool),
            minLiquidity: NVDA_FLOOR,
            poolFee: 500,
            strikeTick: TICK_2_50,
            maxDeviationBps: 150,
            uncorroboratedDelay: 21_600,
            spotMaxAge: 3600,
            enabled: true,
            // No payout route in this fixture: venue none, so the v4 pin below never applies.
            payoutVenue: 0,
            payoutFee: 0,
            payoutTickSpacing: 0,
            payoutPoolId: bytes32(0)
        });
    }

    function _tslaMarket() internal view returns (V2DeployBase.MarketIn memory) {
        return V2DeployBase.MarketIn({
            ticker: "TSLA",
            asset: address(tsla),
            feed: address(tslaFeed),
            pool: address(0),
            minLiquidity: 0,
            poolFee: 0,
            strikeTick: TICK_2_50,
            maxDeviationBps: 150,
            uncorroboratedDelay: 21_600,
            spotMaxAge: 3600,
            enabled: true,
            // No payout route in this fixture: venue none, so the v4 pin below never applies.
            payoutVenue: 0,
            payoutFee: 0,
            payoutTickSpacing: 0,
            payoutPoolId: bytes32(0)
        });
    }

    function _registerInputs(V2DeployBase.Contracts memory d)
        internal
        view
        returns (RegisterMarkets.Inputs memory in_)
    {
        in_.admin = adminSafe;
        in_.usdg = address(usdg);
        in_.exerciseFeeBps = 25;
        in_.maxFeedAge = 4 days;
        in_.c = d;
        in_.markets = new V2DeployBase.MarketIn[](2);
        in_.markets[0] = _nvdaMarket();
        in_.markets[1] = _tslaMarket();
        in_.expectChainId = block.chainid;
        in_.mintFeePpm = _mintFeePpm();
    }

    /// @dev INTERFACE_VERSION 8 (V8-DESIGN.md §4.3): collateral rent launches at 0 on EVERY market and is turned on
    ///      later through `Clearinghouse.setMarketFees` in the 72 h MARKET_FEE_MANAGER lane. These are therefore both
    ///      0, and a suite that wants a non-zero rate has to ask for it and carry the opt-in
    ///      ({V2DeployBase.rentAllowed}); test/v2/unit/ZeroRentLocality.t.sol is where that is proved.
    function _mintFeePpm() internal pure returns (uint32[] memory ppm) {
        ppm = new uint32[](2);
        ppm[0] = 0; // NVDA
        ppm[1] = 0; // TSLA
    }

    function _verifyInputs(V2DeployBase.Contracts memory d, bool fresh)
        internal
        view
        returns (VerifyV8.Inputs memory in_)
    {
        in_.c = d;
        in_.roles = _roles();
        in_.deployer = deployer;
        in_.ext = _external();
        in_.params = _params();
        in_.holidays = _holidays();
        in_.markets = new V2DeployBase.MarketIn[](2);
        in_.markets[0] = _nvdaMarket();
        in_.markets[1] = _tslaMarket();
        in_.mintFeePpm = _mintFeePpm();
        // T-OP-171. One slot per ticker; zero = the registry's markets[].v2.houseVault is null (NOT CHECKED by
        // ticker). Tests that stand a double in for a ticker's vault set the slot.
        in_.marketVaults = new address[](2);
        in_.unregistered = new address[](0);
        in_.expectFresh = fresh;
        in_.expectChainId = block.chainid;
        // T-426. SET, NOT LEFT AT ZERO. `VerifyV8._safeOwnership` refuses when either minimum is 0 -- correctly,
        // because `threshold >= 0` and `owners >= 0` are tautologies -- and this struct is built field by field, so
        // before this line every verify run in the suite stopped at that refusal and NEVER evaluated the threshold
        // or owner-count assertions at all. The values mirror `VerifyV8.inputsFromEnv` (V2_EXPECT_SAFE_THRESHOLD
        // default 2, V2_EXPECT_SAFE_OWNERS default 3), which is the v8 2-of-3 design, rather than being chosen to
        // fit the double: `MockSafe` was made to satisfy them, not the other way round.
        in_.safeMinThreshold = 2;
        in_.safeMinOwners = 3;
    }
}
