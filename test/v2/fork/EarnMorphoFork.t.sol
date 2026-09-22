// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {Erc4626VenueAdapter} from "../../../src/v2/periphery/earn/adapters/Erc4626VenueAdapter.sol";
import {ForkFloor} from "./ForkFloor.sol";

/// @notice {Erc4626VenueAdapter} against chain 4663's LIVE Steakhouse USDG vault.
/// @dev Run with
///      `FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --fork-block-number <recent block> -j 1 \
///       --match-path test/v2/fork/EarnMorphoFork.t.sol -vv`.
///
///      PIN A RECENT BLOCK. The public 4663 node is NOT an archive node: measured, it serves head-512 but not
///      head-9428, so a pin goes stale within hours and surfaces as a bare `EvmError: Revert` inside setUp that
///      reads exactly like a contract bug. The block this file was first written against (69112338) is long gone.
///
///      WITHOUT `--fork-url` THIS SUITE EXECUTES NO ASSERTIONS. It reports `0 passed / 0 failed / N skipped`
///      and EXIT 0 — which looks exactly like success. Only the passed-versus-skipped count separates a real
///      run from a vacuous one, so record BOTH when you cite this file (T-CT5-01: an unforked fork run
///      reports PASSED having run nothing). The same control was run on `ZapFork.t.sol`.
///
///      WHY THIS FILE EXISTS. P8-02B / T-104 shipped the ERC-4626 adapter with its fork half recorded as
///      "not authored", and its first launch-phase check was "run the unit files, then a real --fork-url 4663
///      block against Steakhouse once the owner grants the RPC". Both blockers are now gone. Until this file,
///      the adapter had never met a real 4626 — every green it had was against `Mock4626Vault`, whose
///      conversion is linear.
///
///      WHAT IT DOES NOT ESTABLISH, so a green is not over-read: it does not exercise EarnVault, the funding
///      seam, `skim`, or the disabled-stock adapter; it does not drive Morpho Blue directly; and it asserts
///      nothing about yield accrual over time, since it pins one block.
contract EarnMorphoForkTest is V8AccessTest {
    /// @dev Live 4663 addresses. Verified at block 69112338 before this file was written:
    ///      `eth_getCode` on the venue returns 21_808 bytes, `asset()` returns USDG below, and `decimals()`
    ///      returns 18 — 18-decimal SHARES over a 6-decimal ASSET, which is the mismatch P8-02A and
    ///      P8-03/T-95 both flag. `totalAssets()` was 487_840_190_487306 base units (~487.84M USDG).
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant STEAKHOUSE_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;

    uint256 internal constant DEP = 10_000e6;

    Erc4626VenueAdapter internal adapter;
    address internal earnVault = makeAddr("earnVaultStandIn");

    function setUp() public {
        if (block.chainid != 4663) return;
        _deployManager();
        adapter = new Erc4626VenueAdapter(address(manager), USDG, STEAKHOUSE_USDG, earnVault);
    }

    function _requireFork() internal {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
        }
    }

    /// @dev THE CONSTRUCTOR GUARD MEETS A REAL VENUE. `Erc4626VenueAdapter`'s constructor reverts
    ///      `UnsupportedAsset` unless `IERC4626(venue).asset() == asset`. Against `Mock4626Vault` that check has
    ///      only ever seen a mock's answer; here it is the live vault's.
    function test_fork_theLiveVenueSatisfiesTheConstructorAssetGuard() public {
        _requireFork();
        assertEq(IERC4626(STEAKHOUSE_USDG).asset(), USDG, "the live venue's asset must be USDG");
        assertEq(adapter.asset(), USDG, "adapter reports the asset it was built for");
        assertEq(adapter.venue(), STEAKHOUSE_USDG, "adapter reports the live venue");
        assertGt(IERC4626(STEAKHOUSE_USDG).totalAssets(), 0, "a venue with no assets would make the rest vacuous");
    }

    /// @dev THE DECIMAL MISMATCH IS REAL AND PINNED. The venue's shares are 18dp while USDG is 6dp, so share
    ///      counts and asset counts are NOT interchangeable. Pinned because a future venue swap to a 6dp-share
    ///      4626 would silently change every conversion in this adapter's callers.
    function test_fork_venueSharesAre18dpOverA6dpAsset() public {
        _requireFork();
        assertEq(IERC4626(STEAKHOUSE_USDG).decimals(), 18, "venue share decimals");
        assertEq(IERC20Metadata(USDG).decimals(), 6, "USDG decimals");
    }

    /// @dev WITHDRAWABLE IS maxWithdraw, MEASURED ON THE REAL VENUE. P8-02B's first suspicion is that
    ///      `withdrawable` is a single `maxWithdraw(this)` staticcall and that a 4626 whose `maxWithdraw` reads
    ///      more than FUNDABLE_READ_GAS makes the book treat the adapter as 0. This asserts the identity holds
    ///      against the live vault rather than a linear mock.
    ///
    ///      IT ASSERTS SHARES, NOT THE RETURN VALUE. {Erc4626VenueAdapter.deposit}'s return against this venue
    ///      has its own test, {test_fork_depositReturnsTheUnitsThatLeftTheAdapter}: until T-OP-008 it returned
    ///      ZERO here for a deposit that fully succeeded, because the venue forwards the deposit to Morpho Blue
    ///      inside the same call and the adapter measured the venue's own asset balance. This test keeps to its
    ///      own subject. Share balance is a real effect: it is zero unless the deposit actually happened.
    function test_fork_withdrawableEqualsMaxWithdrawOnTheLiveVenue() public {
        _requireFork();
        deal(USDG, earnVault, DEP);
        vm.startPrank(earnVault);
        IERC20(USDG).approve(address(adapter), DEP);
        adapter.deposit(DEP);
        vm.stopPrank();

        uint256 shares = IERC20(STEAKHOUSE_USDG).balanceOf(address(adapter));
        assertGt(shares, 0, "the venue minted no shares -- the deposit did not happen, so the rest is vacuous");
        assertEq(
            adapter.withdrawable(),
            IERC4626(STEAKHOUSE_USDG).maxWithdraw(address(adapter)),
            "withdrawable must BE maxWithdraw, not a nominal worth"
        );
        // DELIBERATELY NOT `assertGt(withdrawable, 0)`. Measured at this block: the adapter holds
        // 9_923_981_019_927_710_280_891 shares and the venue's `maxWithdraw` STILL RETURNS 0, in 2002 gas --
        // too cheap to be a queue walk. That is the venue reporting no payable liquidity right now, and
        // `withdrawable` relaying it faithfully is CORRECT and conservative, not a defect. Asserting a
        // positive here would pin an environmental condition this suite does not control and would go red
        // on a day the market is fully utilised. The INVARIANT is the identity above; the magnitude is not.
        //
        // THE OPERATIONAL FACT IS WORTH MORE THAN THE ASSERTION, so it is written here: a funded adapter can
        // contribute ZERO to fundability while its NAV is fully intact, because {totalAssets} is
        // `convertToAssets(balanceOf(this))` and does not consult `maxWithdraw`. Money visible to the share
        // price and invisible to the funding path is a state the Earn vault can reach against this venue.
        console2.log("shares %s, withdrawable %s", shares, adapter.withdrawable());
        assertEq(
            adapter.totalAssets(),
            IERC4626(STEAKHOUSE_USDG).convertToAssets(shares),
            "NAV must value the shares even when nothing is withdrawable"
        );
        assertGt(adapter.totalAssets(), 0, "the shares must be worth something, or the deposit bought nothing");
    }

    /// @dev A ROUND TRIP THROUGH THE LIVE VENUE. Deposit then withdraw, asserting the vault stand-in is paid
    ///      real money back. Keyed on SHARES and on the paid delta; the deposit's return value is pinned by
    ///      {test_fork_depositReturnsTheUnitsThatLeftTheAdapter}.
    function test_fork_depositThenWithdrawRoundTripsThroughTheLiveVenue() public {
        _requireFork();
        deal(USDG, earnVault, DEP);
        vm.startPrank(earnVault);
        IERC20(USDG).approve(address(adapter), DEP);
        adapter.deposit(DEP);
        assertGt(IERC20(STEAKHOUSE_USDG).balanceOf(address(adapter)), 0, "no shares: the deposit did not happen");

        // The withdraw leg is asserted CONDITIONALLY on the venue having payable liquidity, because it does
        // not always: see the note above. When it does, the paid delta must equal the reported amount; when
        // it does not, `withdraw` must be a clean no-op rather than a revert or a silent loss.
        uint256 avail = adapter.withdrawable();
        uint256 before = IERC20(USDG).balanceOf(earnVault);
        uint256 got = adapter.withdraw(avail, earnVault);
        vm.stopPrank();

        assertEq(IERC20(USDG).balanceOf(earnVault) - before, got, "the reported withdrawal must be the paid delta");
        if (avail == 0) {
            assertEq(got, 0, "a venue with nothing payable must withdraw nothing, not revert and not overpay");
            assertGt(adapter.totalAssets(), 0, "and the position must survive an unpayable withdraw attempt");
        } else {
            assertGt(got, 0, "the venue reported liquidity but paid nothing");
        }
    }

    /// @dev T-OP-008 ON THE LIVE VENUE. {Erc4626VenueAdapter.deposit} must return the base units that LEFT the
    ///      adapter. It used to measure the venue's own USDG balance delta, and this venue allocates the deposit
    ///      onward inside the same call (Deposit, then a transfer to its allocator 0x44ABc1d6, then a Morpho Blue
    ///      supply), so that delta was 0 for a deposit that fully succeeded and minted shares.
    function test_fork_depositReturnsTheUnitsThatLeftTheAdapter() public {
        _requireFork();
        deal(USDG, earnVault, DEP);
        uint256 venueBefore = IERC20(USDG).balanceOf(STEAKHOUSE_USDG);
        vm.startPrank(earnVault);
        IERC20(USDG).approve(address(adapter), DEP);
        uint256 deposited = adapter.deposit(DEP);
        vm.stopPrank();
        console2.log(
            "deposited %s; venue USDG before %s, after %s",
            deposited,
            venueBefore,
            IERC20(USDG).balanceOf(STEAKHOUSE_USDG)
        );

        assertGt(IERC20(STEAKHOUSE_USDG).balanceOf(address(adapter)), 0, "no shares: the deposit did not happen");
        assertEq(deposited, DEP, "deposit must return what left the adapter, not the venue's balance delta");
        assertEq(IERC20(USDG).balanceOf(earnVault), 0, "the vault stand-in paid the whole offer");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "the adapter keeps no float");
    }

    /// @dev WHY THE TEST ABOVE CAN FAIL, pinned as its own fact: the live venue's USDG balance does not rise by
    ///      the deposit, because it allocates onward in the same call. That is what the old venue-delta measure
    ///      could not see. ENVIRONMENTAL, deliberately kept apart from the adapter's invariant: if a re-pinned
    ///      block finds the venue HOLDING the deposit (an allocator cap, a paused market) this goes red while the
    ///      adapter is fine -- and the test above then no longer distinguishes the two measures, so red is right.
    function test_fork_theLiveVenueAllocatesTheDepositOnward() public {
        _requireFork();
        deal(USDG, earnVault, DEP);
        uint256 venueBefore = IERC20(USDG).balanceOf(STEAKHOUSE_USDG);
        vm.startPrank(earnVault);
        IERC20(USDG).approve(address(adapter), DEP);
        adapter.deposit(DEP);
        vm.stopPrank();
        assertGt(IERC20(STEAKHOUSE_USDG).balanceOf(address(adapter)), 0, "no shares: the deposit did not happen");
        assertLt(
            IERC20(USDG).balanceOf(STEAKHOUSE_USDG),
            venueBefore + DEP,
            "the live venue held the deposit at this block: the return test no longer tells the measures apart"
        );
    }

    /// @dev THE AUTHORISATION IS ANCHORED TO IMMUTABLE STATE, CHECKED AGAINST A LIVE VENUE. `onlyVault` reads
    ///      the immutable `vault`, so a stranger cannot move venue money even though the venue is real.
    function test_fork_aStrangerCannotMoveVenueMoney() public {
        _requireFork();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        adapter.deposit(1);
        vm.prank(stranger);
        vm.expectRevert();
        adapter.withdraw(1, stranger);
    }

    /// @dev THE FLOOR (T-588, added here by T-OP-031). Every other test in this file carries a chain-id guard that
    ///      SKIPS when no fork is attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 --
    ///      indistinguishable from a run in which every assertion held. This test carries no such guard. Under
    ///      `FOUNDRY_PROFILE=fork` it FAILS when the suite could not have executed, and it is the only test here
    ///      that can say so.
    ///
    ///      Its witness is `STEAKHOUSE_USDG`, the live venue every test in this file deposits into or reads through
    ///      the adapter; a fork that does not serve its code cannot exercise anything here. `_requireFork` and the
    ///      `setUp` early return stay: the floor is added beside the suite's own guards, not in place of them.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_earnMorphoForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(STEAKHOUSE_USDG, "EarnMorphoFork");
    }
}
