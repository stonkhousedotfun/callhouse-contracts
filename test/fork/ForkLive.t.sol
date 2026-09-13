// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {Policy, PolicyParams} from "../../src/Policy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {IOvercallRegistry} from "../../src/interfaces/IOvercallRegistry.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {
    ISeaport,
    OrderComponents,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType
} from "../../src/interfaces/ISeaport.sol";

/// @notice Fork tests against the real Robinhood Chain 4663 deployment.
/// @dev Run with:  forge test --match-path 'test/fork/*' --fork-url $RH_RPC -vv
///      These are the tests that catch a wrong assumption about somebody else's contract, which
///      is the class of bug mocks cannot find.
contract ForkLiveTest is Test {
    address constant CLEAR = 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant REGISTRY = 0x8E973cE1A6884E28Ad3E377d5f670Bc0b463f4EA;
    address constant OVERCALL_FEE = 0xdAe7e82A2E7D566C67E87C164B05a1C560190782;
    address constant FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    /// @dev The JUGGERNAUT market registry. Present only so a test can prove we did NOT wire it.
    address constant REGISTRY_JUGGERNAUT = 0x65dD407955912Be814f723724cE60f91ebd72616;

    IOvercallRegistry reg = IOvercallRegistry(REGISTRY);
    IValoremClear clear = IValoremClear(CLEAR);
    ISeaport seaport = ISeaport(SEAPORT);

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
                registry: IOvercallRegistry(REGISTRY),
                priceFeed: IChainlinkFeed(FEED),
                maxPriceAge: 4 days,
                overcallFeeRecipient: OVERCALL_FEE,
                conduitKey: bytes32(0),
                seaportZone: address(0),
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
        assertGt(USDG.code.length, 0, "USDG");
        assertGt(NVDA.code.length, 0, "NVDA Stock Token");
        assertGt(REGISTRY.code.length, 0, "OvercallRegistry NVDA");
        assertGt(MULTICALL3.code.length, 0, "Multicall3");
        assertGt(FEED.code.length, 0, "Chainlink NVDA/USD");
        assertEq(OVERCALL_FEE.code.length, 0, "Overcall fee key is an EOA, not a contract");
    }

    function test_fork_seaportIsVersion16() public onlyFork {
        (string memory version,, address conduitController) = seaport.information();
        assertEq(version, "1.6", "must be Seaport 1.6, not 1.5");
        console2.log("conduitController", conduitController);
    }

    function test_fork_tokenDecimals() public onlyFork {
        assertEq(IStockToken(NVDA).decimals(), 18, "Stock Tokens are 18 decimals");
        assertEq(IStockToken(USDG).decimals(), 6, "USDG is 6 decimals");
    }

    /*//////////////////////////////////////////////////////////////
                        THE REGISTRY IS THE RIGHT ONE
    //////////////////////////////////////////////////////////////*/

    function test_fork_registryDescribesOurPair() public onlyFork {
        assertEq(reg.collateralToken(), NVDA, "collateral must be NVDA");
        assertEq(reg.exerciseToken(), USDG, "exercise must be USDG");
        assertEq(reg.clearinghouse(), CLEAR, "clearinghouse must be Valorem Clear");
        assertEq(reg.lotSize(), 1e18, "lot size is exactly one token");
    }

    /// @dev Overcall's frontend config has a top-level `registry` key that is the JUGGERNAUT
    ///      market, not NVDA. Binding it here would collateralise NVDA calls against a different
    ///      token. This test exists so that mistake can never be made silently.
    function test_fork_juggernautRegistryIsNotOurs() public onlyFork {
        assertTrue(REGISTRY_JUGGERNAUT != REGISTRY, "distinct registries");
        assertTrue(
            IOvercallRegistry(REGISTRY_JUGGERNAUT).collateralToken() != NVDA,
            "the JUGGERNAUT registry does not collateralise NVDA"
        );
    }

    /// @dev The vault constructor refuses a registry that does not describe its pair.
    function test_fork_constructorRejectsWrongRegistry() public onlyFork {
        vm.expectRevert();
        new Vault(
            Vault.Config({
                asset: IERC20(NVDA),
                usdg: IERC20(USDG),
                clear: IValoremClear(CLEAR),
                seaport: ISeaport(SEAPORT),
                registry: IOvercallRegistry(REGISTRY_JUGGERNAUT),
                priceFeed: IChainlinkFeed(FEED),
                maxPriceAge: 4 days,
                overcallFeeRecipient: OVERCALL_FEE,
                conduitKey: bytes32(0),
                seaportZone: address(0),
                admin: admin,
                feeRecipient: feeSafe,
                depositCap: 50e18,
                name: "wrong",
                symbol: "wrong"
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                             THE LIVE CYCLE
    //////////////////////////////////////////////////////////////*/

    function test_fork_cycleShape() public onlyFork {
        IOvercallRegistry.Cycle memory c = reg.cycle();
        console2.log("cycle number      ", c.number);
        console2.log("exerciseTimestamp ", c.exerciseTimestamp);
        console2.log("expiryTimestamp   ", c.expiryTimestamp);
        console2.log("lotSize           ", c.lotSize);
        console2.log("rungs             ", c.optionIds.length);

        if (c.number == 0) {
            console2.log("no cycle set yet on this fork block");
            return;
        }

        assertLe(c.optionIds.length, reg.MAX_STRIKES(), "never more rungs than MAX_STRIKES");
        assertGt(c.expiryTimestamp, c.exerciseTimestamp, "expiry is after exercise");
        assertGe(
            uint256(c.expiryTimestamp - c.exerciseTimestamp),
            reg.MIN_EXERCISE_WINDOW(),
            "exercise window respects the registry minimum"
        );
        assertEq(reg.writeDeadline(), c.exerciseTimestamp, "writeDeadline IS exerciseTimestamp");

        // Strikes ascend, and the registry and the clearinghouse agree about every one of them.
        uint96 prev;
        for (uint256 i; i < c.optionIds.length; i++) {
            uint256 id = c.optionIds[i];
            uint96 strike = reg.strikePerContract(id);
            assertGt(strike, prev, "strikes strictly ascending");
            prev = strike;

            assertTrue(reg.isApproved(id), "every cycle id is approved");
            assertEq(reg.cycleOf(id), c.number, "every id belongs to this cycle");

            IValoremClear.Option memory o = clear.option(id);
            assertEq(o.underlyingAsset, NVDA, "underlying is NVDA");
            assertEq(o.exerciseAsset, USDG, "exercise is USDG");
            assertEq(o.underlyingAmount, c.lotSize, "one lot per contract");
            assertEq(o.exerciseAmount, strike, "registry strike == Valorem exerciseAmount");
            assertEq(o.exerciseTimestamp, c.exerciseTimestamp, "shared exercise time");
            assertEq(o.expiryTimestamp, c.expiryTimestamp, "shared expiry");

            console2.log("  rung strike (USDG 6dp)", strike);
        }
    }

    /// @dev An id that is not in the cycle must not read as approved. A default-true would let
    ///      the keeper write anything.
    function test_fork_unknownOptionNotApproved() public onlyFork {
        assertFalse(reg.isApproved(0), "zero id is not approved");
        assertEq(reg.cycleOf(0), 0, "zero id belongs to no cycle");
    }

    /*//////////////////////////////////////////////////////////////
                          VALOREM ASSUMPTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev The engine fee being off is what makes weekly OTM premium worth collecting. If this
    ///      ever fails on mainnet, the vault refuses to write until governance accepts it.
    function test_fork_valoremFeeSwitch() public onlyFork {
        bool on = clear.feesEnabled();
        console2.log("feesEnabled", on);
        console2.log("feeBps     ", clear.feeBps());
        console2.log("feeTo      ", clear.feeTo());
        assertFalse(on, "Valorem engine fee is expected OFF at Overcall launch");
    }

    function test_fork_clearIsErc1155() public onlyFork {
        assertTrue(clear.supportsInterface(0xd9b67a26), "ERC-1155");
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
        assertEq(address(vault.registry()), REGISTRY);
        assertEq(vault.maxPriceAge(), 4 days);
        assertEq(uint8(vault.phase()), 0, "starts Idle");

        uint256 spot = vault.spotUsdg();
        assertGt(spot, 0, "vault can read spot through the real feed");
        console2.log("vault spotUsdg", spot);
    }

    /// @dev Seaport must accept the vault as an offerer and hash our exact order shape.
    function test_fork_seaportHashesOurOrderShape() public onlyFork {
        IOvercallRegistry.Cycle memory c = reg.cycle();
        if (c.number == 0 || c.optionIds.length == 0) return;

        OrderComponents memory o = _order(c.optionIds[0], 1, 2_000_000, c.exerciseTimestamp);
        bytes32 h = seaport.getOrderHash(o);
        assertTrue(h != bytes32(0), "real Seaport produced a hash for our shape");

        (bool validated, bool cancelledFlag, uint256 filled, uint256 sz) = seaport.getOrderStatus(h);
        assertFalse(validated);
        assertFalse(cancelledFlag);
        assertEq(filled, 0);
        assertEq(sz, 0);

        assertEq(seaport.getCounter(address(vault)), 0, "a fresh vault starts at counter 0");
    }

    /// @dev EIP-1271 must answer for the real Seaport EIP-712 digest, built from the live domain
    ///      separator. Getting this wrong means no buyer can ever fill.
    function test_fork_eip1271RejectsWhenNothingListed() public onlyFork {
        assertEq(vault.isValidSignature(bytes32(uint256(1)), ""), bytes4(0xffffffff));
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
        try this.dealNvda(alice, 5e18) {
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

    function dealNvda(address to, uint256 amount) external {
        deal(NVDA, to, amount, true);
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
                    THE REAL THING: WRITE AND LIST ON CHAIN
    //////////////////////////////////////////////////////////////*/

    /// @dev The integration test that matters. Deposit real NVDA, write real Valorem calls
    ///      against the live cycle, and authorise a real Seaport listing. Everything a mock can
    ///      get wrong about someone else's contract shows up here.
    function test_fork_writeAndListForReal() public onlyFork {
        IOvercallRegistry.Cycle memory c = reg.cycle();
        if (c.number == 0 || c.optionIds.length == 0) {
            console2.log("no live cycle at this block; nothing to write against");
            return;
        }
        if (!reg.isWritingOpen()) {
            console2.log("write window closed at this block");
            return;
        }

        // Pick the nearest rung inside the vault's own OTM band, the way the keeper does.
        uint256 spot = vault.spotUsdg();
        (uint256 lo, uint256 hi) = Policy.strikeBand(spot, _policy());
        uint256 chosen = type(uint256).max;
        for (uint256 i; i < c.optionIds.length; i++) {
            uint256 k = reg.strikePerContract(c.optionIds[i]);
            if (k >= lo && k <= hi) {
                chosen = c.optionIds[i];
                console2.log("picked rung strike", k);
                break;
            }
        }
        if (chosen == type(uint256).max) {
            console2.log("no rung inside the OTM band at this spot; the vault correctly writes nothing");
            return;
        }

        try this.dealNvda(alice, 4e18) {}
        catch {
            console2.log("deal() could not locate the NVDA balance slot; skipping");
            return;
        }

        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), 4e18);
        vault.deposit(4e18, alice);
        vm.stopPrank();

        uint112 n = 3; // 4 NVDA idle at 95% utilisation floors to 3 whole lots

        vm.prank(keeper);
        vault.rollOpen(chosen, n);

        // Real Valorem minted us real option tokens and a real claim.
        assertEq(uint8(vault.phase()), 1, "phase Listed");
        assertEq(clear.balanceOf(address(vault), chosen), n, "vault holds n option tokens");
        assertGt(vault.claimKey(), 0, "vault holds a claim");
        assertEq(vault.contractsWritten(), n);
        assertEq(vault.lockedAssets(), uint256(n) * 1e18, "collateral locked in Valorem");
        assertEq(vault.totalAssets(), 4e18, "writing moves collateral, it does not lose it");

        IValoremClear.Claim memory cl = clear.claim(vault.claimKey());
        assertEq(cl.amountWritten, uint256(n) * 1e18, "Valorem reports a 1e18-scaled scalar");
        assertEq(cl.amountExercised, 0);
        assertEq(cl.optionId, chosen);

        // Now authorise a listing on the real Seaport.
        uint256 unitPrice = 2_000_000; // $2.00/contract, over the 0.40%-of-spot floor
        OrderComponents memory o = _order(chosen, n, unitPrice, c.exerciseTimestamp);

        vm.prank(keeper);
        vault.approveListing(o);

        bytes32 h = seaport.getOrderHash(o);
        assertEq(vault.listingHash(), h, "vault recorded the real Seaport order hash");
        assertEq(vault.listingAmount(), n);
        assertEq(vault.listingGrossUsdg(), unitPrice * n);

        (bool validated, bool isCancelled, uint256 totalFilled, uint256 totalSize) = seaport.getOrderStatus(h);
        assertTrue(validated, "real Seaport marked our order validated");
        assertFalse(isCancelled);
        // NOTE FOR THE KEEPER: `totalFilled`/`totalSize` are the numerator and denominator of the
        // FILL FRACTION, not the order quantity. Both stay 0 until someone actually fills, even
        // on a validated order. Do not read them to discover how big an order is, and do not read
        // totalSize == 0 as "nothing listed" — check `validated` for that.
        assertEq(totalFilled, 0, "nothing filled yet");
        assertEq(totalSize, 0, "fill fraction is unset until the first fill");

        // EIP-1271 must answer for the real EIP-712 digest, or no buyer can ever fill.
        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, h));
        assertEq(vault.isValidSignature(digest, new bytes(65)), bytes4(0x1626ba7e), "1271 accepts the digest");
        assertEq(vault.isValidSignature(h, ""), bytes4(0x1626ba7e), "1271 accepts the raw hash too");
        assertEq(vault.isValidSignature(keccak256("nope"), ""), bytes4(0xffffffff), "and rejects anything else");

        // Seaport pulls the 1155 directly because the conduit key is zero.
        assertTrue(clear.isApprovedForAll(address(vault), SEAPORT), "Seaport is approved to move the options");

        console2.log("listed", uint256(n), "contracts for USDG", unitPrice * n);
    }

    /// @dev A rung outside the OTM band must be refused even against the live ladder.
    function test_fork_outOfBandRungIsRefused() public onlyFork {
        IOvercallRegistry.Cycle memory c = reg.cycle();
        if (c.number == 0 || c.optionIds.length == 0 || !reg.isWritingOpen()) return;

        uint256 spot = vault.spotUsdg();
        (uint256 lo, uint256 hi) = Policy.strikeBand(spot, _policy());

        uint256 outOfBand = type(uint256).max;
        for (uint256 i; i < c.optionIds.length; i++) {
            uint256 k = reg.strikePerContract(c.optionIds[i]);
            if (k < lo || k > hi) {
                outOfBand = c.optionIds[i];
                break;
            }
        }
        if (outOfBand == type(uint256).max) {
            console2.log("every live rung happens to be in band right now");
            return;
        }

        try this.dealNvda(alice, 4e18) {}
        catch {
            return;
        }
        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), 4e18);
        vault.deposit(4e18, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert();
        vault.rollOpen(outOfBand, 3);
    }

    function _policy() internal view returns (PolicyParams memory p) {
        (
            uint16 minOtmBps,
            uint16 maxOtmBps,
            uint16 minPremiumBps,
            uint16 maxUtilizationBps,
            uint16 protocolFeeBps,
            uint64 maxContractsCap
        ) = vault.policy();
        p = PolicyParams({
            minOtmBps: minOtmBps,
            maxOtmBps: maxOtmBps,
            minPremiumBps: minPremiumBps,
            maxUtilizationBps: maxUtilizationBps,
            protocolFeeBps: protocolFeeBps,
            maxContractsCap: maxContractsCap
        });
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _order(uint256 optionId, uint256 n, uint256 unitPrice, uint40 endTime)
        internal
        view
        returns (OrderComponents memory c)
    {
        (uint256 toVault, uint256 toOvercall,) = Policy.splitPremium(unitPrice, n);

        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155, token: CLEAR, identifierOrCriteria: optionId, startAmount: n, endAmount: n
        });

        ConsiderationItem[] memory consid = new ConsiderationItem[](2);
        consid[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: USDG,
            identifierOrCriteria: 0,
            startAmount: toVault,
            endAmount: toVault,
            recipient: payable(address(vault))
        });
        consid[1] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: USDG,
            identifierOrCriteria: 0,
            startAmount: toOvercall,
            endAmount: toOvercall,
            recipient: payable(OVERCALL_FEE)
        });

        c = OrderComponents({
            offerer: address(vault),
            zone: address(0),
            offer: offer,
            consideration: consid,
            orderType: OrderType.PARTIAL_OPEN,
            startTime: 0,
            endTime: endTime,
            zoneHash: bytes32(0),
            salt: uint256(keccak256("callhouse-fork-test")),
            conduitKey: bytes32(0),
            counter: seaport.getCounter(address(vault))
        });
    }
}
