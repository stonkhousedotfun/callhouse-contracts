// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {Policy, PolicyParams} from "../src/Policy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockFeed} from "../src/mocks/MockFeed.sol";
import {MockClear} from "../src/mocks/MockClear.sol";
import {MockRegistry} from "../src/mocks/MockRegistry.sol";
import {MockSeaport} from "../src/mocks/MockSeaport.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";
import {IOvercallRegistry} from "../src/interfaces/IOvercallRegistry.sol";
import {IChainlinkFeed} from "../src/interfaces/IChainlinkFeed.sol";
import {
    ISeaport,
    OrderComponents,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType
} from "../src/interfaces/ISeaport.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared fixture for the Callhouse unit tests.
/// @dev The numbers here mirror the live NVDA market recon found on chain 4663 on 2026-09-12:
///      lot size 1e18, a five-rung ladder at 226/231/236/241/246 USDG, book close Friday
///      20:00 UTC and expiry Saturday 20:00 UTC, exactly 24h apart. Spot is set to $220 so the
///      226 rung sits just BELOW the 3% floor and the 246 rung just above the 12% ceiling,
///      which makes both band edges testable with real-shaped inputs.
abstract contract BaseTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal feeSafe = makeAddr("feeSafe");
    address internal overcallFee = 0xdAe7e82A2E7D566C67E87C164B05a1C560190782;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal buyer = makeAddr("buyer");

    /*//////////////////////////////////////////////////////////////
                               CONTRACTS
    //////////////////////////////////////////////////////////////*/

    MockStockToken internal nvda;
    MockERC20 internal usdg;
    MockClear internal clear;
    MockRegistry internal registry;
    MockSeaport internal seaport;
    MockFeed internal feed;
    Vault internal vault;

    /*//////////////////////////////////////////////////////////////
                              CYCLE FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @dev $220.00 spot, expressed in USDG base units (6 dp).
    uint256 internal constant SPOT_USDG = 220_000_000;
    /// @dev Same spot at the feed's 8 decimals.
    int256 internal constant SPOT_FEED = 220_00000000;

    uint40 internal exerciseTs;
    uint40 internal expiryTs;

    uint256[] internal optionIds;
    uint96[] internal strikes;

    /// @dev Index into `optionIds` for the nearest rung inside the launch OTM band.
    ///      Spot 220 gives a band of [226.60, 246.40], so 226 is out, 231 is the pick.
    uint256 internal constant RUNG_BELOW_BAND = 0; // 226.00
    uint256 internal constant RUNG_PICK = 1; // 231.00
    uint256 internal constant RUNG_MID = 2; // 236.00
    uint256 internal constant RUNG_ABOVE_BAND = 4; // 246.00

    uint256 internal constant LOT = 1e18;
    uint256 internal constant DEPOSIT_CAP = 50e18;
    uint32 internal constant MAX_PRICE_AGE = 6 hours;

    function setUp() public virtual {
        // Start at a realistic timestamp so 40-bit timestamps behave.
        vm.warp(1_789_000_000);

        nvda = new MockStockToken("NVDA Stock Token", "NVDAx");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        clear = new MockClear();
        registry = new MockRegistry(address(nvda), address(usdg), address(clear));
        seaport = new MockSeaport();
        feed = new MockFeed(8, SPOT_FEED, "NVDA / USD");

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);

        _installCycle();

        vault = new Vault(
            Vault.Config({
                asset: IERC20(address(nvda)),
                usdg: IERC20(address(usdg)),
                clear: IValoremClear(address(clear)),
                seaport: ISeaport(address(seaport)),
                registry: IOvercallRegistry(address(registry)),
                priceFeed: IChainlinkFeed(address(feed)),
                maxPriceAge: MAX_PRICE_AGE,
                overcallFeeRecipient: overcallFee,
                conduitKey: bytes32(0),
                seaportZone: address(0),
                admin: admin,
                feeRecipient: feeSafe,
                depositCap: DEPOSIT_CAP,
                name: "Callhouse NVDA",
                symbol: "cNVDA"
            })
        );

        vm.startPrank(admin);
        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();

        _fund(alice, 30e18, 0);
        _fund(bob, 30e18, 0);
        _fund(carol, 30e18, 0);
        _fund(buyer, 0, 5_000_000_000); // $5,000 USDG
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Create the five Valorem option types and register them as this week's cycle.
    function _installCycle() internal {
        delete optionIds;
        delete strikes;

        uint96[5] memory s = [uint96(226_000_000), 231_000_000, 236_000_000, 241_000_000, 246_000_000];
        for (uint256 i; i < 5; i++) {
            uint256 id = clear.newOptionType(address(nvda), uint96(LOT), address(usdg), s[i], exerciseTs, expiryTs);
            optionIds.push(id);
            strikes.push(s[i]);
        }
        registry.setCycleWithStrikes(optionIds, strikes, exerciseTs, expiryTs);
    }

    function _fund(address who, uint256 nvdaAmount, uint256 usdgAmount) internal {
        if (nvdaAmount != 0) nvda.mint(who, nvdaAmount);
        if (usdgAmount != 0) usdg.mint(who, usdgAmount);
    }

    /// @dev Deposit as `who` and return the shares minted.
    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        nvda.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Write `n` contracts against the nearest in-band rung.
    function _rollOpen(uint112 n) internal returns (uint256 optionId) {
        optionId = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vault.rollOpen(optionId, n);
    }

    /// @dev Build an order in exactly the shape Overcall publishes.
    ///      zone 0, zoneHash 0, conduitKey 0, orderType PARTIAL_OPEN, startTime 0, endTime =
    ///      the cycle's exercise timestamp, and the 5% fee rounded PER CONTRACT.
    function _buildOrder(uint256 optionId, uint256 contractsCount, uint256 unitPriceUsdg)
        internal
        view
        returns (OrderComponents memory c)
    {
        (uint256 toVault, uint256 toOvercall,) = _splitPremium(unitPriceUsdg, contractsCount);

        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155,
            token: address(clear),
            identifierOrCriteria: optionId,
            startAmount: contractsCount,
            endAmount: contractsCount
        });

        ConsiderationItem[] memory consid = new ConsiderationItem[](2);
        consid[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(usdg),
            identifierOrCriteria: 0,
            startAmount: toVault,
            endAmount: toVault,
            recipient: payable(address(vault))
        });
        consid[1] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(usdg),
            identifierOrCriteria: 0,
            startAmount: toOvercall,
            endAmount: toOvercall,
            recipient: payable(overcallFee)
        });

        c = OrderComponents({
            offerer: address(vault),
            zone: address(0),
            offer: offer,
            consideration: consid,
            orderType: OrderType.PARTIAL_OPEN,
            startTime: 0,
            endTime: exerciseTs,
            zoneHash: bytes32(0),
            salt: 0x1234,
            conduitKey: bytes32(0),
            counter: seaport.getCounter(address(vault))
        });
    }

    /// @dev The exact rounding Overcall's client uses: floor the fee PER CONTRACT, then
    ///      multiply. Rounding on the total makes the order unfillable in fractions.
    function _splitPremium(uint256 unitPriceUsdg, uint256 contractsCount)
        internal
        pure
        returns (uint256 toVault, uint256 toOvercall, uint256 gross)
    {
        uint256 feePerContract = (unitPriceUsdg * 500) / 10_000;
        toOvercall = feePerContract * contractsCount;
        toVault = (unitPriceUsdg - feePerContract) * contractsCount;
        gross = unitPriceUsdg * contractsCount;
    }

    /// @dev A unit price comfortably above the policy floor (0.40% of spot = $0.88).
    function _okUnitPrice() internal pure returns (uint256) {
        return 2_000_000; // $2.00 per contract
    }

    function _approveListing(uint256 optionId, uint256 contractsCount, uint256 unitPriceUsdg)
        internal
        returns (OrderComponents memory c)
    {
        c = _buildOrder(optionId, contractsCount, unitPriceUsdg);
        vm.prank(keeper);
        vault.approveListing(c);
    }

    /// @dev Fill `fillAmount` of a live order as the buyer.
    function _fill(OrderComponents memory c, uint256 fillAmount) internal {
        vm.startPrank(buyer);
        usdg.approve(address(seaport), type(uint256).max);
        seaport.fulfil(c, fillAmount);
        vm.stopPrank();
    }

    /// @dev Exercise `n` contracts as the buyer, during the exercise window.
    function _exercise(uint256 optionId, uint112 n) internal {
        vm.startPrank(buyer);
        usdg.approve(address(clear), type(uint256).max);
        clear.exercise(optionId, n);
        vm.stopPrank();
    }

    function _warpToExercise() internal {
        vm.warp(exerciseTs);
    }

    function _warpToExpiry() internal {
        vm.warp(expiryTs);
    }

    function _rollClose() internal {
        vm.prank(keeper);
        vault.rollClose();
    }

    /// @dev Run one clean cycle: open, list, fill, expire out of the money, close.
    function _fullCycleOtm(uint112 n, uint256 unitPrice) internal returns (uint256 grossPremium) {
        uint256 optionId = _rollOpen(n);
        OrderComponents memory c = _approveListing(optionId, n, unitPrice);
        _fill(c, n);
        (,, grossPremium) = _splitPremium(unitPrice, n);
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    function _phase() internal view returns (uint8) {
        return uint8(vault.phase());
    }
}
