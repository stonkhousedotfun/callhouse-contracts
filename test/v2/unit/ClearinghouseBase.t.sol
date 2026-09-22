// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {BaseV2Test} from "../BaseV2.t.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockPayoutAdapter} from "../../../src/v2/mocks/MockPayoutAdapter.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";

/// @notice Shared fixture of the Clearinghouse suites (C2-05): the real ExpiryCalendar and KeeperRewards, the
///         MockSettlementOracle standing in for C2-04, a MockPayoutAdapter, and NVDA / TSLA registered as markets.
/// @dev Wiring, as a deployment would have it: `admin` holds DEFAULT_ADMIN_ROLE, `guardian` GUARDIAN_ROLE, `treasury`
///      receives fees. Both markets: strikeTick 1.00 USDG, exercise fee 25 bps, oracle = the mock. The adapter is set with
///      a 100 bps slippage bound and pays at NVDA_SPOT; KeeperRewards pays SETTLE_BOUNTY and REDEEM_BOUNTY under a
///      100 USDG daily cap. Spot is ok for both markets, so the strike band applies by default.
///      Traders (alice, bob, carol, mm) approve the Clearinghouse for USDG and both Stock Tokens. Lifecycle calls are
///      made by `keeper` so bounties never land in a holder's balance under test.
abstract contract ClearinghouseTestBase is BaseV2Test {
    Clearinghouse internal ch;
    ExpiryCalendar internal calendar;
    MockSettlementOracle internal oracle;
    KeeperRewards internal rewards;
    MockPayoutAdapter internal adapter;

    uint16 internal constant FEE_BPS = 25;
    uint16 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant SETTLE_BOUNTY = 50_000;
    uint256 internal constant REDEEM_BOUNTY = 20_000;
    uint256 internal constant REWARDS_BUDGET = 1_000e6;
    string internal constant BASE_URI = "https://app.stonkhouse.fun/api/v2/token/";

    /// @dev Storage slot of `_series` in Clearinghouse (forge inspect Clearinghouse storageLayout); the collision test
    ///      checks it against a live series before writing through it.
    uint256 internal constant SERIES_SLOT = 12;

    /// @dev Strikes on the 1.00 grid inside the NVDA band [110, 440].
    uint128 internal constant K_200 = 200_000_000;
    uint128 internal constant K_220 = 220_000_000;
    uint128 internal constant K_240 = 240_000_000;

    function _deployCore() internal virtual override {
        calendar = _newCalendar(new uint32[](0), admin);
        oracle = new MockSettlementOracle();
        ch = _newClearinghouse(address(usdg), address(calendar), treasury, BASE_URI, admin);
        _grant(V8Roles.GUARDIAN, guardian, 0);
        rewards = new KeeperRewards(IERC20(address(usdg)), address(manager), treasury);
        _wire(address(rewards), "KeeperRewards", admin, 0);
        adapter = new MockPayoutAdapter(IERC20(address(usdg)), NVDA_SPOT);
        vm.label(address(ch), "Clearinghouse");
        vm.label(address(calendar), "ExpiryCalendar");
        vm.label(address(oracle), "MockSettlementOracle");
        vm.label(address(rewards), "KeeperRewards");
        vm.label(address(adapter), "MockPayoutAdapter");

        vm.startPrank(admin);
        ch.setMinter(address(this), true);
        ch.setDefaultOracle(address(oracle));
        ch.setDefaultMarketFees(FEE_BPS, 0);
        ch.registerMarket(address(nvda), STRIKE_TICK, true);
        ch.setMarketOracle(address(nvda), address(oracle));
        ch.setMarketFees(address(nvda), FEE_BPS, 0);
        ch.registerMarket(address(tsla), STRIKE_TICK, true);
        ch.setMarketOracle(address(tsla), address(oracle));
        ch.setMarketFees(address(tsla), FEE_BPS, 0);
        ch.setPayoutAdapter(address(adapter), SLIPPAGE_BPS);
        ch.setKeeperRewards(address(rewards));
        rewards.setCaller(address(ch), true);
        rewards.setBounty(V2Constants.ACTION_SETTLE, SETTLE_BOUNTY);
        rewards.setBounty(V2Constants.ACTION_REDEEM, REDEEM_BOUNTY);
        rewards.setDailyCap(100e6);
        vm.stopPrank();

        usdg.mint(address(rewards), REWARDS_BUDGET);
        usdg.mint(address(adapter), 10_000_000e6);
        oracle.setSpot(address(nvda), true, NVDA_SPOT, START);
        oracle.setSpot(address(tsla), true, TSLA_SPOT, START);

        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            vm.startPrank(traders[i]);
            usdg.approve(address(ch), type(uint256).max);
            nvda.approve(address(ch), type(uint256).max);
            tsla.approve(address(ch), type(uint256).max);
            vm.stopPrank();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _cfg(address oracle_) internal pure returns (V2Types.MarketConfig memory) {
        return V2Types.MarketConfig({
            enabled: true,
            mintPaused: false,
            strikeTick: STRIKE_TICK,
            exerciseFeeBps: FEE_BPS,
            oracle: oracle_,
            mintFeePpm: 0
        });
    }

    function _call(uint128 strike, uint40 expiry) internal returns (uint256) {
        return ch.createSeries(address(nvda), false, strike, expiry);
    }

    function _put(uint128 strike, uint40 expiry) internal returns (uint256) {
        return ch.createSeries(address(nvda), true, strike, expiry);
    }

    function _deposit(address who, address asset, uint256 amount) internal {
        vm.prank(who);
        ch.deposit(asset, amount, who);
    }

    /// @dev Direct mint() requires isMinter[msg.sender] (Clearinghouse.sol:565). The fixture grants
    ///      address(this); EOAs are not minters. Writer names this as operator, then this mints.
    function _asMinter(address writer) internal {
        if (!ch.isOperator(writer, address(this))) {
            vm.prank(writer);
            ch.setOperator(address(this), true);
        }
    }

    /// @dev Deposits exactly the collateral `units` need, then mints as the fixture minter.
    function _write(address writer, uint256 longId, uint64 units, address longTo) internal {
        _deposit(writer, ch.collateralAsset(longId), units * ch.collateralPerUnit(longId));
        _asMinter(writer);
        ch.mint(longId, units, writer, longTo);
    }

    /// @dev Marks the series' expiry final at `price` in the mock oracle, warps past FINALIZE_DELAY and settles as
    ///      `keeper`.
    function _settle(uint256 longId, uint256 price) internal {
        V2Types.Series memory s = ch.series(longId);
        oracle.setSettlement(s.underlying, s.expiry, V2Types.SettlementStatus.Finalized, price);
        if (block.timestamp < s.expiry + V2Constants.FINALIZE_DELAY) vm.warp(s.expiry + V2Constants.FINALIZE_DELAY);
        vm.prank(keeper);
        assertTrue(ch.settle(longId), "settle advanced");
    }

    function _redeem(uint256 tokenId, address holder) internal returns (uint256 paid, bool inUsdg) {
        vm.prank(keeper);
        return ch.redeem(tokenId, holder);
    }

    function _short(uint256 longId) internal pure returns (uint256) {
        return V2Ids.shortIdOf(longId);
    }

    /// @dev Invariant 2 for one asset over the given accounts: free + locked of the given series + accrued fees never
    ///      exceed what the Clearinghouse holds.
    function _assertSolvent(address asset, address[] memory accounts, uint256[] memory longIds) internal view {
        uint256 claimed = ch.accruedFees(asset);
        for (uint256 i; i < accounts.length; ++i) {
            claimed += ch.free(accounts[i], asset);
        }
        for (uint256 i; i < longIds.length; ++i) {
            if (ch.collateralAsset(longIds[i]) == asset) claimed += ch.locked(longIds[i]);
        }
        assertLe(claimed, IERC20(asset).balanceOf(address(ch)), "invariant 2: free + locked + fees <= balance");
    }

    /// @dev Invariant 1 for an unsettled series.
    function _assertBacked(uint256 longId) internal view {
        assertEq(ch.totalSupply(longId), ch.totalSupply(_short(longId)), "invariant 1: long supply == short supply");
        assertEq(
            ch.locked(longId),
            ch.totalSupply(longId) * ch.collateralPerUnit(longId),
            "invariant 1: locked == supply * cpu"
        );
    }
}

/// @notice An ERC-1155 receiver whose acceptance hook can reject, or try one call back into the Clearinghouse and
///         record how it failed. Used by the mint and reentrancy tests.
contract ClearinghouseTestReceiver is IERC1155Receiver {
    address public target;
    bytes public callData;
    bool public reject;
    bool public propagate;

    bool public attempted;
    bool public succeeded;
    bytes public revertData;

    function setAttack(address target_, bytes calldata data, bool propagate_) external {
        target = target_;
        callData = data;
        propagate = propagate_;
    }

    function setReject(bool on) external {
        reject = on;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (reject) return bytes4(0xdeadbeef);
        if (target != address(0) && !attempted) {
            attempted = true;
            (bool ok, bytes memory ret) = target.call(callData);
            succeeded = ok;
            revertData = ret;
            if (!ok && propagate) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
