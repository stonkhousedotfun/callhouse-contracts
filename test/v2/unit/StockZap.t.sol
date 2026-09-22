// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {IPayoutRouter} from "../../../src/v2/interfaces/IPayoutRouter.sol";
import {IStockZap} from "../../../src/v2/interfaces/IStockZap.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MockSettlementOracle} from "../../../src/v2/mocks/MockSettlementOracle.sol";
import {PayoutRouter} from "../../../src/v2/periphery/PayoutRouter.sol";
import {StockZap} from "../../../src/v2/periphery/StockZap.sol";
import {IUniV3PoolFactory, IUniV3SwapRouter02} from "../../../src/v2/periphery/PayoutDeps.sol";
import {IV4PoolManager, IV4StateView, V4PoolKey, V4SwapParams} from "../../../src/v2/periphery/BuybackDeps.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";

interface IStockZapUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

contract StockZapMockV3Factory is IUniV3PoolFactory {
    mapping(bytes32 pair => address pool) private _pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        _pools[keccak256(abi.encode(a, b, fee))] = pool;
        _pools[keccak256(abi.encode(b, a, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return _pools[keccak256(abi.encode(a, b, fee))];
    }
}

contract StockZapMockV3Router is IUniV3SwapRouter02 {
    address public immutable factory;
    uint256 public quote = 1e18;
    uint16 public consumeBps = 10_000;

    constructor(address factory_) {
        factory = factory_;
    }

    function setQuote(uint256 quote_) external {
        quote = quote_;
    }

    function setConsumeBps(uint16 consumeBps_) external {
        consumeBps = consumeBps_;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        uint256 consumed = params.amountIn * consumeBps / 10_000;
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), consumed);
        amountOut = quote;
        require(amountOut >= params.amountOutMinimum, "Too little received");
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }
}

contract StockZapMockV4 is IV4PoolManager, IV4StateView {
    uint160 public sqrtPrice = 1 << 96;
    uint128 public liquidity = 1e18;
    uint24 public lpFee = 3000;
    uint256 public quote = 1e18;
    uint256 public paidOverride;
    bool public lastZeroForOne;

    function setQuote(uint256 quote_) external {
        quote = quote_;
    }

    function setPaidOverride(uint256 paidOverride_) external {
        paidOverride = paidOverride_;
    }

    function poolManager() external view returns (address) {
        return address(this);
    }

    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) {
        return (sqrtPrice, 0, 0, lpFee);
    }

    function getLiquidity(bytes32) external view returns (uint128) {
        return liquidity;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IStockZapUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(V4PoolKey memory, V4SwapParams memory params, bytes calldata) external returns (int256 swapDelta) {
        lastZeroForOne = params.zeroForOne;
        uint256 requested = uint256(-params.amountSpecified);
        uint256 paid = paidOverride == 0 ? requested : paidOverride;
        uint256 taken = quote;
        if (params.zeroForOne) {
            uint256 zeroForOneAmount0 = uint256(uint128(int128(-int256(paid))));
            uint256 zeroForOneAmount1 = uint256(uint128(taken));
            return int256((zeroForOneAmount0 << 128) | zeroForOneAmount1);
        }
        uint256 oneForZeroAmount0 = uint256(uint128(taken));
        uint256 oneForZeroAmount1 = uint256(uint128(int128(-int256(paid))));
        return int256((oneForZeroAmount0 << 128) | oneForZeroAmount1);
    }

    function sync(address) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(address currency, address to, uint256 amount) external {
        IERC20(currency).transfer(to, amount);
    }
}

contract StockZapTest is V8AccessTest {
    uint256 internal constant USDG_IN = 100e6;
    uint24 internal constant V3_FEE = 500;
    uint24 internal constant V4_FEE = 3000;
    int24 internal constant V4_TICK_SPACING = 60;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal user = makeAddr("user");
    address internal beneficiary = makeAddr("beneficiary");
    address internal treasury = makeAddr("treasury");

    MockERC20 internal usdg;
    MockStockToken internal stockAbove;
    MockStockToken internal stockBelow;
    MockStockToken internal unrouted;
    StockZapMockV3Factory internal v3Factory;
    StockZapMockV3Router internal v3Router;
    StockZapMockV4 internal v4;
    PayoutRouter internal router;
    ExpiryCalendar internal calendar;
    MockSettlementOracle internal oracle;
    Clearinghouse internal clearinghouse;
    StockZap internal zap;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 6);
        stockAbove = _orderedStock(true, 1);
        stockBelow = _orderedStock(false, 10_000);
        unrouted = new MockStockToken("Unrouted Stock", "NONE");

        v3Factory = new StockZapMockV3Factory();
        v3Router = new StockZapMockV3Router(address(v3Factory));
        v4 = new StockZapMockV4();
        router = new PayoutRouter(address(_manager()), address(usdg), address(v3Router), address(v4), address(v4));
        _wire(address(router), "PayoutRouter", admin, 0);
        _grant(V8Roles.GUARDIAN, guardian, 0);

        calendar = _newCalendar(new uint32[](0), admin);
        oracle = new MockSettlementOracle();
        clearinghouse = _newClearinghouse(address(usdg), address(calendar), treasury, "", admin);
        vm.startPrank(admin);
        clearinghouse.setDefaultOracle(address(oracle));
        clearinghouse.setDefaultMarketFees(0, 0);
        clearinghouse.registerMarket(address(stockAbove), 100, true);
        clearinghouse.registerMarket(address(stockBelow), 100, true);
        clearinghouse.registerMarket(address(unrouted), 100, true);
        router.setRouteV4(address(stockAbove), V4_FEE, V4_TICK_SPACING);
        router.setRouteV4(address(stockBelow), V4_FEE, V4_TICK_SPACING);
        vm.stopPrank();

        v3Factory.setPool(address(stockAbove), address(usdg), V3_FEE, address(0xBEEF));
        v3Factory.setPool(address(stockBelow), address(usdg), V3_FEE, address(0xCAFE));
        zap = new StockZap(address(router), address(clearinghouse));

        usdg.mint(user, 10_000e6);
        usdg.mint(address(v3Router), 10_000e6);
        usdg.mint(address(v4), 10_000e6);
        stockAbove.mint(user, 100e18);
        stockBelow.mint(user, 100e18);
        stockAbove.mint(address(v3Router), 1_000e18);
        stockBelow.mint(address(v3Router), 1_000e18);
        stockAbove.mint(address(v4), 1_000e18);
        stockBelow.mint(address(v4), 1_000e18);

        vm.startPrank(user);
        usdg.approve(address(zap), type(uint256).max);
        stockAbove.approve(address(zap), type(uint256).max);
        stockBelow.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    function test_writeZap_noRouteRevertsUnsupportedAsset() public {
        vm.prank(user);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        zap.writeZap(address(unrouted), USDG_IN, 1, beneficiary, type(uint40).max);
    }

    function test_writeZap_guardianClearedRouteRevertsUnsupportedAsset() public {
        vm.prank(guardian);
        router.clearRoute(address(stockAbove));

        vm.prank(user);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        zap.writeZap(address(stockAbove), USDG_IN, 1, beneficiary, type(uint40).max);
    }

    function test_writeZap_assetOutBelowMinimumRevertsBadPrice() public {
        v4.setQuote(1e18);
        vm.prank(user);
        vm.expectRevert(V2Errors.BadPrice.selector);
        zap.writeZap(address(stockAbove), USDG_IN, 1e18 + 1, beneficiary, type(uint40).max);
    }

    function test_writeZap_v4PartialFillRevertsBadUnits() public {
        v4.setPaidOverride(USDG_IN - 1);
        vm.prank(user);
        vm.expectRevert(V2Errors.BadUnits.selector);
        zap.writeZap(address(stockAbove), USDG_IN, 1, beneficiary, type(uint40).max);
    }

    function test_bothFunctions_refuseExpiredDeadline() public {
        vm.warp(100);
        vm.prank(user);
        vm.expectRevert(V2Errors.DeadlinePassed.selector);
        zap.writeZap(address(stockAbove), USDG_IN, 1, beneficiary, 99);

        vm.prank(user);
        vm.expectRevert(V2Errors.DeadlinePassed.selector);
        zap.exitZap(address(stockAbove), 1e18, 1, beneficiary, 99);
    }

    function test_writeZap_refusesZeroAndSelfRecipients() public {
        vm.prank(user);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        zap.writeZap(address(stockAbove), USDG_IN, 1, address(0), type(uint40).max);

        vm.prank(user);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        zap.writeZap(address(stockAbove), USDG_IN, 1, address(zap), type(uint40).max);
    }

    function test_bothFunctions_refuseZeroAmountsAndFloors() public {
        vm.startPrank(user);
        vm.expectRevert(V2Errors.BadUnits.selector);
        zap.writeZap(address(stockAbove), 0, 1, beneficiary, type(uint40).max);
        vm.expectRevert(V2Errors.BadPrice.selector);
        zap.writeZap(address(stockAbove), USDG_IN, 0, beneficiary, type(uint40).max);
        vm.expectRevert(V2Errors.BadUnits.selector);
        zap.exitZap(address(stockAbove), 0, 1, beneficiary, type(uint40).max);
        vm.expectRevert(V2Errors.BadPrice.selector);
        zap.exitZap(address(stockAbove), 1e18, 0, beneficiary, type(uint40).max);
        vm.stopPrank();
    }

    function test_writeZap_preservesBothPredonatedBalancesAndCreditsOnlyTo() public {
        uint256 donatedUsdg = 7e6;
        uint256 donatedStock = 3e18;
        uint256 bought = 2e18;
        usdg.mint(address(zap), donatedUsdg);
        stockAbove.mint(address(zap), donatedStock);
        v4.setQuote(bought);

        vm.expectEmit(true, true, false, true, address(zap));
        emit IStockZap.WriteZapped(
            beneficiary, address(stockAbove), user, USDG_IN, bought, uint8(IPayoutRouter.Venue.V4)
        );
        vm.prank(user);
        uint256 out = zap.writeZap(address(stockAbove), USDG_IN, bought, beneficiary, type(uint40).max);

        assertEq(out, bought);
        assertEq(clearinghouse.free(beneficiary, address(stockAbove)), bought, "recipient ledger credited");
        assertEq(clearinghouse.free(user, address(stockAbove)), 0, "caller ledger untouched");
        assertEq(usdg.balanceOf(address(zap)), donatedUsdg, "pre-donated USDG preserved");
        assertEq(stockAbove.balanceOf(address(zap)), donatedStock, "pre-donated stock preserved");
    }

    function test_writeZap_v4DerivesDirectionForBothTokenOrderings() public {
        assertTrue(address(stockAbove) > address(usdg), "fixture above USDG");
        assertTrue(address(stockBelow) < address(usdg), "fixture below USDG");

        v4.setQuote(1e18);
        vm.prank(user);
        zap.writeZap(address(stockAbove), USDG_IN, 1e18, beneficiary, type(uint40).max);
        assertTrue(v4.lastZeroForOne(), "USDG is currency0 when stock sorts above it");

        vm.prank(user);
        zap.writeZap(address(stockBelow), USDG_IN, 1e18, beneficiary, type(uint40).max);
        assertFalse(v4.lastZeroForOne(), "USDG is currency1 when stock sorts below it");
        assertEq(clearinghouse.free(beneficiary, address(stockAbove)), 1e18);
        assertEq(clearinghouse.free(beneficiary, address(stockBelow)), 1e18);
    }

    function test_writeZap_v3ClearsRouterAllowance() public {
        vm.prank(admin);
        router.setRouteV3(address(stockAbove), V3_FEE);
        v3Router.setQuote(4e18);

        vm.prank(user);
        uint256 out = zap.writeZap(address(stockAbove), USDG_IN, 4e18, beneficiary, type(uint40).max);

        assertEq(out, 4e18);
        assertEq(usdg.allowance(address(zap), address(v3Router)), 0, "no v3 allowance survives");
        assertEq(clearinghouse.free(beneficiary, address(stockAbove)), 4e18);
    }

    function test_writeZap_closingBalanceGuardCatchesPartialV3ConsumptionWithDonations() public {
        vm.prank(admin);
        router.setRouteV3(address(stockAbove), V3_FEE);
        usdg.mint(address(zap), 5e6);
        stockAbove.mint(address(zap), 2e18);
        v3Router.setQuote(1e18);
        v3Router.setConsumeBps(5_000);

        vm.prank(user);
        vm.expectRevert(V2Errors.BadUnits.selector);
        zap.writeZap(address(stockAbove), USDG_IN, 1e18, beneficiary, type(uint40).max);
    }

    function test_exitZap_delegatesToRouterAndPaysRecipient() public {
        uint256 assetIn = 2e18;
        uint256 usdgOut = 25e6;
        uint256 before = usdg.balanceOf(beneficiary);
        v4.setQuote(usdgOut);

        vm.expectEmit(true, true, false, true, address(zap));
        emit IStockZap.ExitZapped(
            beneficiary, address(stockAbove), user, assetIn, usdgOut, uint8(IPayoutRouter.Venue.V4)
        );
        vm.prank(user);
        uint256 out = zap.exitZap(address(stockAbove), assetIn, usdgOut, beneficiary, type(uint40).max);

        assertEq(out, usdgOut);
        assertEq(usdg.balanceOf(beneficiary) - before, usdgOut);
        assertEq(stockAbove.balanceOf(address(zap)), 0);
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(stockAbove.allowance(address(zap), address(router)), 0, "router consumed the exact approval");
    }

    function test_constructorRejectsCodelessArgumentsAndMismatchedUsdg() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new StockZap(makeAddr("no router"), address(clearinghouse));
        vm.expectRevert(V2Errors.NoSource.selector);
        new StockZap(address(router), makeAddr("no clearinghouse"));

        MockERC20 otherUsdg = new MockERC20("Other", "OTHER", 6);
        Clearinghouse other = _newClearinghouse(address(otherUsdg), address(calendar), treasury, "", admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new StockZap(address(router), address(other));
    }

    function _manager() internal returns (address) {
        _deployManager();
        return address(manager);
    }

    function _orderedStock(bool above, uint256 saltBase) internal returns (MockStockToken token) {
        for (uint256 i; i < 256; ++i) {
            token = new MockStockToken{salt: bytes32(saltBase + i)}(
                above ? "Above USDG" : "Below USDG", above ? "ABOVE" : "BELOW"
            );
            if ((address(token) > address(usdg)) == above) return token;
        }
        revert("could not construct requested token ordering");
    }
}
