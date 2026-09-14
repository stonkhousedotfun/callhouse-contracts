// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {Policy, PolicyParams} from "../src/Policy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockFeed} from "../src/mocks/MockFeed.sol";
import {MockClear} from "../src/mocks/MockClear.sol";
import {MockSeaport} from "../src/mocks/MockSeaport.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";
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
///
///      NO REGISTRY. The vault validates option types from the clearinghouse alone, so the fixture
///      creates the five weekly types directly on Clear (mock or real) with our own tuple and
///      hands the vault whichever id a test wants to arm.
///
///      WRITE ON FILL. `_rollOpen()` ARMS a type and writes nothing; `_approveListing` lists up
///      to capacity; every `_fill` writes exactly what it sells inside the vault's zone hook.
///      `_openAndSell(n)` chains the three for the many tests that want "n written and sold".
abstract contract BaseTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal feeSafe = makeAddr("feeSafe");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal buyer = makeAddr("buyer");

    /*//////////////////////////////////////////////////////////////
                               CONTRACTS
    //////////////////////////////////////////////////////////////*/

    MockStockToken internal nvda;
    MockERC20 internal usdg;
    /// @dev The clearinghouse the vault is wired to. {MockClear} by default; a suite that needs the
    ///      real Valorem bytecode overrides {_deployClear} (see test/helpers/RealClearBase.sol) and
    ///      every helper below keeps working because none of them needs a mock-only function.
    IValoremClear internal clear;
    /// @dev The same address as {clear} when the mock is in use, typed for the mock-only test
    ///      helpers (`setFeesEnabled`, `setFeeBps`, bucket views). Zero under the real bytecode.
    MockClear internal mockClear;
    /// @dev The Seaport the vault is wired to. {MockSeaport} by default (with the verified 1.6 hook
    ///      order); a suite that needs the genuine fulfilment paths overrides {_deploySeaport} (see
    ///      test/helpers/RealSeaportBase.sol) and {_fill}.
    ISeaport internal seaport;
    /// @dev The same address as {seaport} when the mock is in use, typed for the mock-only helpers
    ///      (`fulfil`, `validated`, `cancelled`, `filled`). Zero under the real bytecode.
    MockSeaport internal mockSeaport;
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
        clear = _deployClear();
        seaport = _deploySeaport();
        feed = new MockFeed(8, SPOT_FEED, "NVDA / USD");

        // Fund BEFORE creating option types: Valorem's `newOptionType` (real and mock alike) requires
        // `totalSupply(underlying) >= underlyingAmount` and `totalSupply(exercise) >= exerciseAmount`.
        _fund(alice, 30e18, 0);
        _fund(bob, 30e18, 0);
        _fund(carol, 30e18, 0);
        _fund(buyer, 0, 5_000_000_000); // $5,000 USDG

        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);

        _installCycle();

        vault = new Vault(
            Vault.Config({
                asset: IERC20(address(nvda)),
                usdg: IERC20(address(usdg)),
                clear: IValoremClear(address(clear)),
                seaport: ISeaport(address(seaport)),
                priceFeed: IChainlinkFeed(address(feed)),
                maxPriceAge: MAX_PRICE_AGE,
                conduitKey: bytes32(0),
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
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The clearinghouse to wire the vault to. The default is the bucket-faithful {MockClear};
    ///      override to return the real Valorem bytecode (test/helpers/RealClearBase.sol).
    function _deployClear() internal virtual returns (IValoremClear) {
        mockClear = new MockClear();
        return IValoremClear(address(mockClear));
    }

    /// @dev The Seaport to wire the vault to. The default is the hook-faithful {MockSeaport}; override to
    ///      etch the real 1.6 runtime (test/helpers/RealSeaportBase.sol), and override {_fill} with it.
    function _deploySeaport() internal virtual returns (ISeaport) {
        mockSeaport = new MockSeaport();
        return ISeaport(address(mockSeaport));
    }

    /// @dev Create this week's five option types on the clearinghouse, as the keeper would.
    function _installCycle() internal {
        delete optionIds;
        delete strikes;

        uint96[5] memory s = [uint96(226_000_000), 231_000_000, 236_000_000, 241_000_000, 246_000_000];
        for (uint256 i; i < 5; i++) {
            uint256 id = clear.newOptionType(address(nvda), uint96(LOT), address(usdg), s[i], exerciseTs, expiryTs);
            optionIds.push(id);
            strikes.push(s[i]);
        }
    }

    /// @dev Roll the fixture forward to a fresh week from now: new types, and a re-stamped feed. A
    ///      week has passed since the fixture published the price and the vault's staleness gate
    ///      would refuse the arm against a frozen `updatedAt`; a live feed keeps ticking.
    function _nextWeek() internal {
        exerciseTs = uint40(block.timestamp + 6 days);
        expiryTs = uint40(block.timestamp + 7 days);
        _installCycle();
        feed.setAnswer(SPOT_FEED);
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

    /// @dev ARM the nearest in-band rung. Nothing is written until a fill.
    function _rollOpen() internal returns (uint256 optionId) {
        optionId = optionIds[RUNG_PICK];
        vm.prank(keeper);
        vault.rollOpen(optionId);
    }

    /// @dev Build an order in exactly the shape the vault authorises under write-on-fill:
    ///      offerer AND zone the vault, PARTIAL_RESTRICTED, zoneHash 0, conduitKey 0, startTime 0,
    ///      endTime = the cycle's exercise timestamp, ONE consideration item of `unit x n` USDG to
    ///      the vault.
    function _buildOrder(uint256 optionId, uint256 contractsCount, uint256 unitPriceUsdg)
        internal
        view
        returns (OrderComponents memory c)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155,
            token: address(clear),
            identifierOrCriteria: optionId,
            startAmount: contractsCount,
            endAmount: contractsCount
        });

        ConsiderationItem[] memory consid = new ConsiderationItem[](1);
        uint256 gross = unitPriceUsdg * contractsCount;
        consid[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(usdg),
            identifierOrCriteria: 0,
            startAmount: gross,
            endAmount: gross,
            recipient: payable(address(vault))
        });

        c = OrderComponents({
            offerer: address(vault),
            zone: address(vault),
            offer: offer,
            consideration: consid,
            orderType: OrderType.PARTIAL_RESTRICTED,
            startTime: 0,
            endTime: exerciseTs,
            zoneHash: bytes32(0),
            salt: 0x1234,
            conduitKey: bytes32(0),
            counter: seaport.getCounter(address(vault))
        });
    }

    /// @dev A unit price comfortably above the policy floor (0.40% of spot = $0.88). $1.90 is what
    ///      the vault netted per contract under the old two-item order at $2.00, so every
    ///      hand-checked USDG figure in the suites (19 USDG per ten contracts, a 0.95 fee, 18.05
    ///      net) is unchanged; only the buyer's outlay is.
    function _okUnitPrice() internal pure returns (uint256) {
        return 1_900_000;
    }

    function _approveListing(uint256 optionId, uint256 contractsCount, uint256 unitPriceUsdg)
        internal
        returns (OrderComponents memory c)
    {
        c = _buildOrder(optionId, contractsCount, unitPriceUsdg);
        vm.prank(keeper);
        vault.approveListing(c);
    }

    /// @dev Fill `fillAmount` of a live order as the buyer. The vault's `authorizeOrder` writes
    ///      exactly `fillAmount` inside the call. Virtual so a real-Seaport suite can route the same
    ///      fill through `fulfillAdvancedOrder`.
    function _fill(OrderComponents memory c, uint256 fillAmount) internal virtual {
        vm.startPrank(buyer);
        usdg.approve(address(seaport), type(uint256).max);
        mockSeaport.fulfil(c, fillAmount);
        vm.stopPrank();
    }

    /// @dev Arm, list `n` at `unitPrice`, and sell all `n`: the vault ends Listed with `n` written
    ///      and sold and `unitPrice x n` of premium banked.
    function _openAndSell(uint112 n, uint256 unitPrice) internal returns (uint256 optionId, OrderComponents memory c) {
        optionId = _rollOpen();
        c = _approveListing(optionId, n, unitPrice);
        _fill(c, n);
    }

    function _openAndSell(uint112 n) internal returns (uint256 optionId, OrderComponents memory c) {
        return _openAndSell(n, _okUnitPrice());
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

    /// @dev Run one clean cycle: arm, list, fill, expire out of the money, close.
    function _fullCycleOtm(uint112 n, uint256 unitPrice) internal returns (uint256 grossPremium) {
        _openAndSell(n, unitPrice);
        grossPremium = unitPrice * n;
        _warpToExercise();
        vault.lockBook();
        _warpToExpiry();
        _rollClose();
    }

    function _phase() internal view returns (uint8) {
        return uint8(vault.phase());
    }
}
