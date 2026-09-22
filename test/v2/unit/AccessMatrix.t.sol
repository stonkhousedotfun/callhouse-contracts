// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {MakerRegistry} from "../../../src/v2/mm/MakerRegistry.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {IFeeDiscount} from "../../../src/v2/interfaces/IFeeDiscount.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {RewardsDistributor} from "../../../src/v2/mm/RewardsDistributor.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {PayoutRouter} from "../../../src/v2/periphery/PayoutRouter.sol";
import {FeeSplitter} from "../../../src/v2/periphery/FeeSplitter.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";
import {MockVerifierProxy} from "../../../src/v2/mocks/MockVerifierProxy.sol";
import {V4PoolKey} from "../../../src/v2/periphery/BuybackDeps.sol";
import {V4BuybackConfig, V4BuybackExecutor} from "../../../src/v2/periphery/V4BuybackExecutor.sol";
import {MockBuybackV3Pool} from "../mocks/MockBuybackV3Pool.sol";
import {MockPonsLaunchHook} from "../mocks/MockPonsLaunchHook.sol";
import {MockV4PoolManager} from "../mocks/MockV4PoolManager.sol";
import {MockV4StateView} from "../mocks/MockV4StateView.sol";
import {MockWeth9} from "../mocks/MockWeth9.sol";
import {MockV3Factory, MockV3Router, MockV4} from "./PayoutRouter.t.sol";
import {HouseVault} from "../../../src/v2/periphery/house/HouseVault.sol";
import {HouseVaultFactory} from "../../../src/v2/periphery/house/HouseVaultFactory.sol";
import {Hedger} from "../../../src/v2/periphery/Hedger.sol";
import {MockMorphoBlue} from "../../../src/v2/mocks/MockMorphoBlue.sol";
import {EarnVault} from "../../../src/v2/periphery/earn/EarnVault.sol";
import {StockVenueAdapter} from "../../../src/v2/periphery/earn/adapters/StockVenueAdapter.sol";
import {Mock4626Vault} from "../../../src/v2/mocks/Mock4626Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExpiryCalendar} from "../../../src/v2/interfaces/IExpiryCalendar.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";

/// @notice C8-01 / C8-09b load-bearing harness: a `restricted` selector with no row in `roles.v8.json` is a
///         FAILURE, not a silent ADMIN mapping. The unmapped probe MUST reach `restricted`, so it builds calldata
///         with {_dummyCalldata} rather than `abi.encodePacked(selector)` (Solidity decodes args before modifiers).
contract AccessMatrixTest is V8AccessTest {
    using stdJson for string;

    // T-220: THE PINNED COUNTS ARE GONE, DELIBERATELY, AND NOTHING SHOULD PUT THEM BACK.
    //
    // There used to be `EXPECTED_TARGETS = 21` and `EXPECTED_MAPPED = 114` here, each a literal that had been
    // counted off `script/v2/roles.v8.json` and then written down beside it. An assertion that compares the JSON
    // with a number copied FROM that JSON agrees with itself: ask what it would do if a manifest row went
    // missing, and the answer is "pass, and the literal gets edited to match on the next commit". That is the
    // defect this row removes, not a style preference -- the owner ruling for T-220 says to re-derive every
    // pinned count from the JSON rather than editing literals.
    //
    // WHAT REPLACES THEM IS A CROSS-CHECK, NOT A SMALLER LITERAL. The manifest is now compared against the LIVE
    // FIXTURE: every target named in `roles.v8.json` must resolve to a contract this harness actually deployed,
    // and every selector it maps must really refuse a stranger. Those two facts come from different places --
    // one from the file, one from the chain -- so they cannot agree with each other by construction.
    //
    // A NOTE FOR ANYONE WHO CONSUMED THE OLD CONSTANTS: they no longer exist. Derive the counts with
    // `vm.parseJsonKeys(json, ".targets")` and a sum over `.targets.<name>` rather than re-pinning them.

    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");
    ExpiryCalendar internal calendar;
    MakerRegistry internal registry;
    Clearinghouse internal house;
    OrderBook internal book;
    PayoutRouter internal payout;
    FeeSplitter internal splitter;
    MockERC20 internal usdg;
    AutoRoller internal roller;
    MakerVault internal vault;
    RewardsDistributor internal rewards;
    SettlementOracle internal settlement;
    ChainlinkFeedSource internal clSource;
    UniV3TwapSource internal twapSource;
    DataStreamsSource internal streamsSource;
    MockVerifierProxy internal verifier;
    KeeperRewards internal keepers;
    V4BuybackExecutor internal buyback;
    HouseVaultFactory internal houseFactory;
    HouseVault internal houseVault;
    Hedger internal hedger;
    MockERC20 internal nvda;
    // T-220: the three manifest targets this harness never deployed, which is why the walk saw 18 of 21.
    EarnVault internal earn;
    StockVenueAdapter internal venueAdapter;
    Mock4626Vault internal venue;
    /// @dev P8-05's SECOND RewardsDistributor instance. Same contract and same artifact as {rewards}, a different
    ///      ADDRESS and reward token, and three byte-identical selectors -- so it needs its own deployment here or
    ///      the walk covers one of the two and looks complete. See {_artifactOf}.
    RewardsDistributor internal rewardsLender;

    function setUp() public {
        uint32[] memory none = new uint32[](0);
        calendar = _newCalendar(none, holder);
        registry = _newRegistry(holder);
        usdg = new MockERC20("USDG", "USDG", 6);
        house = _newClearinghouse(address(usdg), address(calendar), holder, "", holder);
        book = new OrderBook(
            house,
            address(manager),
            holder,
            V2Types.FeeParams({
                premiumFeeBps: 500, resaleFeeBps: 0, takerFeeFlat: 100_000, takerFeeCapBps: 1000, makerRebateBps: 5000
            })
        );
        _wire(address(book), "OrderBook", holder, 0);
        MockV3Factory fac = new MockV3Factory();
        MockV3Router v3 = new MockV3Router(address(fac), usdg);
        MockV4 v4 = new MockV4(usdg);
        payout = new PayoutRouter(address(manager), address(usdg), address(v3), address(v4), address(v4));
        _wire(address(payout), "PayoutRouter", holder, 0);
        splitter = new FeeSplitter(address(manager), address(usdg), holder, 5_000);
        _wire(address(splitter), "FeeSplitter", holder, 0);

        roller = _newRoller(IOrderBook(address(book)), holder, holder);
        vault = _newVault(IOrderBook(address(book)), holder, _vaultLimits(), holder, holder);
        rewards = _newDistributor(usdg, holder, holder);

        settlement = _newSettlementOracle(holder);
        clSource = _newChainlinkFeedSource(holder);
        twapSource = _newUniV3TwapSource(address(usdg), holder);
        verifier = new MockVerifierProxy();
        streamsSource = _newDataStreamsSource(address(verifier), holder);
        keepers = _newKeeperRewards(usdg, holder, holder);
        buyback = _deployBuyback();
        (houseFactory, houseVault, nvda) = _deployHouse();
        hedger = new Hedger(
            address(manager),
            address(usdg),
            payout.poolManager(),
            address(settlement),
            address(payout),
            address(new MockMorphoBlue()),
            makeAddr("hedgerTreasury"),
            // T-265: the trading-week authority is fixed at construction. This fixture's real ExpiryCalendar,
            // built at `calendar` above, is what the constructor probes.
            address(calendar)
        );
        _wire(address(hedger), "Hedger", holder, 0);

        // T-220. EarnVault has ELEVEN restricted selectors and roles.v8.json maps all eleven since T-219 added `place`.
        // Nothing could contradict the old comment that said "ten" because nothing walked the contract.
        earn = new EarnVault(
            IOrderBook(address(book)), address(manager), address(usdg), address(splitter), "Stonkhouse Earn", "eUSDG"
        );
        _wire(address(earn), "EarnVault", holder, 0);

        venue = new Mock4626Vault(IERC20(address(nvda)));
        venueAdapter = new StockVenueAdapter(address(manager), address(nvda), address(venue), address(earn));
        _wire(address(venueAdapter), "StockVenueAdapter", holder, 0);

        rewardsLender = _newDistributor(usdg, holder, holder);
    }

    function _vaultLimits() internal pure returns (MakerVault.Limits memory) {
        return MakerVault.Limits({
            maxSeriesUnits: 10_000,
            maxTotalNotional: 100_000e6,
            askToleranceBps: 100,
            maxBidBpsOfSpot: 1000,
            maxOrderLifetime: 0,
            maxDailyOutflow: 2_500e6
        });
    }

    function _houseLimits() internal pure returns (HouseVault.Limits memory) {
        return HouseVault.Limits({
            maxSeriesUnits: 10_000,
            maxTotalNotional: 100_000e6,
            askToleranceBps: 100,
            maxBidBpsOfSpot: 1000,
            maxOrderLifetime: 0,
            maxDailyOutflow: 2_500e6
        });
    }

    function _deployHouse() internal returns (HouseVaultFactory factory, HouseVault hv, MockERC20 stock) {
        stock = new MockERC20("NVDA Stock Token", "NVDAx", 18);
        factory = new HouseVaultFactory(
            IOrderBook(address(book)),
            address(manager),
            IExpiryCalendar(address(calendar)),
            ISettlementOracle(address(settlement)),
            address(splitter)
        );
        _wire(address(factory), "HouseVaultFactory", holder, 0);
        vm.prank(holder);
        address deployed = factory.createVault(address(stock), _houseLimits(), "Stonkhouse House NVDA", "hNVDA");
        hv = HouseVault(deployed);
        _wire(address(hv), "HouseVault", holder, 0);
    }

    /// @dev Minimal constructor-valid executor. Not wired: `roles.v8.json` maps ZERO restricted selectors.
    function _deployBuyback() internal returns (V4BuybackExecutor exec) {
        MockERC20 tok = new MockERC20("STONKHOUSE", "STONK", 18);
        MockWeth9 weth = new MockWeth9();
        MockV4PoolManager v4pm = new MockV4PoolManager();
        MockPonsLaunchHook hook = new MockPonsLaunchHook(address(v4pm));
        MockV4StateView lens = new MockV4StateView(address(v4pm));
        MockBuybackV3Pool v3pool = new MockBuybackV3Pool(address(weth), address(usdg), 100);
        v3pool.pushState(1_789_000_000, -197_537, 4_893_766_857_630_448_658);
        V4PoolKey memory key =
            V4PoolKey({currency0: address(0), currency1: address(tok), fee: 0, tickSpacing: 200, hooks: address(hook)});
        bytes32 poolId = keccak256(abi.encode(key));
        hook.setLaunch(
            poolId,
            MockPonsLaunchHook.Launch({
                registered: true,
                memecoinIsCurrency0: false,
                memecoin: address(tok),
                quoteToken: address(0),
                creatorTaxBps: 100,
                hookFeeBps: 100
            })
        );
        v4pm.setPool(key, uint160(1 << 96), 0, 0, 0);
        v4pm.setLiquidity(poolId, 29_277_002_188_455_995_497_142);
        exec = new V4BuybackExecutor(
            V4BuybackConfig({
                splitter: holder,
                usdg: address(usdg),
                weth: address(weth),
                v3Pool: address(v3pool),
                poolManager: address(v4pm),
                stateView: address(lens),
                key: key,
                maxTotalFeeBps: 250,
                maxSlippageBps: 51,
                twapWindow: 300,
                minLiquidity: 1e18
            })
        );
    }

    /// @dev T-220. This no longer compares the manifest with a literal copied out of the manifest. It compares the
    ///      manifest with the LIVE FIXTURE: every target named in `roles.v8.json` must resolve to a contract this
    ///      harness actually deployed. The two facts come from different places -- one from the file, one from the
    ///      chain -- so they cannot agree by construction, and a target added to the JSON that nobody deploys fails
    ///      HERE, by name, instead of quietly never being walked.
    /// @dev T-219 / T-253 / owner ruling G: OPS_ADMIN is key-rotation-only and maps NO target selector. Derived from
    ///      the manifest rather than pinned as a count, per T-220 above -- a literal counted off this same JSON
    ///      would agree with itself.
    ///
    ///      THIS USED TO ASSERT `seen == 1`, DELIBERATELY, AND T-253 IS THE ROW THAT EARNED THE FLIP. Ruling G names
    ///      six selectors to move: place, cancel, depositToClearinghouse, withdrawFromClearinghouse, sweepToVenue,
    ///      pullFromVenue. But `place` was ALREADY QUOTER at contracts 92638760 and the manifest's actual OPS_ADMIN
    ///      set contained `refreshApprovals()`, which the ruling never names -- so T-219 could only honestly pin ONE,
    ///      and its role was an owner decision that row did not have. T-253 moved that last selector to QUOTER,
    ///      MIRRORING `MakerVault.refreshApprovals` and `HouseVault.refreshApprovals`, which are both QUOTER in this
    ///      same manifest. The empty set is now the truth, which is the point at which V8Roles' and the manifest
    ///      note's "no target function is mapped to OPS_ADMIN" may be stated.
    ///
    ///      ZERO IS THE DANGEROUS ASSERTION, SO THIS TEST CARRIES ITS OWN POSITIVE CONTROL. `seen == 0` also passes
    ///      when the walk sees NOTHING: delete the `EarnVault` block, rename a target, or break the bracket accessor
    ///      and this goes green while reporting about a subject it never read. That is the defect class that has cost
    ///      this build the most -- a check that passes because it cannot see what it is checking. So the zero is only
    ///      believed after the walk has proved it REACHED `EarnVault.refreshApprovals()` and read a role off it.
    function test_opsAdminMapsNoTargetSelector() public view {
        string memory json = _rolesJson();
        string[] memory names = vm.parseJsonKeys(json, ".targets");
        uint256 walked;
        uint256 seen;
        string memory offenderName;
        string memory offenderSig;
        string memory refreshRole;
        bool reachedRefresh;
        for (uint256 i; i < names.length; ++i) {
            string[] memory sigs = vm.parseJsonKeys(json, string.concat(".targets.", names[i]));
            for (uint256 j; j < sigs.length; ++j) {
                // Bracket notation, not dot: a selector key contains "(", "," and ")", which the JSONPath dot
                // form cannot address -- it returns multiple values and `parseJsonString` refuses. Same accessor
                // shape as {V2DeployBase.roleNameOfSig}.
                string memory role = json.readString(string.concat(".targets.", names[i], '["', sigs[j], '"]'));
                ++walked;
                if (
                    keccak256(bytes(names[i])) == keccak256("EarnVault")
                        && keccak256(bytes(sigs[j])) == keccak256("refreshApprovals()")
                ) {
                    reachedRefresh = true;
                    refreshRole = role;
                }
                if (keccak256(bytes(role)) != keccak256("OPS_ADMIN")) continue;
                ++seen;
                if (bytes(offenderName).length == 0) {
                    offenderName = names[i];
                    offenderSig = sigs[j];
                }
            }
        }
        assertGt(walked, 0, "the manifest walk read no selector at all -- this test cannot see its subject");
        assertTrue(
            reachedRefresh, "the walk never reached EarnVault.refreshApprovals() -- a zero count here would be vacuous"
        );
        assertEq(
            refreshRole,
            "QUOTER",
            "EarnVault.refreshApprovals() must answer to QUOTER, mirroring MakerVault and HouseVault"
        );
        assertEq(
            seen,
            0,
            string.concat(
                "ruling G: OPS_ADMIN must map no target selector, but ", offenderName, ".", offenderSig, " still does"
            )
        );
    }

    /// @dev THE LIVE HALF OF THE SAME CLAIM, because the manifest walk and the wiring both read one file and would
    ///      agree with each other about a file that was simply wrong. This asks the deployed contract instead: an
    ///      account holding ONLY OPS_ADMIN is refused on the exact selector OPS_ADMIN used to hold, and the refusal
    ///      is `NotAuthorized` rather than some unrelated revert that would look the same from outside. The QUOTER
    ///      call afterwards is the positive control -- without it a vault that reverts for everyone would pass.
    function test_opsAdminCannotCallTheSelectorItUsedToHold() public {
        address opsOnly = makeAddr("opsAdminOnly");
        _grant(V8Roles.OPS_ADMIN, opsOnly, 0);

        vm.prank(opsOnly);
        (bool ok, bytes memory ret) = address(earn).call(abi.encodeCall(EarnVault.refreshApprovals, ()));
        assertFalse(ok, "OPS_ADMIN must no longer be able to call EarnVault.refreshApprovals()");
        assertTrue(_isNotAuthorized(ret), "OPS_ADMIN's refusal must be NotAuthorized, not an unrelated revert");

        vm.prank(holder);
        earn.refreshApprovals();
    }

    /// @dev The other half of ruling G, asserted positively so a silent revert to OPS_ADMIN cannot pass: the five
    ///      money-movers answer to QUOTER, and `place` -- already QUOTER before this row -- stays there.
    ///
    ///      `refreshApprovals()` IS THE SEVENTH, and it is added here as T-219 ADDENDUM step 3 asks -- the one step
    ///      of that addendum still undone. It is NOT an unasserted selector, and it is worth being exact about that
    ///      rather than overstating what this line buys. {test_opsAdminMapsNoTargetSelector} ALREADY pins it to
    ///      QUOTER: its walk must reach `EarnVault.refreshApprovals()` and read a role off it before its `seen == 0`
    ///      may be believed, and it asserts that role equals QUOTER. Measured, not assumed -- flipping the manifest
    ///      row to CONFIG_ADMIN turns BOTH tests red, so the pin is real today.
    ///
    ///      WHAT THE SEVENTH ENTRY IS ACTUALLY FOR, then. This list is where a reader looks for "which EarnVault
    ///      selectors answer to QUOTER", and naming six of seven makes it quietly wrong as documentation. And the
    ///      pin in the other test is INCIDENTAL to that test's purpose: the role read exists there to prove the walk
    ///      reached its subject, so a later simplification of that anti-vacuity control would remove the only
    ///      positive assertion on this selector without anything going red. Cheap redundancy, deliberately placed.
    function test_earnVaultMoneyMoversAreQuoter() public view {
        string memory json = _rolesJson();
        string[7] memory sigs = [
            "place(uint256,uint8,uint128,uint64,uint40)",
            "cancel(uint256[])",
            "depositToClearinghouse(address,uint256)",
            "withdrawFromClearinghouse(address,uint256)",
            "sweepToVenue(uint256)",
            "pullFromVenue(uint256)",
            "refreshApprovals()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            assertEq(
                json.readString(string.concat('.targets.EarnVault["', sigs[i], '"]')),
                "QUOTER",
                string.concat("EarnVault.", sigs[i], " must answer to QUOTER (owner ruling B and G)")
            );
        }
    }

    /// @dev T-OP-058 (BUG-02 F6). `HouseVault.setOracle(address)` is a NEW restricted selector on an EXISTING
    ///      target, which is the T-170 shape: the source compiles and the scope check passes with no manifest row,
    ///      and `VerifyV8` check group 4 then reads the selector as ADMIN-only in silence. The generic walk
    ///      ({test_restrictedSelectorMissingFromManifestFails}) catches the ABSENCE of the row; this pins the
    ///      ROLE, because a row under the wrong lane -- OPS_ADMIN at delay 0, the forbidden fix -- would pass the
    ///      walk. Both halves are read: the manifest string, and what the live fixture's manager actually holds
    ///      after {_wire} mapped it, so a manifest edit that never reached the manager is visible too.
    function test_houseVaultSetOracleIsConfigAdmin() public view {
        assertEq(
            _rolesJson().readString('.targets.HouseVault["setOracle(address)"]'),
            "CONFIG_ADMIN",
            "HouseVault.setOracle must answer to CONFIG_ADMIN (24 h, guardian-cancellable), never OPS_ADMIN"
        );
        assertEq(
            uint256(manager.getTargetFunctionRole(address(houseVault), HouseVault.setOracle.selector)),
            uint256(V8Roles.CONFIG_ADMIN),
            "the live fixture maps setOracle to CONFIG_ADMIN"
        );
    }

    /// @dev T-OP-159. OWNER ORDER 2026-09-22 05:55Z, verbatim: "i dont want these numbers to have a delay at all."
    ///      `HouseVault.setLimits` moved from TREASURY_ADMIN (delaysS 86400) to GUARDIAN (delaysS 0). This is the
    ///      T-OP-058 shape again, so it is pinned the same way: the MANIFEST STRING and what the LIVE FIXTURE's
    ///      manager holds after {_wire} mapped it, so a manifest edit that never reached the manager is visible, and
    ///      a manager state that drifted from the manifest is visible too.
    ///
    ///      THE BOUNDARY IS PINNED AS WELL. The owner asked for the LIMITS only; `setPerformanceFeeBps` stays on
    ///      the 24 h treasury lane. Without the second assertion a sweeping "move every HouseVault admin setter to
    ///      GUARDIAN" would pass this test, and that is a larger change than the one ordered.
    function test_houseVaultSetLimitsIsGuardian() public view {
        string memory json = _rolesJson();
        assertEq(
            json.readString('.targets.HouseVault["setLimits((uint64,uint128,uint16,uint16,uint32,uint128))"]'),
            "GUARDIAN",
            "HouseVault.setLimits must answer to GUARDIAN (0 delay) -- owner order 2026-09-22 05:55Z"
        );
        assertEq(
            uint256(manager.getTargetFunctionRole(address(houseVault), HouseVault.setLimits.selector)),
            uint256(V8Roles.GUARDIAN),
            "the live fixture maps setLimits to GUARDIAN"
        );
        assertEq(
            json.readUint(".delaysS.GUARDIAN"), 0, "GUARDIAN must stay a 0-delay lane or the order is not honoured"
        );
        assertEq(
            json.readString('.targets.HouseVault["setPerformanceFeeBps(uint16)"]'),
            "TREASURY_ADMIN",
            "setPerformanceFeeBps stays TREASURY_ADMIN: the owner asked for the limits only"
        );
        assertEq(
            uint256(manager.getTargetFunctionRole(address(houseVault), HouseVault.setPerformanceFeeBps.selector)),
            uint256(V8Roles.TREASURY_ADMIN),
            "the live fixture keeps setPerformanceFeeBps on TREASURY_ADMIN"
        );
    }

    /// @dev T-OP-159, THE LIVE HALF -- the same shape as {test_opsAdminCannotCallTheSelectorItUsedToHold}. The
    ///      manifest walk and the wiring both read one file and would agree about a file that was simply wrong, so
    ///      this asks the deployed vault instead, with accounts that hold ONE role each:
    ///        - an account holding ONLY GUARDIAN sets the limits and the vault stores them;
    ///        - an account holding ONLY TREASURY_ADMIN (delay 0, so the refusal is a ROLE refusal and not a missing
    ///          schedule) is refused on `setLimits` with `NotAuthorized`, and NOT an unrelated revert;
    ///        - the same TREASURY_ADMIN-only account still reaches `setPerformanceFeeBps` -- the positive control
    ///          that proves the refusal above is about the SELECTOR, not the account;
    ///        - a stranger is refused on both.
    ///      PROVE-BY-BREAKING, recorded in the T-OP-159 evidence: with the manifest row restored to TREASURY_ADMIN
    ///      the first leg reverts `NotAuthorized` (GUARDIAN-only caller refused) and the second leg's call SUCCEEDS,
    ///      so both assertions go red; with the row at GUARDIAN both go green.
    function test_houseVaultSetLimits_guardianOnlySetsThem_treasuryAdminOnlyIsRefused() public {
        address guardianOnly = makeAddr("guardianOnly");
        address treasuryOnly = makeAddr("treasuryAdminOnly");
        _grant(V8Roles.GUARDIAN, guardianOnly, 0);
        _grant(V8Roles.TREASURY_ADMIN, treasuryOnly, 0);

        HouseVault.Limits memory next = _houseLimits();
        next.maxSeriesUnits = 1; // any value that differs from the constructor's, so storage is observed to move
        next.maxDailyOutflow = 1;
        assertTrue(
            houseVault.limits().maxSeriesUnits != next.maxSeriesUnits, "precondition: the new limits must differ"
        );

        // GUARDIAN alone: accepted, and stored.
        vm.prank(guardianOnly);
        houseVault.setLimits(next);
        HouseVault.Limits memory got = houseVault.limits();
        assertEq(got.maxSeriesUnits, next.maxSeriesUnits, "a GUARDIAN-only caller must be able to set the limits");
        assertEq(got.maxDailyOutflow, next.maxDailyOutflow, "and the whole tuple is stored");

        // TREASURY_ADMIN alone: refused on setLimits, with the manager's NotAuthorized.
        vm.prank(treasuryOnly);
        (bool ok, bytes memory ret) = address(houseVault).call(abi.encodeCall(HouseVault.setLimits, (next)));
        assertFalse(ok, "a TREASURY_ADMIN-only caller must no longer be able to call HouseVault.setLimits");
        assertTrue(_isNotAuthorized(ret), "TREASURY_ADMIN's refusal must be NotAuthorized, not an unrelated revert");

        // ...and still reaches the setter the owner did NOT move: the positive control.
        vm.prank(treasuryOnly);
        houseVault.setPerformanceFeeBps(1);
        assertEq(houseVault.performanceFeeBps(), 1, "setPerformanceFeeBps stays reachable by TREASURY_ADMIN");

        // A stranger is refused on both.
        vm.prank(stranger);
        (ok, ret) = address(houseVault).call(abi.encodeCall(HouseVault.setLimits, (next)));
        assertFalse(ok, "a stranger must be refused on setLimits");
        assertTrue(_isNotAuthorized(ret), "with NotAuthorized");
        vm.prank(stranger);
        (ok, ret) = address(houseVault).call(abi.encodeCall(HouseVault.setPerformanceFeeBps, (1)));
        assertFalse(ok, "a stranger must be refused on setPerformanceFeeBps");
        assertTrue(_isNotAuthorized(ret), "with NotAuthorized");
    }

    function test_everyManifestTargetResolvesToALiveInstance() public view {
        string memory json = _rolesJson();
        string[] memory names = vm.parseJsonKeys(json, ".targets");
        assertGt(names.length, 0, "roles.v8.json names no targets at all");
        uint256 n;
        bool sawBuyback;
        for (uint256 i; i < names.length; ++i) {
            // FAIL BY NAME. The owner ruling for this row is explicit: a target the harness cannot construct must
            // stop the run rather than be skipped. `address(0)` here is precisely how EarnVault and
            // StockVenueAdapter went eighteen-of-twenty-one unnoticed.
            assertTrue(
                _targetOf(names[i]) != address(0),
                string.concat("roles.v8.json names a target this harness does not deploy: ", names[i])
            );
            uint256 c = vm.parseJsonKeys(json, string.concat(".targets.", names[i])).length;
            n += c;
            if (keccak256(bytes(names[i])) == keccak256("V4BuybackExecutor")) {
                sawBuyback = true;
                assertEq(c, 0, "V4BuybackExecutor must have zero restricted selectors");
            } else {
                assertGt(c, 0, names[i]);
            }
        }
        assertTrue(sawBuyback, "V4BuybackExecutor missing from targets");
        assertGt(n, 0, "roles.v8.json maps no selectors at all");
    }

    /// @dev T-220. Was seventeen hand-listed calls against a manifest of twenty-one. The subject set is now the
    ///      manifest itself, so a target cannot be added to `roles.v8.json` and silently left unprobed.
    ///      V4BuybackExecutor has an empty map and is skipped by {_assertTargetMapped}'s own guard.
    function test_manifestSelectorsRevertNotAuthorizedForStranger() public {
        string[] memory names = vm.parseJsonKeys(_rolesJson(), ".targets");
        for (uint256 i; i < names.length; ++i) {
            _assertTargetMapped(names[i], _targetOf(names[i]));
        }
    }

    /// @dev C8-05: the manifest says {MakerVault.deposit} carries no role. A stranger must therefore get PAST the
    ///      gate -- the call still fails, on the ERC-20 pull it has not approved, which is a different error. This
    ///      is the positive half of the matrix: the unmapped probe proves nothing was added, this proves nothing
    ///      was left behind.
    function test_permissionlessSelectorsAreNotGated() public {
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(MakerVault.deposit, (address(usdg), 1)));
        assertFalse(ok, "the pull still fails without an approval");
        assertFalse(_isNotAuthorized(ret), "but NOT because deposit is gated");

        vm.prank(stranger);
        (ok, ret) = address(roller).call(abi.encodeCall(AutoRoller.roll, (stranger, address(usdg))));
        assertTrue(ok, "roll is permissionless and just reports nothing to do");
    }

    /// @dev Load-bearing unrestricted row: Clearinghouse.mint sits inside the book's try/gas. A stray `restricted`
    ///      mapping would turn fills into silent skips. A stranger who is not a minter must revert NotMinter, not
    ///      the manager's NotAuthorized.
    function test_clearinghouseMintIsNotManagerRestricted() public {
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(house).call(_dummyCalldata("mint(uint256,uint64,address,address)"));
        assertFalse(ok, "stranger mint must revert");
        assertFalse(_isNotAuthorized(ret), "mint must not be manager-restricted");
        assertEq(bytes4(ret), V2Errors.NotMinter.selector, "stranger mint is NotMinter");
    }

    function test_holderCanCallMappedSelectors() public {
        uint32[] memory one = new uint32[](1);
        one[0] = 1;
        vm.prank(holder);
        calendar.setHolidays(one, true);
        vm.prank(holder);
        // T-479: an instant whose settlement window lies inside a session (Wed 2026-09-16 12:00 New York); the
        // calendar now refuses one no session can price, and this row checks access, not the instant.
        calendar.setSpecialExpiry(1_789_574_400, true);
        vm.prank(holder);
        registry.setTier(holder, 1);
        V2Types.FeeParams memory fees = book.feeParams();
        vm.prank(holder);
        book.setFeeParams(fees);
        vm.prank(holder);
        book.setMakerRegistry(registry);
        vm.prank(holder);
        book.setDiscountModule(IFeeDiscount(address(0)));
        vm.prank(holder);
        book.setFeeRecipient(holder);
        vm.prank(holder);
        book.setFundingAllowed(holder, true);
        vm.prank(holder);
        book.setTradingPaused(true);
        vm.prank(holder);
        book.setTradingPaused(false);
    }

    /// @dev Walks the compiled ABI with dummy-decoded calldata. Every selector that reverts `NotAuthorized` for a
    ///      stranger MUST be in the JSON, except `setAuthority(address)` (hardcoded authority-only, not `restricted`)
    ///      and the `unrestricted` rows (in-contract gates that reuse NotAuthorized, e.g. OrderBook.setFunding).
    /// @dev T-220. Was eighteen hand-listed calls against a manifest of twenty-one, which is the defect this row
    ///      exists to remove: EarnVault and StockVenueAdapter were added to the MANIFEST and not to the WALK, so
    ///      the walk's coverage never changed and the guard reported green about contracts it had never read.
    ///      The subject set is the manifest now, and {_artifactOf} resolves the compiled ABI per TARGET NAME
    ///      rather than per artifact -- see its note on RewardsDistributorLender.
    function test_restrictedSelectorMissingFromManifestFails() public {
        string[] memory names = vm.parseJsonKeys(_rolesJson(), ".targets");
        for (uint256 i; i < names.length; ++i) {
            // EXTERNAL SELF-CALL, ON PURPOSE, AND IT IS NOT STYLE. Each target reads a compiled artifact and parses
            // its whole `methodIdentifiers` map. Solidity never frees memory inside one call frame, so walking all
            // twenty-one in a single frame died with `EvmError: MemoryOOG` -- the derivation was correct and the
            // frame was the problem. An external call gives every target a fresh memory space; a revert inside
            // still propagates with its message intact, which is what the assertions depend on.
            this.assertNoUnmappedRestricted(names[i], _targetOf(names[i]), _artifactOf(names[i]));
        }
    }

    /// @dev Each `unrestricted` signature is in the ABI, is NOT in `targets`, and therefore cannot grow a manager
    ///      role without this file moving. Mint is the load-bearing case (see test_clearinghouseMintIsNotManagerRestricted).
    function test_unrestrictedSectionIsNotManagerMapped() public {
        string memory json = _rolesJson();
        string[] memory groups = vm.parseJsonKeys(json, ".unrestricted");
        for (uint256 i; i < groups.length; ++i) {
            if (bytes(groups[i])[0] == "_") continue;
            address target = _targetOf(groups[i]);
            require(target != address(0), string.concat("no live instance for unrestricted group ", groups[i]));
            string memory artifact = string.concat("out/", groups[i], ".sol/", groups[i], ".json");
            string memory art = vm.readFile(artifact);
            string[] memory methods = vm.parseJsonKeys(art, ".methodIdentifiers");
            string[] memory mapped = vm.parseJsonKeys(json, string.concat(".targets.", groups[i]));
            string[] memory sigs = vm.parseJsonKeys(json, string.concat(".unrestricted.", groups[i]));
            for (uint256 j; j < sigs.length; ++j) {
                if (bytes(sigs[j])[0] == "_") continue;
                bool inAbi;
                for (uint256 k; k < methods.length; ++k) {
                    if (keccak256(bytes(methods[k])) == keccak256(bytes(sigs[j]))) {
                        inAbi = true;
                        break;
                    }
                }
                require(inAbi, string.concat("unrestricted signature missing from ABI: ", groups[i], ".", sigs[j]));
                for (uint256 k; k < mapped.length; ++k) {
                    require(
                        keccak256(bytes(mapped[k])) != keccak256(bytes(sigs[j])),
                        string.concat("unrestricted signature also mapped: ", groups[i], ".", sigs[j])
                    );
                }
            }
        }
    }

    function test_jsonRoleIdsMatchV8RolesLibrary() public view {
        _assertManifestMatchesLibrary();
        assertEq(uint256(V8Roles.ADMIN), 0);
        assertEq(uint256(V8Roles.COUNT), 11);
    }

    function _targetOf(string memory name) internal view returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("ExpiryCalendar")) return address(calendar);
        if (h == keccak256("MakerRegistry")) return address(registry);
        if (h == keccak256("Clearinghouse")) return address(house);
        if (h == keccak256("OrderBook")) return address(book);
        if (h == keccak256("PayoutRouter")) return address(payout);
        if (h == keccak256("FeeSplitter")) return address(splitter);
        if (h == keccak256("AutoRoller")) return address(roller);
        if (h == keccak256("MakerVault")) return address(vault);
        if (h == keccak256("RewardsDistributor")) return address(rewards);
        if (h == keccak256("SettlementOracle")) return address(settlement);
        if (h == keccak256("ChainlinkFeedSource")) return address(clSource);
        if (h == keccak256("UniV3TwapSource")) return address(twapSource);
        if (h == keccak256("DataStreamsSource")) return address(streamsSource);
        if (h == keccak256("KeeperRewards")) return address(keepers);
        if (h == keccak256("V4BuybackExecutor")) return address(buyback);
        if (h == keccak256("HouseVaultFactory")) return address(houseFactory);
        if (h == keccak256("HouseVault")) return address(houseVault);
        if (h == keccak256("Hedger")) return address(hedger);
        if (h == keccak256("EarnVault")) return address(earn);
        if (h == keccak256("StockVenueAdapter")) return address(venueAdapter);
        if (h == keccak256("RewardsDistributorLender")) return address(rewardsLender);
        // DELIBERATELY STILL address(0) FOR AN UNKNOWN NAME, and that is now load-bearing rather than lax:
        // test_everyManifestTargetResolvesToALiveInstance fails BY NAME on any manifest target that lands here,
        // so a twenty-second target cannot be added to roles.v8.json and quietly go unwalked.
        return address(0);
    }

    /// @dev The compiled artifact for a manifest TARGET NAME. Defaults to `out/<Name>.sol/<Name>.json`, which is
    ///      right for twenty of the twenty-one.
    ///
    ///      THE EXCEPTION IS THE WHOLE REASON THIS IS A FUNCTION. `RewardsDistributorLender` is a SECOND
    ///      `RewardsDistributor` instance -- same contract, same artifact, a different address and a different
    ///      reward token (V2DeployBase.sol) -- and its three selectors are byte-identical to the first's. A subject
    ///      set keyed on ARTIFACT would therefore look complete while walking one of the two live instances, which
    ///      is this row's own defect wearing a different coat. Key on the target name, one entry per deployment,
    ///      and translate to an artifact only here.
    function _artifactOf(string memory name) internal pure returns (string memory) {
        if (keccak256(bytes(name)) == keccak256("RewardsDistributorLender")) {
            return "out/RewardsDistributor.sol/RewardsDistributor.json";
        }
        return string.concat("out/", name, ".sol/", name, ".json");
    }

    function _assertTargetMapped(string memory name, address target) internal {
        string memory json = _rolesJson();
        string memory path = string.concat(".targets.", name);
        require(target != address(0), string.concat("no live instance for manifest target ", name));
        string[] memory sigs = vm.parseJsonKeys(json, path);
        // V4BuybackExecutor is the one legitimately empty map (it is not Managed). Every other empty map is a
        // manifest that lost its rows, which the count cross-check catches by name.
        if (sigs.length == 0) return;
        for (uint256 i; i < sigs.length; ++i) {
            bytes memory data = _dummyCalldata(sigs[i]);
            vm.prank(stranger);
            (bool ok, bytes memory ret) = target.call(data);
            require(!ok, "mapped selector must revert for a stranger");
            require(_isNotAuthorized(ret), "mapped selector must revert NotAuthorized");
        }
    }

    /// @dev External so {test_restrictedSelectorMissingFromManifestFails} can call it per target through `this`
    ///      and get a fresh memory frame each time. Not meant to be called from outside the test.
    function assertNoUnmappedRestricted(string memory name, address target, string memory artifact) external {
        require(target != address(0), string.concat("no live instance for manifest target ", name));
        _assertNoUnmappedRestricted(name, target, artifact);
    }

    function _assertNoUnmappedRestricted(string memory name, address target, string memory artifact) internal {
        string memory json = _rolesJson();
        string memory path = string.concat(".targets.", name);
        string[] memory mapped = vm.parseJsonKeys(json, path);
        string memory art = vm.readFile(artifact);
        string[] memory methods = vm.parseJsonKeys(art, ".methodIdentifiers");
        for (uint256 i; i < methods.length; ++i) {
            if (_isUnmappedExempt(name, methods[i])) continue;
            bytes memory data = _dummyCalldata(methods[i]);
            vm.prank(stranger);
            (bool ok, bytes memory ret) = target.call(data);
            if (ok || !_isNotAuthorized(ret)) continue;
            bool found;
            for (uint256 j; j < mapped.length; ++j) {
                if (bytes4(keccak256(bytes(mapped[j]))) == bytes4(keccak256(bytes(methods[i])))) {
                    found = true;
                    break;
                }
            }
            require(found, string.concat("restricted selector missing from roles.v8.json: ", methods[i]));
        }
    }

    /// @dev Not `restricted`, but a stranger still sees `NotAuthorized`:
    ///      - `setAuthority(address)`: Managed, `msg.sender != authority()`, ADMIN is manager-only.
    ///      - Clearinghouse `batchRedeemOne` / `convertPayout`: `msg.sender != address(this)` self-calls.
    ///      - ERC-1155 receiver hooks: Clearinghouse-only (or always-revert on OrderBook batch).
    ///      - OrderBook.placeFor: maker/delegate `_authorize`, not `restricted`.
    ///      - `pin(address,uint40)`: oracle-only (`isOracle` / clearinghouse), missing from unrestricted JSON
    ///        (`roles.v8.json` is out of scope).
    ///      - PayoutRouter/V4BuybackExecutor unlock/v3 callbacks and V4BuybackExecutor.buy (splitter-only;
    ///        unrestricted JSON names `execute`, not `buy`).
    ///      Unrestricted JSON rows reuse NotAuthorized for in-contract gates (OrderBook.setFunding,
    ///      V4BuybackExecutor.execute). Mint is guarded separately (NotMinter, not this list).
    function _isUnmappedExempt(string memory name, string memory method) internal view returns (bool) {
        bytes32 m = keccak256(bytes(method));
        // T-SEC-06. WAS TEN INLINE `if`s. The same ten exemptions are now needed by the standalone gate
        // (`VerifyV8._unmappedExempt`), which probes a live deployment where this test is not running. Two
        // hand-kept copies of a list whose whole job is to make a guard look away would have drifted silently,
        // so the list is data here and {test_unmappedExemptListMatchesVerifyV8} asserts the two sets are equal.
        // T-535. SCOPED BY OWNER, and it was not. This loop used to compare the SIGNATURE alone and never
        // look at `name`, so a hard exemption written for one contract waved the same signature through on
        // EVERY contract the matrix walks. That is not hypothetical at the shape level: `pin(address,uint40)`
        // is declared on four concrete sources (ChainlinkFeedSource, DataStreamsSource, SettlementOracle,
        // UniV3TwapSource), `onERC1155Received`/`onERC1155BatchReceived` on four vault-ish contracts and
        // `unlockCallback` on two, while each exemption was written for exactly one of them. Nothing is hidden
        // TODAY -- none of the other declarations is a restricted-and-unmapped selector -- so this is the
        // untidiness closed before it becomes a hole, not a live defect being patched.
        // The JSON branch below has always scoped by name (it only reads `.unrestricted.<name>`); this makes
        // the two branches agree.
        string[] memory hard = _hardExemptSignatures();
        string[] memory owner = _hardExemptOwners();
        require(hard.length == owner.length, "hard exemption list and its owner list are different lengths");
        for (uint256 i; i < hard.length; ++i) {
            if (m != keccak256(bytes(hard[i]))) continue;
            // An empty owner means "any contract": `setAuthority(address)` really is authority-only on every
            // Managed contract, so scoping it to one name would make the matrix demand a mapping that must
            // not exist.
            if (bytes(owner[i]).length == 0) return true;
            if (_ownerListContains(owner[i], name)) return true;
        }
        string memory json = _rolesJson();
        string[] memory groups = vm.parseJsonKeys(json, ".unrestricted");
        for (uint256 i; i < groups.length; ++i) {
            if (bytes(groups[i])[0] == "_") continue;
            if (keccak256(bytes(groups[i])) != keccak256(bytes(name))) continue;
            string[] memory sigs = vm.parseJsonKeys(json, string.concat(".unrestricted.", groups[i]));
            for (uint256 j; j < sigs.length; ++j) {
                if (bytes(sigs[j])[0] == "_") continue;
                if (keccak256(bytes(sigs[j])) == keccak256(bytes(method))) return true;
            }
        }
        return false;
    }

    /// @dev The exemptions that are NOT derivable from `roles.v8.json`: each is a signature that answers
    ///      `NotAuthorized` to a stranger through an in-contract gate rather than through the manager. The reason
    ///      for each row is on {_isUnmappedExempt}. Mirrored by `VerifyV8.unmappedExemptSignatures`.
    /// @dev T-535. The scoping itself, asserted rather than inferred. Before this row the hard branch of
    ///      {_isUnmappedExempt} compared the SIGNATURE alone, so an exemption written for one contract waved
    ///      that signature through on every contract the matrix walks. These four assertions are what fails if
    ///      anyone removes the owner check: the first two are the exemption doing its job, the second two are
    ///      the hole it used to leave.
    function test_hardExemptionsAreScopedToTheirOwner() public view {
        assertTrue(
            _isUnmappedExempt("SettlementOracle", "pin(address,uint40)"),
            "pin is exempt on the oracle, which is what the exemption is for"
        );
        assertTrue(
            _isUnmappedExempt("ChainlinkFeedSource", "pin(address,uint40)"),
            "and on the sources, which is why the owner list holds four names and not one"
        );
        assertFalse(
            _isUnmappedExempt("Clearinghouse", "pin(address,uint40)"),
            "but NOT on a contract that does not own it: that is the hole the unscoped list left"
        );
        assertFalse(
            _isUnmappedExempt("ExpiryCalendar", "buy(uint256,uint256,uint256)"),
            "an exemption written for the buyback executor must not cover the calendar"
        );
        assertTrue(
            _isUnmappedExempt("ExpiryCalendar", "setAuthority(address)"),
            "an empty owner still means every contract, which setAuthority genuinely is"
        );
    }

    /// @dev Whether `name` appears in a comma-separated owner list. Several exemptions legitimately belong to
    ///      more than one contract -- `pin(address,uint40)` is on the oracle AND on all three sources -- and a
    ///      single-owner field would have forced either a wrong mapping or a blanket exemption. Written with no
    ///      trimming because the lists below carry no spaces, and a silent mismatch here would re-open exactly
    ///      the hole this scoping closes.
    function _ownerListContains(string memory list, string memory name) internal pure returns (bool) {
        bytes memory l = bytes(list);
        bytes memory n = bytes(name);
        uint256 start;
        for (uint256 i; i <= l.length; ++i) {
            if (i != l.length && l[i] != ",") continue;
            if (i - start == n.length) {
                bool same = true;
                for (uint256 k; k < n.length; ++k) {
                    if (l[start + k] != n[k]) {
                        same = false;
                        break;
                    }
                }
                if (same) return true;
            }
            start = i + 1;
        }
        return false;
    }

    /// @dev The contract each hard exemption is written FOR, index-aligned with {_hardExemptSignatures}. An
    ///      empty string means the exemption is not contract-specific. Kept as a SEPARATE list rather than
    ///      folded into the signatures because {test_unmappedExemptListMatchesVerifyV8} asserts that the
    ///      signature SET equals `VerifyV8.unmappedExemptSignatures`, and `VerifyV8.s.sol` is another file:
    ///      changing the exported shape here would break that mirror for a reason unrelated to this fix.
    function _hardExemptOwners() internal pure returns (string[] memory owners) {
        owners = new string[](10);
        // DERIVED FROM THE ARTIFACTS, not guessed: each list is the manifest targets whose compiled ABI
        // exposes that signature and which do not map it. Two earlier drafts scoped `pin` and
        // `unlockCallback` to one contract each and {test_restrictedSelectorMissingFromManifestFails}
        // failed on the others -- this scoping catching its own first draft, twice.
        owners[0] = ""; // setAuthority: authority-only on every Managed contract, all twenty of them
        owners[1] = "Clearinghouse"; // batchRedeemOne: self-call
        owners[2] = "Clearinghouse"; // convertPayout: self-call
        // the ERC-1155 receiver hooks, on every contract that can hold options
        owners[3] = "OrderBook,MakerVault,HouseVault,EarnVault";
        owners[4] = "OrderBook,MakerVault,HouseVault,EarnVault";
        owners[5] = "OrderBook"; // placeFor: in-contract maker gate
        owners[6] = "PayoutRouter,V4BuybackExecutor,Hedger"; // unlockCallback: PoolManager-only
        // pin: oracle-only (isOracle / clearinghouse), on the oracle AND all three sources
        owners[7] = "SettlementOracle,ChainlinkFeedSource,UniV3TwapSource,DataStreamsSource";
        owners[8] = "V4BuybackExecutor"; // buy: splitter-only
        owners[9] = "V4BuybackExecutor"; // uniswapV3SwapCallback: pool-only
    }

    function _hardExemptSignatures() internal pure returns (string[] memory sigs) {
        sigs = new string[](10);
        sigs[0] = "setAuthority(address)";
        sigs[1] = "batchRedeemOne(uint256,address,address)";
        sigs[2] = "convertPayout(address,uint256,uint256,address)";
        sigs[3] = "onERC1155Received(address,address,uint256,uint256,bytes)";
        sigs[4] = "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)";
        sigs[5] = "placeFor(address,uint256,uint8,uint128,uint64,uint40)";
        sigs[6] = "unlockCallback(bytes)";
        sigs[7] = "pin(address,uint40)";
        sigs[8] = "buy(uint256,uint256,uint256)";
        sigs[9] = "uniswapV3SwapCallback(int256,int256,bytes)";
    }

    /// @dev T-SEC-06. An exemption is a hole in BOTH walks, so the two lists have to be the same list. Equality
    ///      both ways, not a length check and not a one-directional subset: a row added to one side only is the
    ///      failure mode, and it is invisible to every other test in this file.
    function test_unmappedExemptListMatchesVerifyV8() public {
        string[] memory mine = _hardExemptSignatures();
        string[] memory theirs = new VerifyV8().unmappedExemptSignatures();
        assertEq(mine.length, theirs.length, "exempt list lengths differ");
        for (uint256 i; i < mine.length; ++i) {
            bool found;
            for (uint256 j; j < theirs.length; ++j) {
                if (keccak256(bytes(mine[i])) == keccak256(bytes(theirs[j]))) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string.concat("VerifyV8 does not exempt: ", mine[i]));
        }
        for (uint256 i; i < theirs.length; ++i) {
            bool found;
            for (uint256 j; j < mine.length; ++j) {
                if (keccak256(bytes(theirs[i])) == keccak256(bytes(mine[j]))) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string.concat("this harness does not exempt: ", theirs[i]));
        }
    }

    /// @dev The one EarnVault manifest row this file removes to prove the gate can see its subject. Chosen because
    ///      the literal occurs exactly once in `roles.v8.json`, so the scratch copy cannot lose a second row by
    ///      accident; the assertion on the key count below checks that anyway.
    string internal constant DROPPED_ROW = '"setSkimBps(uint16)": "TREASURY_ADMIN",';

    /// @dev T-SEC-06, PROVE BY BREAKING, AND THE STATE IT BREAKS INTO IS THE WHOLE POINT.
    ///
    ///      `VerifyV8` is the standalone gate: the thing an operator runs against a live deployment, where this
    ///      file is not running. Its unlisted-selector walk used to compare the on-chain role with the manifest's
    ///      role and nothing else. For a selector that is `restricted` on the contract but named by NEITHER side,
    ///      `AccessManager` answers `ADMIN_ROLE`, which is 0, and the manifest answers 0, so the comparison was
    ///      `0 == 0` and the gate printed a pass on exactly the deployment it exists to reject.
    ///
    ///      So the red case has to reach that state and not merely half of it. Dropping the manifest row alone
    ///      leaves the role still mapped on chain, `onChain != want` fires, and the old comparison catches it --
    ///      a red that proves nothing about this change. This clears the on-chain mapping TOO, asserts that the
    ///      old comparison is now satisfied, and only then requires the walk to go red.
    function test_verifyV8UnlistedWalkSeesARestrictedSelectorTheManifestDropped() public {
        VerifyV8 verify = new VerifyV8();
        V2DeployBase.Contracts memory c;
        c.earnVault = address(earn);
        string memory json = _rolesJson();

        assertTrue(
            verify._noUnlistedRestrictedTarget(c, manager, json, "EarnVault"),
            "GREEN: EarnVault is clean against the real manifest and the real wiring"
        );

        string memory dropped = vm.replace(json, DROPPED_ROW, "");
        assertEq(
            vm.parseJsonKeys(dropped, ".targets.EarnVault").length,
            vm.parseJsonKeys(json, ".targets.EarnVault").length - 1,
            "the scratch manifest must really be exactly one row shorter"
        );

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = EarnVault.setSkimBps.selector;
        // ADMIN_ROLE is 0 and is what the manager returns for a pair it was never told about, so writing 0 here
        // IS the unmapped state, reached through the manager's own API rather than asserted about.
        manager.setTargetFunctionRole(address(earn), sels, 0);
        assertEq(
            manager.getTargetFunctionRole(address(earn), sels[0]),
            0,
            "precondition: the selector is unmapped on chain, so the old comparison is 0 == 0 and passes"
        );
        // And it is still gated: the modifier is on the function, not in the manifest.
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(earn).call(abi.encodeCall(EarnVault.setSkimBps, (1)));
        assertFalse(ok, "precondition: setSkimBps still refuses a stranger");
        assertTrue(_isNotAuthorized(ret), "precondition: and it refuses with NotAuthorized");

        assertFalse(
            verify._noUnlistedRestrictedTarget(c, manager, dropped, "EarnVault"),
            "RED: setSkimBps is gated on chain and the scratch manifest no longer names it"
        );
    }

    function _isNotAuthorized(bytes memory ret) internal pure returns (bool) {
        return ret.length >= 4 && bytes4(ret) == V2Errors.NotAuthorized.selector;
    }
}
