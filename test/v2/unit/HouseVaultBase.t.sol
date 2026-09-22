// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MakerTestBase} from "./MakerBase.t.sol";
import {HouseVault} from "../../../src/v2/periphery/house/HouseVault.sol";
import {HouseVaultFactory} from "../../../src/v2/periphery/house/HouseVaultFactory.sol";
import {IExpiryCalendar} from "../../../src/v2/interfaces/IExpiryCalendar.sol";
import {IOrderBook} from "../../../src/v2/interfaces/IOrderBook.sol";
import {ISettlementOracle} from "../../../src/v2/interfaces/ISettlementOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";

/// @notice Shared fixture of the House vault suites (P8-06). It EXTENDS {MakerTestBase} rather than rebuilding the
///         world: that gives the real Clearinghouse, the real OrderBook, the real ExpiryCalendar, the mock oracle
///         and a live {MakerVault} on the same state -- which is exactly what the equivalence criterion needs, since
///         it has to compare a HouseVault and a v8 MakerVault configured identically.
/// @dev MakerBase.t.sol is IMPORTED AND NOT EDITED. It belongs to the maker lane.
///
///      THE MANAGER IS WIRED BY HAND HERE, on purpose. {V8AccessTest._wire} reads `script/v2/roles.v8.json` and maps
///      every selector the manifest lists for a target name -- but HouseVault has NO manifest row yet: that row is
///      P8-06b's deliverable, and writing it here would be this task editing another lane's frozen artifact. So this
///      fixture calls `manager.setTargetFunctionRole` directly with the selector sets frozen in the P8-06 task
///      contract. When P8-06b lands its row, this fixture should switch to `_wire(vault, "HouseVault", ...)` and the
///      two must agree; {HouseVaultInterfaceTest} is what makes that agreement checkable, because it pins the same
///      strings against the compiled artifact.
abstract contract HouseVaultTestBase is MakerTestBase {
    HouseVault internal house;
    HouseVaultFactory internal factory;

    address internal lister = makeAddr("lister");
    address internal splitterAddr = makeAddr("feeSplitter");
    address internal depositorA = makeAddr("depositorA");
    address internal depositorB = makeAddr("depositorB");

    uint256 internal constant DEP_USDG = 10_000e6;
    uint256 internal constant DEP_STOCK = 10e18;

    function setUp() public virtual override {
        super.setUp();
        _deployHouse();
    }

    function _deployHouse() internal {
        house = new HouseVault(
            IOrderBook(address(book)),
            address(manager),
            IERC20(address(nvda)),
            IExpiryCalendar(address(calendar)),
            ISettlementOracle(address(oracle)),
            splitterAddr,
            _houseLimits(),
            "Stonkhouse House NVDA",
            "hNVDA"
        );
        vm.label(address(house), "HouseVault");

        factory = new HouseVaultFactory(
            IOrderBook(address(book)),
            address(manager),
            IExpiryCalendar(address(calendar)),
            ISettlementOracle(address(oracle)),
            splitterAddr
        );
        vm.label(address(factory), "HouseVaultFactory");

        _wireHouseByHand(address(house));
        _wireFactoryByHand(address(factory));
        _grant(V8Roles.LISTING, lister, 0);
        // GRANT THE GUARDIAN ITS ROLE. `_wireHouseByHand` MAPS `setQuotingPaused` to GUARDIAN, and nothing
        // anywhere granted GUARDIAN to anyone -- `V8Access.sol:187` grants QUOTER to `quoterHolder` and
        // `MakerBase.t.sol:131` grants QUOTER to `admin`, but no fixture on this chain grants GUARDIAN. So every
        // `vm.prank(guardian); house.setQuotingPaused(...)` died `NotAuthorized` at `AccessManager.canCall`, which
        // reads exactly like a contract refusing an authorised guardian and is not: the role table was right and
        // the role was never handed out. A role is (role, member) across ALL targets, which is why QUOTER worked
        // here without the House fixture granting it and why this one line is enough.
        _grant(V8Roles.GUARDIAN, guardian, 0);

        // The vault must be able to mint through the book exactly as MakerVault does. PRANKED as `admin`,
        // which is correct here and is what MakerBase.t.sol:103-104 and :123-124 do: the Clearinghouse is
        // constructed with `admin` as its authority principal, so `admin` -- not the test contract -- is who
        // may call `setMinter`. This prank is NOT the bug; the two `setTargetFunctionRole` pranks above were.
        vm.prank(admin);
        ch.setMinter(address(house), true);

        _fundDepositor(depositorA);
        _fundDepositor(depositorB);

        // ARM THE VAULT. `take` FAILS CLOSED until CONFIG_ADMIN has named a protocol account -- see
        // {HouseVault.protocolAccountsConfirmed}. Without this line every `take` in every suite built on this
        // fixture reverts `NoSource()`, which is the point: an unconfigured vault must not trade.
        //
        // THE ADDRESS IS CHOSEN, NOT ARBITRARY. `vault` is the v8 MakerVault living on this same state, and it is
        // the single protocol account a House vault is most likely to meet on the book. It is deliberately NOT
        // `mm`: {HouseVaultGuardsTest.test_take_allowsAnOrdinaryMaker} asserts `mm` is NOT a protocol account, and
        // arming with `mm` would make that test pass for the wrong reason.
        vm.prank(admin);
        house.setProtocolAccount(address(vault), true);
    }

    /// @dev A SECOND HOUSE VAULT, WIRED BUT NOT ARMED, for the tests that have to observe the unconfigured state.
    ///      It cannot be got by un-arming `house`: clearing the set does not disarm a vault on purpose (see
    ///      {HouseVault.setProtocolAccount}), so the only way to see a never-configured vault is to build one.
    function _newUnarmedHouse() internal returns (HouseVault fresh) {
        fresh = new HouseVault(
            IOrderBook(address(book)),
            address(manager),
            IERC20(address(nvda)),
            IExpiryCalendar(address(calendar)),
            ISettlementOracle(address(oracle)),
            splitterAddr,
            _houseLimits(),
            "Stonkhouse House NVDA unarmed",
            "hNVDA2"
        );
        vm.label(address(fresh), "HouseVaultUnarmed");
        _wireHouseByHand(address(fresh));
        vm.prank(admin);
        ch.setMinter(address(fresh), true);
        // NO setProtocolAccount CALL HERE. That is the entire point of this helper.
    }

    /// @dev The same guard rails MakerBase gives its MakerVault, so the equivalence test compares like with like.
    function _houseLimits() internal pure returns (HouseVault.Limits memory) {
        return HouseVault.Limits({
            maxSeriesUnits: MAX_SERIES_UNITS,
            maxTotalNotional: MAX_TOTAL_NOTIONAL,
            askToleranceBps: ASK_TOLERANCE_BPS,
            maxBidBpsOfSpot: MAX_BID_BPS,
            maxOrderLifetime: 0,
            maxDailyOutflow: MAX_DAILY_OUTFLOW
        });
    }

    /// @dev Maps the frozen section-12 selector sets onto `target` and grants each role to the fixture's holder.
    function _wireHouseByHand(address target) internal {
        string[10] memory quoterSigs = [
            "depositToClearinghouse(address,uint256)",
            "withdrawFromClearinghouse(address,uint256)",
            "place(uint256,uint8,uint128,uint64,uint40)",
            "replace(uint256,uint128,uint64)",
            "cancel(uint256[])",
            "take((uint256,bool,uint256[],uint64,uint64,uint128,bool,address,uint40,uint128))",
            "close(uint256,uint64)",
            "claimOwed()",
            "sync(uint256[])",
            "refreshApprovals()"
        ];
        bytes4[] memory q = new bytes4[](quoterSigs.length);
        for (uint256 i; i < quoterSigs.length; ++i) {
            q[i] = bytes4(keccak256(bytes(quoterSigs[i])));
        }
        // T-OP-159 (owner order 2026-09-22 05:55Z, "i dont want these numbers to have a delay at all"): `setLimits`
        // moved from TREASURY_ADMIN (24 h) to GUARDIAN (0 delay) in roles.v8.json. Only `setPerformanceFeeBps`
        // stays on the treasury lane. The hand list is kept in step for the same reason the CONFIG_ADMIN list below
        // is: this fixture is the INDEPENDENT copy that AccessMatrix.t.sol's manifest proof is measured against.
        bytes4[] memory t = new bytes4[](1);
        t[0] = bytes4(keccak256("setPerformanceFeeBps(uint16)"));
        // T-OP-064 (T-OP-058 follow-up): `setOracle(address)` is CONFIG_ADMIN in roles.v8.json and was missing here,
        // so in every suite on this base the selector fell to ADMIN by default and a "refuses everyone but
        // CONFIG_ADMIN" test could pass for the wrong reason. Kept as a HAND LIST on purpose rather than switched to
        // the manifest reader: `AccessMatrix.t.sol` already proves the manifest against the library and the live
        // wiring, and this fixture is the INDEPENDENT copy that makes that proof mean something -- a fixture that
        // read the manifest would agree with it by construction.
        bytes4[] memory c = new bytes4[](2);
        c[0] = bytes4(keccak256("setProtocolAccount(address,bool)"));
        c[1] = bytes4(keccak256("setOracle(address)"));
        bytes4[] memory g = new bytes4[](2);
        g[0] = bytes4(keccak256("setQuotingPaused(bool)"));
        g[1] = bytes4(keccak256("setLimits((uint64,uint128,uint16,uint16,uint32,uint128))"));

        // UNPRANKED. `setTargetFunctionRole` is an AccessManager ADMIN operation and the TEST CONTRACT is
        // this manager's admin (V8Access._map); `admin` is a role HOLDER, not ADMIN. Pranking it reverted
        // AccessManagerUnauthorizedAccount(admin, 0) here -- the FIRST call in setUp's wiring -- which is
        // why every suite built on this base died before a single test body ran. MakerBase.t.sol and
        // EarnVault.t.sol both map selectors unpranked for the same reason.
        manager.setTargetFunctionRole(target, q, V8Roles.QUOTER);
        manager.setTargetFunctionRole(target, t, V8Roles.TREASURY_ADMIN);
        manager.setTargetFunctionRole(target, c, V8Roles.CONFIG_ADMIN);
        manager.setTargetFunctionRole(target, g, V8Roles.GUARDIAN);
    }

    function _wireFactoryByHand(address target) internal {
        bytes4[] memory l = new bytes4[](1);
        l[0] = bytes4(keccak256("createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)"));
        // UNPRANKED, same reason as _wireHouseByHand.
        manager.setTargetFunctionRole(target, l, V8Roles.LISTING);
    }

    function _fundDepositor(address who) internal {
        _fund(who, DEP_USDG * 10, DEP_STOCK * 10, DEP_STOCK * 10);
        vm.startPrank(who);
        usdg.approve(address(house), type(uint256).max);
        nvda.approve(address(house), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Put spendable USDG in the VAULT'S OWN WALLET, for the guard tests that call {depositToClearinghouse}
    ///      before they can reach the guard they are actually testing. `_deployHouse` funds the DEPOSITORS
    ///      (`_fundDepositor`) and arms the vault, but nothing ever gave the vault itself a balance, so those tests
    ///      died `ERC20InsufficientBalance` inside `transferFrom(HouseVault -> Clearinghouse)` long before their
    ///      assertion ran.
    ///
    ///      IT USED TO SEED THROUGH `requestDeposit`, AND F3 IS WHY IT NO LONGER CAN. That route funded the wallet
    ///      with a QUEUED DEPOSIT -- somebody else's money, still cancellable -- and the helper's old comment said
    ///      out loud that it relied on "posting more than the free balance is the vault's own documented
    ///      behaviour ... nothing stops it going below the reserve". That WAS the F3 defect, and five guard tests
    ///      were reaching their subject by quoting with a queued depositor's USDG. {depositToClearinghouse} now
    ///      clamps to the unreserved wallet, so a vault whose only USDG is queued deposits can no longer write
    ///      against it -- correctly -- and those tests would have died `BadUnits` before their own assertion ran.
    ///
    ///      SO IT DEALS THE BALANCE, AND STILL DOES NOT ROLL. Rolling is the realistic way a vault acquires
    ///      unreserved USDG and is what `_seedFirstEpoch` does, but it MOVES `epochEnd`, and two tests in the
    ///      guards suite assert on where a series' expiry sits relative to that boundary -- seeding must not
    ///      quietly change the thing those tests measure. `deal` reaches the same END STATE as a roll for these
    ///      tests' purposes (pool USDG in the wallet, no reserve against it) without moving the boundary.
    function _seedVaultWallet(uint256 usdgAmount) internal {
        uint256 before = usdg.balanceOf(address(house));
        deal(address(usdg), address(house), before + usdgAmount);
        assertEq(house.pendingDepositUsdg(), 0, "the seed must not be reserved for a queued depositor");
        assertGe(usdg.balanceOf(address(house)), usdgAmount, "the seed did not reach the vault wallet");
    }

    function _requestDeposit(address who, uint256 usdgAmount, uint256 stockAmount) internal {
        vm.startPrank(who);
        if (usdgAmount != 0) house.requestDeposit(address(usdg), usdgAmount);
        if (stockAmount != 0) house.requestDeposit(address(nvda), stockAmount);
        vm.stopPrank();
    }

    /// @dev Drives the fixture to a rollable boundary: warp past {HouseVault.epochEnd} and make the oracle report the
    ///      epoch's settlement price Finalized at `price`.
    function _finalizeBoundary(uint256 price) internal {
        uint40 end = house.epochEnd();
        oracle.setSettlement(address(nvda), end, V2Types.SettlementStatus.Finalized, price);
        if (block.timestamp < end) vm.warp(end);
    }

    /// @dev A boundary the oracle has NOT finalized: guard (b) must refuse it.
    function _unfinalizedBoundary() internal {
        uint40 end = house.epochEnd();
        oracle.setSettlement(address(nvda), end, V2Types.SettlementStatus.Pending, 0);
        if (block.timestamp < end) vm.warp(end);
    }

    function _navPerShare() internal view returns (uint256) {
        uint256 supply = house.totalSupply();
        return supply == 0 ? 0 : house.nav() * 1e18 / supply;
    }
}
