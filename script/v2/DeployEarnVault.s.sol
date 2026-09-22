// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IOrderBook} from "../../src/v2/interfaces/IOrderBook.sol";
import {EarnVault} from "../../src/v2/periphery/earn/EarnVault.sol";
import {StockVenueAdapter} from "../../src/v2/periphery/earn/adapters/StockVenueAdapter.sol";
import {StockZap} from "../../src/v2/periphery/StockZap.sol";
import {PayoutRouter} from "../../src/v2/periphery/PayoutRouter.sol";
import {IClearinghouse} from "../../src/v2/interfaces/IClearinghouse.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @notice Deploys the Earn vault, and the zap beside it, for a v8 set that is already on chain.
///
///           DEPLOYER_PK=... V2_ACCESS_MANAGER=0x... V2_ORDER_BOOK=0x... V2_USDG=0x... V2_FEE_SPLITTER=0x... \
///             V2_CLEARINGHOUSE=0x... V2_PAYOUT_ROUTER=0x... \
///             forge script script/v2/DeployEarnVault.s.sol --rpc-url "$RH_RPC" --broadcast
///
/// @dev WHY THIS FILE HAD TO EXIST AT ALL, because the obvious fix was the wrong one (T-225). `EarnVault` is a
///      `roles.v8.json` target and it has an artifact constant (`ART_EARN_VAULT`), a `Contracts.earnVault` field and
///      a `V2_EARN_VAULT` input -- every piece of a deploy path except the part that constructs it. The tempting fix
///      was a `_create(ART_EARN_VAULT, ...)` inside `DeployV8`. THAT WOULD INVERT A DOCUMENTED DESIGN:
///      `DeployV8.s.sol:1307` `_externallySupplied()` deliberately lists `EarnVault`, `StockVenueAdapter`,
///      `HouseVault`, `HouseVaultFactory`, `Hedger` and `RewardsDistributorLender` as arriving BY ADDRESS, "created
///      by their own tasks", and its NatSpec says the list is explicit on purpose so a refactor cannot silently skip
///      a target that script DOES deploy. Five of those six tasks had never been written. This is one of them; the
///      pattern is `script/v2/DeployLenderRewards.s.sol`.
///
///      IT TOUCHES NOTHING ELSE. No `src/` change, no manifest change, and `DeployV8.s.sol`, `VerifyV8.s.sol` and
///      `script/v2/lib/V2DeployBase.sol` are all left alone. Unlike the lender distributor, `EarnVault` and
///      `StockVenueAdapter` ARE their own manifest keys, so their selector maps need no printed Safe ceremony: set
///      `V2_EARN_VAULT` (and `V2_STOCK_VENUE_ADAPTER`) and re-run `DeployV8`, whose `_mapTarget` maps them then.
///      Until that re-run their selectors stay unmapped and `VerifyV8` FAILS on them, which is the designed
///      behaviour and is stated in `docs/DEPLOY-V2.md` beside the ordering constraint.
///
///      EVERY PREFLIGHT IS A RE-DERIVATION, NOT A TRUSTED CONSTANT. Each input is interrogated on chain -- the
///      book's clearinghouse, the splitter's USDG, the manager's role constants -- because the failure this guards
///      against is not a missing address but a plausible WRONG one. `EarnVault`'s own constructor rejects a
///      code-less asset or splitter (`EarnVault.sol:226`), but a script that only finds out inside the constructor
///      hands the operator a bare selector instead of the variable that was wrong.
///
///      THE VENUE IS OPTIONAL AND THAT IS DELIBERATE. `Erc4626VenueAdapter`'s constructor requires an EXISTING
///      ERC-4626 whose `asset()` is the vault's USDG and fails closed on a zero address
///      (`src/v2/periphery/earn/adapters/Erc4626VenueAdapter.sol:60-67`). At the time of writing NO such venue is
///      named anywhere in this repository. So `V2_EARN_VENUE` is read but not required: without it the vault
///      deploys with `adapter == address(0)` and its venue sweeps are simply unreachable, which is the safe state.
///      Passing a zero venue to make the call compile would convert a MISSING OWNER INPUT into a deploy-time revert
///      that reads like a code bug.
///
///      THE ADAPTER IS NOT WIRED HERE EVEN WHEN IT IS DEPLOYED. `EarnVault.setAdapter` is `TREASURY_ADMIN`
///      (`roles.v8.json`), and after hand-over the deployer holds nothing, so this script PRINTS the call for the
///      Safe rather than attempting it and reverting. Same rule as the lender script's printed role rows.
contract DeployEarnVault is V2DeployBase {
    /// @dev The ERC-20 name and symbol of the vault's share token, mirrored from the unit fixture
    ///      (`test/v2/unit/EarnVault.t.sol:37-39`) rather than invented here, so the deployed share token matches
    ///      the one every test reasons about.
    string internal constant SHARE_NAME = "Stonkhouse Earn USDG";
    string internal constant SHARE_SYMBOL = "eUSDG";

    struct Inputs {
        address manager;
        address orderBook;
        address usdg;
        address splitter;
        address clearinghouse;
        address payoutRouter;
        /// @dev Optional. Zero means "no venue chosen yet", which is a supported outcome, not an error.
        address venue;
    }

    struct Built {
        address earnVault;
        address stockZap;
        address venueAdapter;
    }

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.manager = vm.envAddress("V2_ACCESS_MANAGER");
        in_.orderBook = vm.envAddress("V2_ORDER_BOOK");
        in_.usdg = vm.envAddress("V2_USDG");
        in_.splitter = vm.envAddress("V2_FEE_SPLITTER");
        in_.clearinghouse = vm.envOr("V2_CLEARINGHOUSE", address(0));
        in_.payoutRouter = vm.envOr("V2_PAYOUT_ROUTER", address(0));
        in_.venue = vm.envOr("V2_EARN_VENUE", address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                ENTRY
    //////////////////////////////////////////////////////////////*/

    function run() external returns (Built memory built) {
        Inputs memory in_ = inputsFromEnv();
        preflight(in_);

        uint256 pk = vm.envOr("DEPLOYER_PK", uint256(0));
        Signer memory deployer = pk != 0 ? Signer(pk, vm.addr(pk)) : Signer(0, vm.envAddress("V2_DEPLOYER"));

        _startBroadcast(deployer);
        EarnVault vault =
            new EarnVault(IOrderBook(in_.orderBook), in_.manager, in_.usdg, in_.splitter, SHARE_NAME, SHARE_SYMBOL);
        built.earnVault = address(vault);

        // The zap needs the v8 PayoutRouter, not the v7 UniV3PayoutAdapter: its constructor reads `usdg()`,
        // `v3Router()` and the v4 pool manager off it (`src/v2/periphery/StockZap.sol:36-48`). Skipped, loudly,
        // rather than half-built when the router or the clearinghouse is absent.
        if (in_.payoutRouter != address(0) && in_.clearinghouse != address(0)) {
            built.stockZap = address(new StockZap(in_.payoutRouter, in_.clearinghouse));
        }

        if (in_.venue != address(0)) {
            built.venueAdapter = address(new StockVenueAdapter(in_.manager, in_.usdg, in_.venue, built.earnVault));
        }
        vm.stopBroadcast();

        _readBack(in_, built);
        _report(in_, built);
    }

    /*//////////////////////////////////////////////////////////////
                              PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @notice Everything that must hold before a byte is deployed. Every failure names the variable that was wrong.
    function preflight(Inputs memory in_) public view {
        // 1. The manager is the v8 AccessManager, not an EOA and not some other manager. An EOA authority would make
        //    every `restricted` call revert and could never be replaced, because `setAuthority` is callable only by
        //    the authority itself (`src/v2/access/Managed.sol:56-60`).
        _code(in_.manager, "V2_ACCESS_MANAGER");
        require(
            AccessManager(in_.manager).ADMIN_ROLE() == 0
                && AccessManager(in_.manager).PUBLIC_ROLE() == type(uint64).max,
            string.concat("V2_ACCESS_MANAGER ", vm.toString(in_.manager), " does not answer as an AccessManager")
        );

        // 2. The book is a contract and it is on THIS manager. A vault pointed at a book under a different authority
        //    would place orders the rest of the set cannot govern.
        _code(in_.orderBook, "V2_ORDER_BOOK");
        // `IOrderBook` does not declare `authority()`; it is on the `Managed` base, so ask through the
        // OpenZeppelin interface rather than pulling the concrete `OrderBook` into a deploy script.
        address bookAuthority = IAccessManaged(in_.orderBook).authority();
        require(
            bookAuthority == in_.manager,
            string.concat(
                "V2_ORDER_BOOK ",
                vm.toString(in_.orderBook),
                " answers to ",
                vm.toString(bookAuthority),
                ", not V2_ACCESS_MANAGER: the vault and the book would be governed by different managers"
            )
        );

        // 3. USDG is a contract and is the 6-decimal unit the rest of v8 uses. Re-derived from the token, never
        //    assumed: an 18-decimal asset here would make every share price wrong by 10^12.
        _code(in_.usdg, "V2_USDG");
        uint8 decimals_ = IERC20Metadata(in_.usdg).decimals();
        require(
            decimals_ == 6,
            string.concat(
                "V2_USDG ", vm.toString(in_.usdg), " reports ", vm.toString(uint256(decimals_)), " decimals, not 6"
            )
        );

        // 4. The splitter has code. `EarnVault.sol:226` refuses a code-less splitter itself; this says which
        //    variable was wrong instead of leaving the operator with `NoSource()`.
        _code(in_.splitter, "V2_FEE_SPLITTER");

        // 5. The zap's two inputs are all-or-nothing, and when present they must agree on USDG. `StockZap`'s
        //    constructor enforces the agreement (`UnsupportedAsset`); this reports which pair disagreed.
        require(
            (in_.payoutRouter == address(0)) == (in_.clearinghouse == address(0)),
            "V2_PAYOUT_ROUTER and V2_CLEARINGHOUSE must be set together: the zap needs both or neither"
        );
        if (in_.payoutRouter != address(0)) {
            _code(in_.payoutRouter, "V2_PAYOUT_ROUTER");
            _code(in_.clearinghouse, "V2_CLEARINGHOUSE");
            address routerUsdg = PayoutRouter(payable(in_.payoutRouter)).usdg();
            require(
                routerUsdg == in_.usdg,
                string.concat(
                    "V2_PAYOUT_ROUTER pays ", vm.toString(routerUsdg), ", not V2_USDG ", vm.toString(in_.usdg)
                )
            );
            address houseUsdg = IClearinghouse(in_.clearinghouse).usdg();
            require(
                houseUsdg == in_.usdg,
                string.concat(
                    "V2_CLEARINGHOUSE holds ", vm.toString(houseUsdg), ", not V2_USDG ", vm.toString(in_.usdg)
                )
            );
        }

        // 6. The venue, when one is given, must be an ERC-4626 over the SAME USDG. `Erc4626VenueAdapter.sol:62`
        //    enforces this and reverts `UnsupportedAsset`; naming it here is the difference between "your venue is
        //    denominated in something else" and a bare selector. An ABSENT venue is allowed and reported, never
        //    silently skipped -- see {run}.
        if (in_.venue != address(0)) {
            _code(in_.venue, "V2_EARN_VENUE");
            address venueAsset = IERC4626(in_.venue).asset();
            require(
                venueAsset == in_.usdg,
                string.concat(
                    "V2_EARN_VENUE ",
                    vm.toString(in_.venue),
                    " is denominated in ",
                    vm.toString(venueAsset),
                    ", not V2_USDG ",
                    vm.toString(in_.usdg)
                )
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                               READ BACK
    //////////////////////////////////////////////////////////////*/

    /// @dev What was actually built, read off the deployed contracts rather than assumed from the arguments. The
    ///      constructor arguments and the deployed state can disagree -- that is the whole reason this exists.
    function _readBack(Inputs memory in_, Built memory built) internal view {
        EarnVault vault = EarnVault(built.earnVault);
        require(vault.authority() == in_.manager, "deployed EarnVault is not on the v8 AccessManager");
        require(vault.asset() == in_.usdg, "deployed EarnVault does not hold V2_USDG");
        require(
            vault.adapter() == address(0),
            "deployed EarnVault already has an adapter: this script never sets one, so the address is not fresh"
        );

        if (built.stockZap != address(0)) {
            StockZap zap = StockZap(payable(built.stockZap));
            require(zap.usdg() == in_.usdg, "deployed StockZap does not use V2_USDG");
            require(
                address(zap.clearinghouse()) == in_.clearinghouse, "deployed StockZap is not bound to V2_CLEARINGHOUSE"
            );
        }

        if (built.venueAdapter != address(0)) {
            StockVenueAdapter adapter = StockVenueAdapter(built.venueAdapter);
            require(adapter.vault() == built.earnVault, "deployed venue adapter is not bound to this EarnVault");
            require(
                !adapter.enabled(),
                "deployed venue adapter is already enabled: it must start off and be turned on by the Safe"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                REPORT
    //////////////////////////////////////////////////////////////*/

    /// @dev What the operator must do next, printed rather than attempted. Everything below is a privileged call the
    ///      deployer cannot make after hand-over.
    function _report(Inputs memory in_, Built memory built) internal pure {
        console2.log("EarnVault deployed");
        console2.log("  V2_EARN_VAULT", built.earnVault);
        if (built.stockZap != address(0)) {
            console2.log("  StockZap", built.stockZap);
        } else {
            console2.log("  StockZap SKIPPED: set V2_PAYOUT_ROUTER and V2_CLEARINGHOUSE to deploy it");
        }
        if (built.venueAdapter != address(0)) {
            console2.log("  V2_STOCK_VENUE_ADAPTER", built.venueAdapter);
        } else {
            console2.log("  venue adapter SKIPPED: no V2_EARN_VENUE, so the vault cannot sweep to a venue yet");
        }

        console2.log("NEXT, and none of it can be done by this script:");
        console2.log("  1. export V2_EARN_VAULT and re-run DeployV8 so _mapTarget maps the manifest selectors;");
        console2.log("     until then they are unmapped and VerifyV8 FAILS on them, by design.");
        if (built.venueAdapter != address(0)) {
            console2.log("  2. Safe, TREASURY_ADMIN: EarnVault.setAdapter(venueAdapter)");
            console2.log("  3. Safe, CONFIG_ADMIN:   StockVenueAdapter.setEnabled(true)");
        } else {
            console2.log("  2. choose an ERC-4626 venue denominated in V2_USDG, then re-run with V2_EARN_VENUE set.");
        }
        in_; // silence the unused-parameter warning without dropping it from the signature
    }
}
