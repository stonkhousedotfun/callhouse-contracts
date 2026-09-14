// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {
    ISeaport,
    IZone,
    OrderComponents,
    OrderParameters,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType
} from "../../src/interfaces/ISeaport.sol";
import {AdvancedOrder, CriteriaResolver, ISeaportFulfil} from "../helpers/RealSeaportBase.sol";

/// @notice Fork tests against the real Robinhood Chain 4663 deployment.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC -vv
///      These are the tests that catch a wrong assumption about somebody else's contract, which
///      is the class of bug mocks cannot find. Under write on fill the assumptions that matter
///      are Seaport 1.6's hook order (authorizeOrder before any transfer, on the LIVE runtime),
///      transient storage on chain 4663 (the fill baseline is TSTORE'd), and Valorem's `write`
///      minting to `msg.sender` inside that hook.
///
///      NO REGISTRY. The vault validates option types from the clearinghouse alone, and
///      `newOptionType` is permissionless, so these tests create their own weekly type on the live
///      Clear rather than depending on Overcall having published one.
contract ForkLiveTest is Test {
    address constant CLEAR = 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant CONDUIT_CONTROLLER = 0x00000000F9490004C11Cef243f5400493c00Ad63;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    /// @dev Pinned in test/helpers/RealSeaportBase.sol and script/Verify.s.sol; asserted live here.
    bytes32 constant SEAPORT_16_RUNTIME_HASH = 0x95809b70c9659c30188db5fdd87103e24b1a55379af8c851fca393aba0224a00;

    IValoremClear clear = IValoremClear(CLEAR);
    ISeaport seaport = ISeaport(SEAPORT);
    ISeaportFulfil seaportFulfil = ISeaportFulfil(SEAPORT);

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address feeSafe = makeAddr("feeSafe");
    address alice = makeAddr("alice");
    address buyer = makeAddr("buyer");

    Vault vault;

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        vault = _deployVault();
    }

    function _deployVault() internal returns (Vault v) {
        v = new Vault(
            Vault.Config({
                asset: IERC20(NVDA),
                usdg: IERC20(USDG),
                clear: IValoremClear(CLEAR),
                seaport: ISeaport(SEAPORT),
                priceFeed: IChainlinkFeed(FEED),
                maxPriceAge: 4 days,
                conduitKey: bytes32(0),
                admin: admin,
                feeRecipient: feeSafe,
                depositCap: 50e18,
                name: "Callhouse NVDA",
                symbol: "cNVDA"
            })
        );
        vm.startPrank(admin);
        v.grantRole(v.KEEPER_ROLE(), keeper);
        v.grantRole(v.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      THE ADDRESSES ARE WHAT WE THINK
    //////////////////////////////////////////////////////////////*/

    function test_fork_everythingHasCode() public onlyFork {
        assertGt(CLEAR.code.length, 0, "Valorem Clear");
        assertGt(SEAPORT.code.length, 0, "Seaport 1.6");
        assertGt(CONDUIT_CONTROLLER.code.length, 0, "ConduitController");
        assertGt(USDG.code.length, 0, "USDG");
        assertGt(NVDA.code.length, 0, "NVDA Stock Token");
        assertGt(MULTICALL3.code.length, 0, "Multicall3");
        assertGt(FEED.code.length, 0, "Chainlink NVDA/USD");
    }

    /// @dev The zone hooks are a Seaport 1.6 feature, and their ordering (authorize before any
    ///      transfer, validate after all of them, on every fulfilment path) was verified against
    ///      THIS runtime (integrations/seaport.md). Pin the bytes, not only the version string.
    function test_fork_seaportIsTheVerified16Runtime() public onlyFork {
        (string memory version,, address conduitController) = seaport.information();
        assertEq(version, "1.6", "must be Seaport 1.6, not 1.5");
        assertEq(conduitController, CONDUIT_CONTROLLER, "canonical ConduitController");
        assertEq(SEAPORT.codehash, SEAPORT_16_RUNTIME_HASH, "the live runtime is the one the fixtures and Verify pin");
        assertEq(SEAPORT.code.length, 23_981, "23,981 B on 4663");
    }

    function test_fork_tokenDecimals() public onlyFork {
        assertEq(IStockToken(NVDA).decimals(), 18, "Stock Tokens are 18 decimals");
        assertEq(IStockToken(USDG).decimals(), 6, "USDG is 6 decimals");
    }

    /*//////////////////////////////////////////////////////////////
                          VALOREM ASSUMPTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev The engine fee being off is what makes weekly OTM premium worth collecting. If this
    ///      ever fails on mainnet, the vault refuses to arm until governance accepts it.
    function test_fork_valoremFeeSwitch() public onlyFork {
        bool on = clear.feesEnabled();
        console2.log("feesEnabled", on);
        console2.log("feeBps     ", clear.feeBps());
        console2.log("feeTo      ", clear.feeTo());
        assertEq(clear.feeBps(), 15, "feeBps is a compile-time 15");
        assertFalse(on, "Valorem engine fee is expected OFF");
    }

    function test_fork_clearIsErc1155() public onlyFork {
        assertTrue(clear.supportsInterface(0xd9b67a26), "ERC-1155");
    }

    /// @dev `newOptionType` is permissionless and the settlement seed is the option key: the two
    ///      facts the vault's arm gate and the write-on-fill design rest on, checked live.
    function test_fork_anyoneCanCreateAnOptionTypeAndTheSeedIsTheKey() public onlyFork {
        (uint256 id,,,) = _ourOptionType(7);
        assertEq(uint8(clear.tokenType(id)), uint8(IValoremClear.TokenType.Option), "an Option id");
        IValoremClear.Option memory o = clear.option(id);
        assertEq(o.underlyingAsset, NVDA);
        assertEq(o.exerciseAsset, USDG);
        assertEq(o.underlyingAmount, 1e18);
        assertEq(o.settlementSeed, uint160(id >> 96), "settlementSeed == optionKey, fixed for ever");
    }

    /*//////////////////////////////////////////////////////////////
                              THE FEED
    //////////////////////////////////////////////////////////////*/

    /// @dev The NVDA feed is a `us_equities_24/5` feed: it stops when the market closes, and
    ///      observed gaps run to ~78h over a holiday weekend. This test documents the live age
    ///      rather than asserting freshness, and asserts only that our 4-day window accommodates
    ///      the market being shut.
    function test_fork_feedLivenessAndAge() public onlyFork {
        IChainlinkFeed f = IChainlinkFeed(FEED);
        (, int256 answer,, uint256 updatedAt,) = f.latestRoundData();
        assertGt(answer, 0, "positive price");
        assertEq(f.decimals(), 8, "8 decimals");

        uint256 age = block.timestamp - updatedAt;
        console2.log("description", f.description());
        console2.log("answer 8dp ", uint256(answer));
        console2.log("age seconds", age);
        console2.log("spot USDG  ", Policy.normalizeSpot(answer, f.decimals()));

        assertLt(age, 7 days, "even a long holiday weekend fits inside the hard ceiling");
    }

    function test_fork_spotNormalisesToUsdgUnits() public onlyFork {
        (, int256 answer,,,) = IChainlinkFeed(FEED).latestRoundData();
        uint256 spot = Policy.normalizeSpot(answer, 8);
        // NVDA has traded in the low hundreds; this is a sanity band, not a price assertion.
        assertGt(spot, 1_000_000, "more than $1");
        assertLt(spot, 10_000_000_000, "less than $10,000");
    }

    /*//////////////////////////////////////////////////////////////
                        THE VAULT AGAINST REALITY
    //////////////////////////////////////////////////////////////*/

    function test_fork_vaultDeploysAndReadsSpot() public onlyFork {
        assertEq(address(vault.asset()), NVDA);
        assertEq(address(vault.clear()), CLEAR);
        assertEq(vault.seaportZone(), address(vault), "the vault is its own zone");
        assertEq(vault.maxPriceAge(), 4 days);
        assertEq(uint8(vault.phase()), 0, "starts Idle");
        assertTrue(clear.isApprovedForAll(address(vault), SEAPORT), "Seaport may pull the option tokens");
        assertTrue(vault.supportsInterface(type(IZone).interfaceId), "advertises the zone interface");

        uint256 spot = vault.spotUsdg();
        assertGt(spot, 0, "vault can read spot through the real feed");
        console2.log("vault spotUsdg", spot);
    }

    /// @dev Seaport must accept the vault as an offerer and hash our exact order shape.
    function test_fork_seaportHashesOurOrderShape() public onlyFork {
        (uint256 id,, uint40 exTs,) = _ourOptionType(11);
        OrderComponents memory o = _order(id, 1, 2_000_000, exTs);
        bytes32 h = seaport.getOrderHash(o);
        assertTrue(h != bytes32(0), "real Seaport produced a hash for our shape");

        (bool validated, bool cancelledFlag, uint256 filled, uint256 sz) = seaport.getOrderStatus(h);
        assertFalse(validated);
        assertFalse(cancelledFlag);
        assertEq(filled, 0);
        assertEq(sz, 0);

        assertEq(seaport.getCounter(address(vault)), 0, "a fresh vault starts at counter 0");
    }

    /// @dev Bumping the counter is the guardian's no-data kill switch. Prove it works against the
    ///      real Seaport, since it is the path used when the keeper is gone.
    ///
    ///      NOTE FOR THE KEEPER: Seaport does NOT increment by one. It jumps by a quasi-random
    ///      amount so the next counter cannot be predicted and orders pre-signed against it
    ///      cannot be queued up. Observed here: 0 -> 645105783290196256915466989660461880.
    ///      Anything that builds an order must therefore RE-READ `getCounter` after a bump
    ///      rather than assuming `previous + 1`.
    function test_fork_guardianCanBumpSeaportCounter() public onlyFork {
        uint256 before = seaport.getCounter(address(vault));
        vm.prank(guardian);
        vault.invalidateAllListings();
        uint256 after_ = seaport.getCounter(address(vault));
        assertGt(after_, before, "counter strictly increased on real Seaport");
        console2.log("counter before", before);
        console2.log("counter after ", after_);
    }

    /*//////////////////////////////////////////////////////////////
                       DEPOSIT WITH A REAL STOCK TOKEN
    //////////////////////////////////////////////////////////////*/

    /// @dev Uses forge's `deal` to mint NVDA into a test account. If the Stock Token's balance
    ///      slot cannot be found, this reports that rather than failing opaquely; the write path
    ///      is then covered by the mock suite instead.
    function test_fork_depositRealStockToken() public onlyFork {
        try this.dealToken(NVDA, alice, 5e18) {
            assertEq(IERC20(NVDA).balanceOf(alice), 5e18, "dealt NVDA");
        } catch {
            console2.log("deal() could not locate the NVDA balance slot; skipping deposit path");
            return;
        }

        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), 5e18);
        uint256 shares = vault.deposit(5e18, alice);
        vm.stopPrank();

        assertEq(shares, 5e18, "first deposit is 1:1");
        assertEq(vault.totalAssets(), 5e18);
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 5e18);

        // Flat vault: redemption is instant.
        assertTrue(vault.canRedeemInstantly());
        vm.prank(alice);
        vault.redeem(5e18, alice, alice);
        assertEq(IERC20(NVDA).balanceOf(alice), 5e18, "got it all back");
    }

    function dealToken(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    /// @dev The ERC-8056 multiplier must be readable and must never enter share maths.
    function test_fork_uiMultiplierIsDisplayOnly() public onlyFork {
        uint256 m = vault.uiMultiplier();
        console2.log("uiMultiplier", m);
        assertGt(m, 0, "readable, or defaulted to 1e18");
    }

    function test_fork_oracleNotPaused() public onlyFork {
        (bool ok, bytes memory data) = NVDA.staticcall(abi.encodeWithSelector(IStockToken.oraclePaused.selector));
        if (!ok || data.length != 32) {
            console2.log("oraclePaused() not present on this implementation");
            return;
        }
        assertFalse(abi.decode(data, (bool)), "issuer oracle is live");
    }

    /*//////////////////////////////////////////////////////////////
               THE REAL THING: ARM, LIST AND WRITE ON FILL
    //////////////////////////////////////////////////////////////*/

    /// @dev The integration test that matters (FIX-PLAN C-06A acceptance, D11.4). Deposit real
    ///      NVDA, arm a type on the live Clear, authorise a real PARTIAL_RESTRICTED listing on the
    ///      live Seaport with the vault as zone, and let a buyer fill it TWICE through the live
    ///      `fulfillAdvancedOrder`: the first fill opens the claim inside `authorizeOrder`, the second
    ///      tops the same claim up, and the TSTORE'd fill baseline is exercised on chain 4663's EVM.
    ///      Everything a mock can get wrong about someone else's contract shows up here.
    function test_fork_writeOnFillAgainstLiveSeaportAndClear() public onlyFork {
        (uint256 optionId, uint256 strike, uint40 exTs,) = _ourOptionType(13);
        if (!_dealBoth()) return;

        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), 4e18);
        vault.deposit(4e18, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rollOpen(optionId);
        assertEq(uint8(vault.phase()), 1, "phase Listed");
        assertEq(vault.contractsWritten(), 0, "nothing written at arm");
        assertEq(vault.claimKey(), 0, "no claim at arm");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no inventory at arm");
        assertEq(vault.cycleStrikeUsdg(), strike);
        assertEq(vault.cycleExerciseTs(), exTs);

        // 4 NVDA at 95% utilisation floors to 3 whole lots: list the whole capacity.
        uint256 unitPrice = 2_000_000; // $2.00/contract, over the 0.40%-of-spot floor
        OrderComponents memory o = _order(optionId, 3, unitPrice, exTs);
        vm.prank(keeper);
        vault.approveListing(o);

        bytes32 h = seaport.getOrderHash(o);
        assertEq(vault.listingHash(), h, "vault recorded the real Seaport order hash");
        (bool validated,,,) = seaport.getOrderStatus(h);
        assertTrue(validated, "real Seaport marked our order validated");

        // First fill: 1 of 3. `authorizeOrder` writes 1 into a fresh claim, Seaport moves it out.
        vm.prank(buyer);
        IERC20(USDG).approve(SEAPORT, type(uint256).max);
        uint256 g0 = gasleft();
        assertTrue(_fill(o, 1, 3), "first fill");
        console2.log("gas: first fill (opens the claim)", g0 - gasleft());
        uint256 key = vault.claimKey();
        assertGt(key, 0, "the fill opened the claim");
        assertEq(vault.contractsWritten(), 1);
        assertEq(clear.balanceOf(buyer, optionId), 1, "buyer holds the call");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "the vault holds NO option tokens");
        assertEq(clear.balanceOf(address(vault), key), 1, "and the claim NFT");
        assertEq(IERC20(USDG).balanceOf(address(vault)), unitPrice, "premium landed");
        assertEq(vault.lockedAssets(), 1e18, "one lot behind the claim");
        assertEq(vault.totalAssets(), 4e18, "writing moves collateral, it does not lose it");

        // Second fill: 1 more. Same claim, topped up.
        g0 = gasleft();
        assertTrue(_fill(o, 1, 3), "second fill");
        console2.log("gas: second fill (tops the claim up)", g0 - gasleft());
        assertEq(vault.claimKey(), key, "live Clear topped up the same claim");
        assertEq(vault.contractsWritten(), 2);
        assertEq(clear.balanceOf(buyer, optionId), 2);
        assertEq(clear.balanceOf(address(vault), optionId), 0, "still no inventory");
        assertEq(clear.claim(key).amountWritten, 2e18, "Valorem sums the claim's indices");
        assertEq(vault.lockedAssets(), 2e18, "position() sums them too");

        (, bool isCancelled, uint256 totalFilled, uint256 totalSize) = seaport.getOrderStatus(h);
        assertFalse(isCancelled);
        assertEq(totalFilled, 2, "fill fraction numerator");
        assertEq(totalSize, 3, "fill fraction denominator");

        console2.log("wrote and sold 2 of 3 on the live Seaport + Clear; claim", key);
    }

    /// @dev A type whose strike sits outside the band must be refused at arm against the live ladder
    ///      maths, and a claim id must never pass for an option id.
    function test_fork_armGateRefusesOutOfBandAndClaimIds() public onlyFork {
        uint256 spot = vault.spotUsdg();
        (uint40 exTs, uint40 expTs) = _window(17);
        // 30% out of the money is above the 12% ceiling at every launch policy.
        uint96 farStrike = uint96((spot * 13_000) / 10_000);
        uint256 far = clear.newOptionType(NVDA, 1e18, USDG, farStrike, exTs, expTs);
        vm.prank(keeper);
        vm.expectRevert();
        vault.rollOpen(far);
        assertEq(uint8(vault.phase()), 0, "still Idle");

        // A claim id (a write against a live type) is not an option type.
        if (!_dealBoth()) return;
        (uint256 optionId,,,) = _ourOptionType(19);
        vm.startPrank(alice);
        IERC20(NVDA).approve(CLEAR, 1e18);
        uint256 claimId = clear.write(optionId, 1);
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Vault.NotAnOptionType.selector, claimId));
        vault.rollOpen(claimId);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev A weekly-shaped window `salt` seconds off the round hour, so two tests in one fork run
    ///      never collide on an option key that already exists on the live Clear.
    function _window(uint256 salt) internal view returns (uint40 exTs, uint40 expTs) {
        exTs = uint40(block.timestamp + 3 days + salt);
        expTs = uint40(exTs + 1 days);
    }

    /// @dev Create our own option type on the live clearinghouse: 7% out of the money at live spot
    ///      (inside the 3%..12% launch band), lot 1e18, a 24-hour exercise window.
    function _ourOptionType(uint256 salt) internal returns (uint256 id, uint256 strike, uint40 exTs, uint40 expTs) {
        (exTs, expTs) = _window(salt);
        uint256 spot = vault.spotUsdg();
        strike = (spot * 10_700) / 10_000;
        id = clear.newOptionType(NVDA, 1e18, USDG, uint96(strike), exTs, expTs);
    }

    /// @dev Fund alice with NVDA and the buyer with USDG through `deal`; false if either slot cannot
    ///      be located on the live token (then the test reports and skips).
    function _dealBoth() internal returns (bool) {
        try this.dealToken(NVDA, alice, 4e18) {}
        catch {
            console2.log("deal() could not locate the NVDA balance slot; skipping");
            return false;
        }
        try this.dealToken(USDG, buyer, 10_000_000_000) {}
        catch {
            console2.log("deal() could not locate the USDG balance slot; skipping");
            return false;
        }
        return true;
    }

    function _fill(OrderComponents memory c, uint120 num, uint120 den) internal returns (bool ok) {
        AdvancedOrder memory ao = AdvancedOrder({
            parameters: _toParameters(c), numerator: num, denominator: den, signature: "", extraData: ""
        });
        vm.prank(buyer);
        ok = seaportFulfil.fulfillAdvancedOrder(ao, new CriteriaResolver[](0), bytes32(0), buyer);
    }

    function _toParameters(OrderComponents memory c) internal pure returns (OrderParameters memory p) {
        p = OrderParameters({
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

    /// @dev The vault's order shape: offerer AND zone the vault, PARTIAL_RESTRICTED, one USDG
    ///      consideration item to the vault.
    function _order(uint256 optionId, uint256 n, uint256 unitPrice, uint40 endTime)
        internal
        view
        returns (OrderComponents memory c)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155, token: CLEAR, identifierOrCriteria: optionId, startAmount: n, endAmount: n
        });

        ConsiderationItem[] memory consid = new ConsiderationItem[](1);
        consid[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: USDG,
            identifierOrCriteria: 0,
            startAmount: unitPrice * n,
            endAmount: unitPrice * n,
            recipient: payable(address(vault))
        });

        c = OrderComponents({
            offerer: address(vault),
            zone: address(vault),
            offer: offer,
            consideration: consid,
            orderType: OrderType.PARTIAL_RESTRICTED,
            startTime: 0,
            endTime: endTime,
            zoneHash: bytes32(0),
            salt: uint256(keccak256("callhouse-fork-test")),
            conduitKey: bytes32(0),
            counter: seaport.getCounter(address(vault))
        });
    }
}
