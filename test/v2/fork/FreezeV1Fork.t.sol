// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FreezeV1} from "../../../script/v2/FreezeV1.s.sol";
import {AccountFactory} from "../../../src/solo/AccountFactory.sol";
import {WriterAccount} from "../../../src/solo/Account.sol";
import {Policy} from "../../../src/Policy.sol";
import {IValoremClear} from "../../../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../../../src/interfaces/IChainlinkFeed.sol";
import {Order, OrderComponents, OrderParameters} from "../../../src/interfaces/ISeaport.sol";
import {ISeaportFulfil} from "../../helpers/RealSeaportBase.sol";

import {ForkFloor} from "./ForkFloor.sol";

/// @notice `script/v2/FreezeV1.s.sol` against the LIVE v1 NVDA AccountFactory on a fork of chain 4663, sent by the
///         real role holders, and what the freeze does to a real listing on the live Seaport and Clear.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path "test/v2/fork/*" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as test/fork/ForkLive.t.sol does.
///
///      THE ROLE HOLDERS. AccessControl here is not enumerable, so the holders cannot be discovered on chain;
///      the registry's (`ops/markets/tier1.json`, NVDA row and `shared`) are checked with `hasRole` and pranked.
///      `test_fork_roleHoldersAreTheRegistrys` fails if they moved, because the owner commands in
///      docs/V1-RUNOFF.md would then be wrong. The other tests keep proving the mechanics through a stand-in
///      the admin grants, and say so in the log.
///
///      Everything goes through the Safe batch files, executed call by call from the holders: those are the
///      exact bytes the owner sends, whether from a key (same calldata) or a Safe.
contract FreezeV1ForkTest is Test {
    AccountFactory constant NVDA_FACTORY = AccountFactory(0xc4A5Cd0DE91CaB7F5Ebe2114bc63Fbb43E642BBb);
    address constant REGISTRY_ADMIN = 0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b;
    address constant REGISTRY_GUARDIAN = 0x29741A8d283a253E8Ce10aDfd04C6507438b6F39;
    address constant REGISTRY_KEEPER = 0x06c131cfEd73A56893f5eB52D17252856FAFC1d2;

    address admin;
    address guardian;
    address keeper;
    // Read from the factory in setUp, never inline after a prank: a view call between `vm.prank` and the call
    // it was meant for would consume the prank.
    IERC20 nvda;
    IERC20 usdg;
    address seaport;
    IValoremClear clear;
    address alice = makeAddr("alice");
    address buyer = makeAddr("buyer");

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        admin = REGISTRY_ADMIN;
        require(
            NVDA_FACTORY.hasRole(NVDA_FACTORY.DEFAULT_ADMIN_ROLE(), admin),
            "the registry admin no longer holds DEFAULT_ADMIN_ROLE on the live NVDA factory"
        );
        guardian = _holderOr(NVDA_FACTORY.GUARDIAN_ROLE(), REGISTRY_GUARDIAN, "guardian");
        keeper = _holderOr(NVDA_FACTORY.KEEPER_ROLE(), REGISTRY_KEEPER, "keeper");
        nvda = NVDA_FACTORY.asset();
        usdg = NVDA_FACTORY.usdg();
        seaport = address(NVDA_FACTORY.seaport());
        clear = NVDA_FACTORY.clear();
    }

    function _holderOr(bytes32 role, address registryHolder, string memory name) internal returns (address) {
        if (NVDA_FACTORY.hasRole(role, registryHolder)) return registryHolder;
        address standIn = makeAddr(string.concat("stand-in ", name));
        console2.log("WARNING: the registry's", name, "does not hold its role on the live factory; using a stand-in");
        vm.prank(admin);
        NVDA_FACTORY.grantRole(role, standIn);
        return standIn;
    }

    /*//////////////////////////////////////////////////////////////
                         THE FREEZE ON THE LIVE FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_fork_roleHoldersAreTheRegistrys() public onlyFork {
        assertTrue(NVDA_FACTORY.hasRole(NVDA_FACTORY.DEFAULT_ADMIN_ROLE(), REGISTRY_ADMIN), "admin");
        assertTrue(NVDA_FACTORY.hasRole(NVDA_FACTORY.GUARDIAN_ROLE(), REGISTRY_GUARDIAN), "guardian");
        assertTrue(NVDA_FACTORY.hasRole(NVDA_FACTORY.KEEPER_ROLE(), REGISTRY_KEEPER), "keeper");
        assertFalse(NVDA_FACTORY.hasRole(NVDA_FACTORY.GUARDIAN_ROLE(), REGISTRY_ADMIN), "admin is not the guardian");
    }

    /// @dev Batch run (no keys, the real holders named as the Safes, so the role check runs on the live
    ///      factory), the holders send the files, the key-less re-run skips both calls and post-checks. If the
    ///      owner has already frozen mainnet, the first run is the check and the test says so.
    function test_fork_freezeLiveFactory_batchesThenPostChecks() public onlyFork {
        bool haltedBefore = NVDA_FACTORY.writesHalted();
        uint256 capBefore = NVDA_FACTORY.depositCap();
        console2.log("fork block", block.number, "timestamp", block.timestamp);
        console2.log("live writesHalted()", haltedBefore);
        console2.log("live depositCap()  ", capBefore);
        console2.log(
            "live accounts, live, pending",
            NVDA_FACTORY.nextIndex(),
            NVDA_FACTORY.liveCount(),
            NVDA_FACTORY.pendingCount()
        );
        uint256 missing = (haltedBefore ? 0 : 1) + (capBefore == 0 ? 0 : 1);

        FreezeV1.Inputs memory in_ = _inputs("live");
        (uint256 executed, uint256 skipped, uint256 batched, bool postChecked) = new FreezeV1().runWith(in_);
        assertEq(executed, 0, "no keys: nothing sent");
        assertEq(batched, missing, "one call per missing piece");
        assertEq(skipped, 2 - missing);
        assertEq(postChecked, missing == 0);
        // T-OP-045, post-assertion-return: the four assertions above are the batch-mode result and stand
        // whichever branch runs. When the live factory is already frozen there is nothing to send, and the
        // early exit is a logged branch rather than a `return` that reads as PASSED-with-everything-run.
        if (missing == 0) {
            console2.log("the live NVDA factory is already frozen on this block: the run above was the check");
        } else {
            assertEq(NVDA_FACTORY.writesHalted(), haltedBefore, "batch mode changed nothing");
            assertEq(NVDA_FACTORY.depositCap(), capBefore);

            _sendBatches(in_);

            (executed, skipped, batched, postChecked) = new FreezeV1().runWith(in_);
            assertEq(executed + batched, 0, "nothing left");
            assertEq(skipped, 2, "both reported as already done");
            assertTrue(postChecked, "post-check passed on the live factory");
            assertTrue(NVDA_FACTORY.writesHalted());
            assertEq(NVDA_FACTORY.depositCap(), 0);

            // And with real NVDA in hand and approved, a deposit of a whole token is refused by the cap.
            vm.prank(alice);
            WriterAccount a = NVDA_FACTORY.createAccount();
            // T-OP-045, post-assertion-return: the freeze is proven above; only the cap-refusal coda needs NVDA
            // in hand. `_deal` here logs and returns false without skipping, so say what was not exercised.
            if (!_deal(address(nvda), alice, 1e18)) {
                console2.log("the cap refusal below was not exercised: no NVDA balance slot on this fork");
            } else {
                vm.prank(alice);
                nvda.approve(address(a), 1e18);
                vm.prank(alice);
                vm.expectRevert(WriterAccount.DepositCapExceeded.selector);
                a.deposit(1e18);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    A LISTED LOT ON THE LIVE SEAPORT AND CLEAR
    //////////////////////////////////////////////////////////////*/

    /// @dev The run-off end to end on live contracts: a two-lot listing with one lot sold, then the freeze.
    ///      The unsold lot stops filling at once (and only because of the halt: lifting it revives the lot), the
    ///      buyer still exercises inside the window, a stranger settles at the account's expiry, and the writer
    ///      withdraws and claims while the market stays frozen.
    function test_fork_freezeStopsListedLots_soldLotRunsOff() public onlyFork {
        // T-OP-045, precondition-bail: nothing asserted yet, so a missing precondition is a SKIP, not a pass.
        if (NVDA_FACTORY.writesHalted() || NVDA_FACTORY.depositCap() == 0) {
            console2.log("the live NVDA factory is already frozen: no listing can be made to test against");
            vm.skip(true);
            return;
        }
        console2.log("fork block", block.number, "timestamp", block.timestamp);
        (uint256 strike, uint256 ask, bool fresh) = _weekTerms();
        // T-OP-045, precondition-bail: `_weekTerms` logged why the feed is too old to list against.
        if (!fresh) {
            vm.skip(true);
            return;
        }
        uint40 exerciseTs = uint40(block.timestamp + 3 days);
        vm.prank(keeper);
        NVDA_FACTORY.setWeek(strike, exerciseTs, exerciseTs + 1 days, ask);

        // T-OP-045, precondition-bail: `_deal` logs the missing slot; the skip is the honest outcome.
        if (!_deal(address(nvda), alice, 2e18)) {
            vm.skip(true);
            return;
        }
        if (!_deal(address(usdg), buyer, 1_000_000_000)) {
            vm.skip(true);
            return;
        }
        uint256 liveBefore = NVDA_FACTORY.liveCount();
        vm.prank(alice);
        WriterAccount a = NVDA_FACTORY.createAccount();
        vm.startPrank(alice);
        nvda.approve(address(a), 2e18);
        a.deposit(2e18);
        a.requestWrite(2);
        vm.stopPrank();
        vm.prank(keeper);
        NVDA_FACTORY.listFor(alice);
        assertEq(NVDA_FACTORY.liveCount(), liveBefore + 1, "listed on the live Seaport");
        vm.prank(buyer);
        usdg.approve(seaport, type(uint256).max);

        uint256 g = gasleft();
        assertTrue(_fill(a, 0), "lot 0 sells before the freeze");
        console2.log("gas: live fill before the freeze", g - gasleft());
        assertEq(a.contractsWritten(), 1);

        _freeze();

        Order memory lot1 = _order(a, 1);
        vm.prank(buyer);
        vm.expectRevert(WriterAccount.WritesAreHalted.selector);
        ISeaportFulfil(seaport).fulfillOrder(lot1, bytes32(0));
        assertEq(a.idleAssets(), 0, "the unsold lot stays reserved until settle");

        // The halt is the only thing in the way: lifted (before the close), the same order fills.
        uint256 snap = vm.snapshotState();
        vm.prank(guardian);
        NVDA_FACTORY.setWritesHalted(false);
        assertTrue(_fill(a, 1), "lot 1 fills once the halt is lifted");
        assertEq(a.contractsWritten(), 2);
        vm.revertToState(snap);
        assertTrue(NVDA_FACTORY.writesHalted(), "back to frozen");
        assertEq(a.contractsWritten(), 1);

        // The sold option is Valorem's: the buyer exercises it on the live Clear while v1 is frozen.
        uint256 optionId = a.optionId();
        vm.warp(exerciseTs);
        vm.startPrank(buyer);
        usdg.approve(address(clear), type(uint256).max);
        clear.exercise(optionId, 1);
        vm.stopPrank();
        assertEq(nvda.balanceOf(buyer), 1e18, "buyer took delivery");

        uint40 expiry = a.listedExpiryTs();
        assertEq(expiry, exerciseTs + 1 days + a.index(), "settle opens at base expiry + account index");
        vm.warp(expiry - 1);
        vm.expectRevert(WriterAccount.TooEarly.selector);
        a.settle();
        vm.warp(expiry);
        vm.prank(makeAddr("stranger"));
        a.settle();
        assertEq(NVDA_FACTORY.liveCount(), liveBefore, "drained");
        assertEq(usdg.balanceOf(address(a)), strike, "strike landed");
        assertEq(a.idleAssets(), 1e18, "the unsold lot is released");

        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.startPrank(alice);
        a.withdraw(1e18);
        a.claimUsdg();
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 1e18, "the unsold NVDA is home");
        assertEq(usdg.balanceOf(alice) - usdgBefore, strike, "and the strike");
        console2.log("frozen run-off on the live factory, Seaport and Clear: option", optionId);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _inputs(string memory name) internal view returns (FreezeV1.Inputs memory in_) {
        in_.factories = new AccountFactory[](1);
        in_.factories[0] = NVDA_FACTORY;
        in_.safeGuardian = guardian;
        in_.safeAdmin = admin;
        in_.guardianBatchOut = string.concat("broadcast/test-freeze-v1-fork-", name, "-guardian.json");
        in_.adminBatchOut = string.concat("broadcast/test-freeze-v1-fork-", name, "-admin.json");
    }

    function _freeze() internal {
        FreezeV1.Inputs memory in_ = _inputs("listed");
        new FreezeV1().runWith(in_);
        _sendBatches(in_);
        assertTrue(NVDA_FACTORY.writesHalted() && NVDA_FACTORY.depositCap() == 0, "frozen");
    }

    /// @dev Sends the guardian's file from the guardian and the admin's from the admin, call by call.
    function _sendBatches(FreezeV1.Inputs memory in_) internal {
        if (vm.exists(in_.guardianBatchOut)) _sendBatch(in_.guardianBatchOut, guardian, "guardian");
        if (vm.exists(in_.adminBatchOut)) _sendBatch(in_.adminBatchOut, admin, "admin");
    }

    function _sendBatch(string memory path, address sender, string memory role) internal {
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 4663, "batch chainId");
        for (uint256 i; vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(i), "]")); i++) {
            string memory base = string.concat(".transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(json, string.concat(base, ".to"));
            assertEq(to, address(NVDA_FACTORY), "every call goes to the live factory");
            vm.prank(sender);
            uint256 g = gasleft();
            (bool ok,) = to.call(vm.parseJsonBytes(json, string.concat(base, ".data")));
            assertTrue(ok, string.concat(role, " batch call reverted"));
            console2.log(string.concat("gas: ", role, " batch call"), i, g - gasleft());
        }
    }

    /// @dev A strike 7% out of the money at the live spot (inside the 3%..12% launch band) and an ask of twice
    ///      the policy's premium floor plus 1 USDG. `fresh` is false, with a log, when the feed is older than the
    ///      factory's `maxPriceAge` on this block: `list()` would then revert StalePrice.
    function _weekTerms() internal view returns (uint256 strike, uint256 ask, bool fresh) {
        IChainlinkFeed feed = NVDA_FACTORY.priceFeed();
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        fresh = block.timestamp - updatedAt <= NVDA_FACTORY.maxPriceAge();
        if (!fresh) {
            console2.log("skipping: the NVDA feed is older than maxPriceAge on this block", block.timestamp - updatedAt);
            return (0, 0, false);
        }
        uint256 spot = Policy.normalizeSpot(answer, feed.decimals());
        (,, uint16 minPremiumBps,,,) = NVDA_FACTORY.policy();
        strike = (spot * 10_700) / 10_000;
        ask = (2 * spot * minPremiumBps) / 10_000 + 1_000_000;
        console2.log("spot, strike, ask (USDG 6 dp)", spot, strike, ask);
    }

    function _order(WriterAccount a, uint256 salt) internal view returns (Order memory o) {
        OrderComponents memory c = a.lotOrder(salt);
        o.parameters = OrderParameters({
            offerer: c.offerer,
            zone: c.zone,
            offer: c.offer,
            consideration: c.consideration,
            orderType: c.orderType,
            startTime: c.startTime,
            endTime: c.endTime,
            zoneHash: c.zoneHash,
            salt: c.salt,
            conduitKey: c.conduitKey,
            totalOriginalConsiderationItems: c.consideration.length
        });
    }

    /// @dev The lot orders were validated on Seaport by the account at `list()`, so no signature is needed.
    function _fill(WriterAccount a, uint256 salt) internal returns (bool) {
        Order memory o = _order(a, salt);
        vm.prank(buyer);
        return ISeaportFulfil(seaport).fulfillOrder(o, bytes32(0));
    }

    function _deal(address token, address to, uint256 amount) internal returns (bool) {
        try this.dealToken(token, to, amount) {
            return true;
        } catch {
            console2.log("deal() could not locate the balance slot; skipping", token);
            return false;
        }
    }

    function dealToken(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `address(NVDA_FACTORY)`, an address this suite's own tests read.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_freezeV1ForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(address(NVDA_FACTORY), "FreezeV1Fork");
    }
}
