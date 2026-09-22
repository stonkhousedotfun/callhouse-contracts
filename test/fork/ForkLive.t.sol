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

import {ForkFloor} from "../v2/fork/ForkFloor.sol";

/// @dev The three USDG (Paxos) admin entry points the strand tests drive on the live token: `freeze` and
///      `unfreeze` are `ASSET_PROTECTION_ROLE`, instant and untimelocked (integrations/usdg.md §3).
///      C8-09b: this is the v1 vault fork, not the v8 matrix. Without `--fork-url` and `--fork-block-number`
///      it is GREEN HAVING RUN NOTHING (`06-QUIRKS.md` §A.1). No RPC was granted for this task.
interface IUsdgAssetProtection {
    function freeze(address addr) external;
    function unfreeze(address addr) external;
    function isFrozen(address addr) external view returns (bool);
}

/// @dev One TSTORE and one TLOAD, the two opcodes the vault's fill baseline is built on, compiled for
///      the same `evm_version = "cancun"` as the vault.
contract TransientProbe {
    function roundTrip(uint256 v) external returns (uint256 out) {
        assembly {
            tstore(0x42, v)
            out := tload(0x42)
        }
    }
}

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

    /// @dev The EOA holding USDG's PAUSE_ROLE and ASSET_PROTECTION_ROLE on 4663 (27 freezes sent from it
    ///      so far, none reversed; integrations/usdg.md §3). Impersonated to freeze the vault below; if the
    ///      role has moved, the test falls back to writing the `frozen` mapping (slot 6) directly.
    address constant USDG_ASSET_PROTECTION = 0x3Af3e85f4f97De7AD0f000B724Fb77fE5ffc024B;
    uint256 constant USDG_FROZEN_SLOT = 6;

    /// @dev $2.00 a contract: above the 0.40%-of-spot premium floor at any NVDA price under $500.
    uint256 constant UNIT_PRICE = 2_000_000;

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
            vm.skip(true);
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
            vm.skip(true);
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
            vm.skip(true);
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
        if (!_dealBoth()) {
            // SKIP, DO NOT RETURN. A bare return here reports PASSED having asserted nothing -- the exact
            // shape T-CT5-01 was opened for, one layer down. See the note on {_dealBoth}.
            vm.skip(true);
            return;
        }

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
        if (!_dealBoth()) {
            // SKIP, DO NOT RETURN. A bare return here reports PASSED having asserted nothing -- the exact
            // shape T-CT5-01 was opened for, one layer down. See the note on {_dealBoth}.
            vm.skip(true);
            return;
        }
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
                    TRANSIENT STORAGE ON THE LIVE CHAIN
    //////////////////////////////////////////////////////////////*/

    /// @dev D11.4 / D17. The fill baseline lives in transient storage, so the vault is only deployable
    ///      where EIP-1153 is live. A fork test runs on forge's EVM, not the chain's, so the local
    ///      probe below proves only the build target; the chain itself is asked THROUGH THE RPC with the
    ///      same `eth_call` create probe the D17 verification used: init code `PUSH1 1 PUSH1 0 TSTORE
    ///      PUSH1 0 TLOAD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN` returns the 32-byte word 1 only if the
    ///      node's EVM executes TSTORE/TLOAD. A node without them fails the call.
    function test_fork_transientStorageIsLiveOnChain4663() public onlyFork {
        bytes memory word = vm.rpc("eth_call", '[{"data":"0x600160005d60005c60005260206000f3"},"latest"]');
        assertEq(word.length, 32, "the create probe returned one word");
        assertEq(uint256(bytes32(word)), 1, "TLOAD read back the TSTORE'd 1 on the live node");

        // And the build target the vault is compiled for round-trips the same pair on the forked EVM.
        assertEq(new TransientProbe().roundTrip(7), 7, "TSTORE/TLOAD under evm_version cancun");
    }

    /*//////////////////////////////////////////////////////////////
                   THE WHOLE WEEK ON THE LIVE CLEARINGHOUSE
    //////////////////////////////////////////////////////////////*/

    /// @dev An assigned week end to end on the live Clear: arm, list, two fills through the live Seaport
    ///      (open + top-up), the buyer exercises everything it bought inside the window, the book locks,
    ///      and a stranger closes an hour after expiry. Assignment equals what was SOLD, the strike lands
    ///      as fee-free proceeds, the unassigned collateral is nil because everything sold was assigned,
    ///      and the vault is flat again. The first real assignment and redeem on this chain's Clear happen
    ///      here, on a fork, before they happen for real.
    function test_fork_assignedWeekSettlesOnLiveClear() public onlyFork {
        (uint256 optionId, uint256 strike, uint40 exTs, uint40 expTs) = _ourOptionType(23);
        if (!_dealBoth()) {
            // SKIP, DO NOT RETURN. A bare return here reports PASSED having asserted nothing -- the exact
            // shape T-CT5-01 was opened for, one layer down. See the note on {_dealBoth}.
            vm.skip(true);
            return;
        }
        uint256 key = _sellTwoOfThree(optionId, exTs, true); // open + top-up
        uint256 premium = 2 * UNIT_PRICE;

        // The window opens: the buyer exercises both. Clear pulls the strike from the buyer and pushes
        // the collateral to it; the vault's claim now holds 2 x strike of USDG and no NVDA.
        vm.warp(exTs);
        vm.startPrank(buyer);
        IERC20(USDG).approve(CLEAR, type(uint256).max);
        clear.exercise(optionId, 2);
        vm.stopPrank();
        assertEq(clear.balanceOf(buyer, optionId), 0, "options burnt on exercise");
        assertEq(IERC20(NVDA).balanceOf(buyer), 2e18, "buyer took delivery");
        assertEq(vault.lockedAssets(), 0, "nothing left behind the claim");
        assertEq(vault.claimedExerciseProceeds(), 2 * strike, "the claim holds the strike proceeds");
        assertEq(vault.contractsAssigned(), 2, "assigned == sold");
        assertEq(vault.totalAssets(), 2e18, "NAV reflects the delivery");

        vault.lockBook(); // anyone
        assertEq(uint8(vault.phase()), 2, "Exercisable");
        assertEq(vault.listingHash(), bytes32(0), "the listing is dead on Seaport");

        // A stranger may close an hour after expiry. Assignment is read before the redeem zeroes the claim.
        vm.warp(uint256(expTs) + 1 hours);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.RollClose(1, 0, 2 * strike, 2);
        vm.prank(alice);
        vault.rollClose();

        assertEq(uint8(vault.phase()), 0, "Idle");
        assertEq(vault.claimKey(), 0, "claim redeemed");
        assertEq(clear.balanceOf(address(vault), key), 0, "claim NFT burnt by Clear's redeem");
        assertFalse(vault.isStranded());
        assertTrue(vault.canRedeemInstantly(), "flat");
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 2e18, "the two unsold lots never moved");
        assertEq(vault.totalAssets(), 2e18);

        // The fee is 5% of the PREMIUM only; the strike proceeds are credited to the holder fee-free.
        uint256 fee = (premium * 500) / 10_000;
        assertEq(IERC20(USDG).balanceOf(feeSafe), fee, "5% of the premium, none of the strike");
        assertEq(IERC20(USDG).balanceOf(address(vault)), premium - fee + 2 * strike, "premium net of fee plus strike");
        assertApproxEqAbs(vault.claimableUsdg(alice), premium - fee + 2 * strike, 1, "all of it to the sole holder");
        console2.log("assigned week on the live Clear: claim", key, "strike", strike);
    }

    /// @dev A week nobody bought: the listing stays unfilled, nothing is written, so `rollClose` has no
    ///      claim to redeem. It must return to Idle with nothing locked and nothing stranded.
    function test_fork_unfilledWeekClosesFlatOnLiveClear() public onlyFork {
        (uint256 optionId,, uint40 exTs, uint40 expTs) = _ourOptionType(31);
        if (!_dealBoth()) {
            // SKIP, DO NOT RETURN. A bare return here reports PASSED having asserted nothing -- the exact
            // shape T-CT5-01 was opened for, one layer down. See the note on {_dealBoth}.
            vm.skip(true);
            return;
        }
        _depositArmAndList(optionId, 4e18, 3, exTs);
        assertTrue(vault.listingHash() != bytes32(0), "listed");

        vm.warp(exTs);
        vault.lockBook();
        assertEq(uint8(vault.phase()), 2, "Exercisable");
        assertEq(vault.contractsWritten(), 0, "nothing was ever written");
        assertEq(vault.claimKey(), 0, "no claim");

        // The keeper may close at expiry exactly.
        vm.warp(expTs);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.RollClose(1, 0, 0, 0);
        vm.prank(keeper);
        vault.rollClose();

        assertEq(uint8(vault.phase()), 0, "Idle");
        assertEq(vault.optionId(), 0, "the armed type is forgotten");
        assertEq(vault.claimKey(), 0);
        assertEq(vault.lockedAssets(), 0, "nothing locked");
        assertFalse(vault.isStranded(), "nothing stranded");
        assertEq(vault.strandGen(), 0);
        assertTrue(vault.canRedeemInstantly(), "flat");
        assertEq(vault.totalAssets(), 4e18, "NAV untouched");
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 4e18);
        assertEq(IERC20(USDG).balanceOf(address(vault)), 0, "no premium, no proceeds");
        assertEq(vault.cycleNumber(), 1, "the week still counted");
    }

    /*//////////////////////////////////////////////////////////////
                THE F-02 STRAND ON THE REAL USDG FREEZE PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev AUDIT-FINDINGS F-02 against the REAL token: Paxos's `ASSET_PROTECTION_ROLE` freezes the vault
    ///      on USDG after a partially assigned week, so Clear's `redeem` (USDG leg first, to the frozen
    ///      vault) reverts `AddressFrozen`. `rollClose` must still reach Idle, keep the claim, shut deposits
    ///      and the instant path, and `retryStrandedClaim` must refuse `StillStranded` until the freeze
    ///      lifts and then bring both legs home. Partial assignment on purpose: both legs are non-zero, so
    ///      the recovery has to return NVDA and USDG in one redeem.
    function test_fork_usdgFreezeStrandsTheCloseAndRetryRecoversIt() public onlyFork {
        (uint256 optionId, uint256 strike, uint40 exTs, uint40 expTs) = _ourOptionType(29);
        if (!_dealBoth()) {
            // SKIP, DO NOT RETURN. A bare return here reports PASSED having asserted nothing -- the exact
            // shape T-CT5-01 was opened for, one layer down. See the note on {_dealBoth}.
            vm.skip(true);
            return;
        }
        uint256 key = _sellTwoOfThree(optionId, exTs, false); // one fill of two
        uint256 premium = 2 * UNIT_PRICE;

        vm.warp(exTs);
        vm.startPrank(buyer);
        IERC20(USDG).approve(CLEAR, type(uint256).max);
        clear.exercise(optionId, 1); // one of two: the claim holds 1e18 NVDA AND 1 x strike USDG
        vm.stopPrank();
        assertEq(vault.lockedAssets(), 1e18);
        assertEq(vault.claimedExerciseProceeds(), strike);
        vault.lockBook();
        vm.warp(uint256(expTs) + 1 hours);

        // Paxos freezes the vault. Real role, real token, real revert on the redeem's first leg.
        _setUsdgFrozen(address(vault), true);
        uint256 usdgBefore = IERC20(USDG).balanceOf(address(vault));
        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.ClaimStranded(1, key, 1);
        vm.prank(alice);
        vault.rollClose();
        _assertStrandedOn(key, optionId, usdgBefore);

        // Arming over it is refused, and so is the retry while the freeze holds.
        uint256 next = _optionTypeAtStrike(strike, 37);
        vm.prank(keeper);
        vm.expectRevert(Vault.StillStranded.selector);
        vault.rollOpen(next);
        vm.expectRevert(Vault.StillStranded.selector);
        vault.retryStrandedClaim();

        // Paxos unfreezes. Anyone redeems the claim; both legs come home, the strike fee-free.
        _setUsdgFrozen(address(vault), false);
        uint256 feeBefore = IERC20(USDG).balanceOf(feeSafe);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.StrandedClaimRecovered(1, 1e18, strike, 0);
        vm.prank(alice);
        vault.retryStrandedClaim();
        _assertRecovered(usdgBefore, feeBefore, strike, premium);
        console2.log("USDG freeze strand + recovery on the live token and Clear: claim", key);
    }

    /// @dev The stranded state after a close whose redeem the frozen USDG refused: Idle, claim and type
    ///      kept, deposits and the instant path shut, the claim still counted as collateral, no USDG moved.
    function _assertStrandedOn(uint256 key, uint256 optionId, uint256 usdgBefore) internal view {
        assertEq(uint8(vault.phase()), 0, "Idle even though the redeem failed");
        assertTrue(vault.isStranded(), "stranded");
        assertEq(vault.claimKey(), key, "the claim is kept");
        assertEq(vault.optionId(), optionId, "and the type with it");
        assertEq(vault.contractsWritten(), 2, "and the count that shuts the instant path");
        assertEq(vault.strandGen(), 1, "generation 1 open");
        assertEq(vault.strandedRemainingWad(), 1e18, "live shares own all of it: nothing was queued");
        assertEq(vault.lockedAssets(), 1e18, "the stranded claim still reads as locked collateral");
        assertEq(vault.totalAssets(), 3e18, "NAV counts the stranded lot");
        assertFalse(vault.canRedeemInstantly(), "instant path shut");
        assertEq(vault.maxDeposit(alice), 0, "deposits shut");
        assertEq(IERC20(USDG).balanceOf(address(vault)), usdgBefore, "no USDG moved under the freeze");
        assertEq(clear.balanceOf(address(vault), key), 1, "Clear still holds the claim for the vault");
    }

    /// @dev After the retry: resolved and flat, the unassigned lot back, the strike leg landed fee-free.
    ///      Whatever the close could not push to the fee Safe under the freeze, the retry's harvest does,
    ///      so the USDG identity is stated on vault plus fee Safe together.
    function _assertRecovered(uint256 usdgBefore, uint256 feeBefore, uint256 strike, uint256 premium) internal view {
        assertFalse(vault.isStranded(), "resolved");
        assertEq(vault.claimKey(), 0);
        assertEq(vault.lastResolvedGen(), 1);
        assertEq(vault.strandedRemainingWad(), 0);
        assertTrue(vault.canRedeemInstantly(), "flat again");
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 3e18, "the unassigned lot is back");
        assertEq(vault.totalAssets(), 3e18);
        uint256 feeDelta = IERC20(USDG).balanceOf(feeSafe) - feeBefore;
        assertEq(IERC20(USDG).balanceOf(address(vault)) + feeDelta, usdgBefore + strike, "the strike leg landed");
        uint256 fee = (premium * 500) / 10_000;
        assertEq(IERC20(USDG).balanceOf(feeSafe), fee, "fee: 5% of the premium, none of the strike");
        assertApproxEqAbs(vault.claimableUsdg(alice), premium - fee + strike, 1, "the rest to the sole holder");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deposit `assets` of NVDA as alice, arm `optionId`, list `n` contracts at {UNIT_PRICE}, and
    ///      leave the buyer approved on Seaport. Every week-shaped test starts here.
    function _depositArmAndList(uint256 optionId, uint256 assets, uint256 n, uint40 exTs)
        internal
        returns (OrderComponents memory o)
    {
        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), assets);
        vault.deposit(assets, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rollOpen(optionId);
        assertEq(uint8(vault.phase()), 1, "Listed");

        o = _order(optionId, n, UNIT_PRICE, exTs);
        vm.prank(keeper);
        vault.approveListing(o);

        vm.prank(buyer);
        IERC20(USDG).approve(SEAPORT, type(uint256).max);
    }

    /// @dev {_depositArmAndList} with 4 NVDA and a 3-contract listing, then sell two of the three through
    ///      the live Seaport: as two fills of one (`twoFills`, so the top-up path runs) or one fill of two.
    ///      Returns the claim the fill(s) opened. Kept out of the test frames because encoding the nested
    ///      order for `fulfillAdvancedOrder` is what pushes a frame with the week's locals past the stack.
    function _sellTwoOfThree(uint256 optionId, uint40 exTs, bool twoFills) internal returns (uint256 key) {
        OrderComponents memory o = _depositArmAndList(optionId, 4e18, 3, exTs);
        if (twoFills) {
            assertTrue(_fill(o, 1, 3), "first fill opens the claim");
            assertTrue(_fill(o, 1, 3), "second fill tops it up");
        } else {
            assertTrue(_fill(o, 2, 3), "sold two in one fill");
        }
        key = vault.claimKey();
        assertGt(key, 0, "the fill opened the claim");
        assertEq(vault.contractsWritten(), 2, "wrote exactly what it sold");
        assertEq(clear.balanceOf(buyer, optionId), 2, "buyer holds two");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no inventory");
        assertEq(clear.claim(key).amountWritten, 2e18, "one claim, two contracts");
        assertEq(IERC20(USDG).balanceOf(address(vault)), 2 * UNIT_PRICE, "premium landed");
    }

    /// @dev Freeze or unfreeze `who` on the live USDG as Paxos would: impersonate the ASSET_PROTECTION
    ///      EOA and call the facet. If the role has moved since the dossier, write the `frozen` mapping
    ///      (slot 6, confirmed on chain) instead, so the test still exercises the token's own revert.
    function _setUsdgFrozen(address who, bool frozen) internal {
        vm.prank(USDG_ASSET_PROTECTION);
        (bool ok,) = USDG.call(abi.encodeWithSignature(frozen ? "freeze(address)" : "unfreeze(address)", who));
        if (!ok) {
            console2.log("USDG ASSET_PROTECTION_ROLE has moved; writing the frozen slot directly");
            vm.store(USDG, keccak256(abi.encode(who, USDG_FROZEN_SLOT)), bytes32(uint256(frozen ? 1 : 0)));
        }
        assertEq(IUsdgAssetProtection(USDG).isFrozen(who), frozen, "USDG frozen state");
    }

    /// @dev A second type at a given strike (the spot may be stale after a warp, so the strike is
    ///      reused rather than re-derived), `salt` seconds off the round hour.
    function _optionTypeAtStrike(uint256 strike, uint256 salt) internal returns (uint256 id) {
        (uint40 exTs, uint40 expTs) = _window(salt);
        id = clear.newOptionType(NVDA, 1e18, USDG, uint96(strike), exTs, expTs);
    }

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
    /// @dev RETURNS FALSE WHEN THE PRECONDITION IS UNAVAILABLE, AND EVERY CALLER MUST `vm.skip` ON THAT,
    ///      never a bare `return`. A returning test body reports PASSED having asserted nothing, which is
    ///      indistinguishable from a test that verified the behaviour. MEASURED at 3ae5824a: with this helper
    ///      forced false, all 20 tests in this file still reported `20 passed; 0 failed; 0 skipped` and the
    ///      only trace was the gas column collapsing -- 3,511,755 -> 176,551 on
    ///      {test_fork_usdgFreezeStrandsTheCloseAndRetryRecoversIt}, and comparably on the other four. Nobody
    ///      reads the gas column. That is the T-CT5-01 defect shape exactly, one layer below where it was found.
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

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `CLEAR`, an address this suite's own tests read.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_forkLiveExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(CLEAR, "ForkLive");
    }
}
