// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../src/interfaces/IChainlinkFeed.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {AccountFactory} from "../src/solo/AccountFactory.sol";

/// @notice Deploys one isolated 1-lot account factory (src/solo/) for ONE market. Does not touch the
///         pooled Vault, which is closed.
/// @dev One factory per market, one process per market: the same script deploys NVDA (its defaults) and
///      every Tier 1 market from `ops/markets/tier1.json` (stonkhousedotfun/callhouse), driven by
///      `script/DeploySoloBatch.sh`, which exports the per-market environment below. Run by hand:
///        DEPLOYER_PK=... ADMIN=0x... SAFE_FEE=0x... ASSET=0x... PRICE_FEED=0x... DEPOSIT_CAP=... EXPECTED_TICKER=TSLA \
///          forge script script/DeploySolo.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching \
///          --non-interactive --verify --verifier sourcify --chain 4663
///
///      ENVIRONMENT (every default is the live NVDA market; nothing here is read from a registry)
///        DEPLOYER_PK      required. Pays for the deploy.
///        ADMIN            DEFAULT_ADMIN_ROLE holder. Falls back to SAFE_ADMIN when unset (one of the two is required).
///        SAFE_FEE         required. `feeRecipient`: where the protocol fee consideration item pays.
///        ASSET            the Stock Token (18 dp)           default NVDA 0xd060…9EEC
///        PRICE_FEED       the Chainlink proxy (8 dp)        default NVDA/USD 0x379E…9F15
///        EXPECTED_TICKER  default "NVDA". The asset's `symbol()` must equal it and the feed's `description()`
///                         must contain it, which is what catches a fat-fingered ASSET or PRICE_FEED: a wrong
///                         pair of addresses is silent until the first fill, and by then it is collateralised.
///        DEPOSIT_CAP      per-account cap in asset base units, default 20e18. Must be > 0.
///        USDG, CLEARINGHOUSE, SEAPORT   shared dependencies, defaults below (our own Clear, Seaport 1.6).
///        PREFLIGHT_SKIP_CONDUIT_CONTROLLER  TEST ONLY (default false): skips the canonical-ConduitController
///                         check because `MockSeaport.information()` answers with a zero controller. Refused
///                         on chain 4663; the batch script unsets it, and the preflight prints a WARNING line
///                         when it is set.
///
///      PREFLIGHT. Every dependency is probed the way the contracts will use it, and any mismatch reverts
///      with a message naming the value read and the value expected, before anything is broadcast:
///      asset symbol / decimals / `uiMultiplier()` / `oraclePaused()` (the last two by low-level
///      staticcall, as ValoremLib probes them: a token without them is not a Stock Token), USDG decimals,
///      feed description / decimals / roundId / answer / freshness within MAX_PRICE_AGE, Clear `feeBps`
///      and fee switch and ERC-1155, Seaport 1.6 with the canonical ConduitController, and the cap.
///      The checks are copied from Deploy.s.sol rather than imported so this script never compiles the
///      closed Vault product.
contract DeploySolo is Script {
    /*//////////////////////////////////////////////////////////////
             CHAIN 4663 — all explorer/eth_call confirmed
    //////////////////////////////////////////////////////////////*/

    /// @dev OUR ValoremOptionsClearinghouse (DeployClear.s.sol, block 63,467,465), the live NVDA factory's.
    address internal constant CLEARINGHOUSE = 0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6;
    address internal constant SEAPORT_16 = 0x0000000000000068F116a894984e2DB1123eB395;
    /// @dev Seaport 1.6's canonical ConduitController; `authorizeOrder` runs before any transfer only on
    ///      that build (integrations/seaport.md), so the controller is pinned, not just the version string.
    address internal constant CONDUIT_CONTROLLER = 0x00000000F9490004C11Cef243f5400493c00Ad63;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    /// @dev Chainlink NVDA/USD AggregatorProxy, 8 decimals, description "RHNVDA / USD".
    address internal constant NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    /// @dev Seaport pulls the ERC-1155 directly: no conduit.
    bytes32 internal constant CONDUIT_KEY = bytes32(0);
    /// @dev Four days: the `us_equities_24/5` feeds publish nothing all weekend (worst observed gap 78.24 h).
    ///      The same window is the preflight's freshness bound, so a feed the factory would refuse to
    ///      write against on day one is refused at deploy.
    uint32 internal constant MAX_PRICE_AGE = 4 days;
    uint256 internal constant LAUNCH_DEPOSIT_CAP = 20e18;

    /// @dev Everything `run()` resolves from the environment, in one place so it can be logged before the
    ///      preflight and before the broadcast.
    struct Inputs {
        uint256 pk;
        address admin;
        address feeRecipient;
        address asset;
        address usdg;
        address clear;
        address seaport;
        address feed;
        uint256 cap;
        string ticker;
    }

    function run() external returns (AccountFactory factory) {
        Inputs memory in_ = _inputs();
        _logInputs(in_);
        _preflight(in_);

        vm.startBroadcast(in_.pk);
        factory = new AccountFactory(
            IERC20(in_.asset),
            IERC20(in_.usdg),
            IValoremClear(in_.clear),
            ISeaport(in_.seaport),
            IChainlinkFeed(in_.feed),
            MAX_PRICE_AGE,
            CONDUIT_KEY,
            in_.admin,
            in_.feeRecipient,
            in_.cap
        );
        vm.stopBroadcast();

        console2.log("");
        console2.log("AccountFactory", address(factory));
        console2.log("implementation", address(factory.implementation()));
        console2.log("admin         ", in_.admin);
        console2.log("feeRecipient  ", in_.feeRecipient);
        if (in_.admin.code.length == 0) {
            console2.log("WARNING: the admin is a PLAIN KEY, not a Safe. Whoever holds it has every admin power");
            console2.log("over this factory (policy, fee, cap, price age, every role grant).");
        }
        console2.log("NEXT: script/ConfigureSolo.s.sol grants KEEPER_ROLE and GUARDIAN_ROLE, then VerifySolo.s.sol.");
    }

    function _inputs() internal view returns (Inputs memory in_) {
        in_.pk = vm.envUint("DEPLOYER_PK");
        // DEFAULT_ADMIN_ROLE goes to exactly one address at construction. ADMIN wins if set, else SAFE_ADMIN
        // (the same rule as Deploy.s.sol: bootstrap with the deployer's own address, a Safe later).
        in_.admin = vm.envOr("ADMIN", address(0));
        if (in_.admin == address(0)) in_.admin = vm.envAddress("SAFE_ADMIN");
        in_.feeRecipient = vm.envAddress("SAFE_FEE");
        // Every address can be overridden for a fork rehearsal or another market.
        in_.asset = vm.envOr("ASSET", NVDA);
        in_.usdg = vm.envOr("USDG", USDG);
        in_.clear = vm.envOr("CLEARINGHOUSE", CLEARINGHOUSE);
        in_.seaport = vm.envOr("SEAPORT", SEAPORT_16);
        in_.feed = vm.envOr("PRICE_FEED", NVDA_USD_FEED);
        in_.cap = vm.envOr("DEPOSIT_CAP", LAUNCH_DEPOSIT_CAP);
        in_.ticker = vm.envOr("EXPECTED_TICKER", string("NVDA"));
    }

    function _logInputs(Inputs memory in_) internal view {
        console2.log(
            string.concat("inputs (chain ", vm.toString(block.chainid), ", block ", vm.toString(block.number), ")")
        );
        console2.log("  EXPECTED_TICKER", in_.ticker);
        console2.log("  ASSET          ", in_.asset);
        console2.log("  PRICE_FEED     ", in_.feed);
        console2.log("  USDG           ", in_.usdg);
        console2.log("  CLEARINGHOUSE  ", in_.clear);
        console2.log("  SEAPORT        ", in_.seaport);
        console2.log("  ADMIN          ", in_.admin);
        console2.log("  SAFE_FEE       ", in_.feeRecipient);
        console2.log("  DEPOSIT_CAP    ", in_.cap);
        console2.log("  MAX_PRICE_AGE  ", uint256(MAX_PRICE_AGE));
        console2.log("  DEPLOYER       ", vm.addr(in_.pk));
    }

    /*//////////////////////////////////////////////////////////////
                               PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @dev Refuse to deploy against dependencies that do not have the shape the factory assumes. Each
    ///      line prints `ok` as it passes; the first failure reverts with the values involved.
    function _preflight(Inputs memory in_) internal view {
        console2.log("preflight");
        _asset(in_.asset, in_.ticker);

        // Every unit convention in {Policy} rests on a 6-decimal USDG.
        require(IERC20Metadata(in_.usdg).decimals() == 6, "usdg decimals != 6");
        _ok("usdg decimals == 6");

        _feed(in_.feed, in_.ticker);
        _clear(in_.clear);
        _seaport(in_.seaport);

        // A zero cap would refuse every deposit: a factory nobody can use, deployed and paid for.
        require(in_.cap > 0, "DEPOSIT_CAP must be > 0");
        _ok(string.concat("DEPOSIT_CAP > 0 (", vm.toString(in_.cap), ")"));
        console2.log("preflight OK");
    }

    /// @dev The asset must be THE Stock Token of EXPECTED_TICKER: symbol equal, 18 decimals, and the two
    ///      ERC-8056 / issuer views ValoremLib relies on answering (probed by staticcall, its style, so the
    ///      message says which one is missing rather than a bare revert).
    function _asset(address asset, string memory ticker) internal view {
        string memory symbol = IERC20Metadata(asset).symbol();
        require(
            keccak256(bytes(symbol)) == keccak256(bytes(ticker)),
            string.concat(
                "asset symbol mismatch: ASSET ",
                vm.toString(asset),
                " is \"",
                symbol,
                "\", EXPECTED_TICKER is \"",
                ticker,
                "\""
            )
        );
        _ok(string.concat("asset symbol == EXPECTED_TICKER (", symbol, ")"));

        require(IERC20Metadata(asset).decimals() == 18, "asset decimals != 18");
        _ok("asset decimals == 18");

        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSelector(IStockToken.uiMultiplier.selector));
        require(ok && data.length == 32, "asset uiMultiplier() probe failed: not a Robinhood Stock Token?");
        uint256 multiplier = abi.decode(data, (uint256));
        require(multiplier > 0, "asset uiMultiplier() == 0");
        _ok(string.concat("asset uiMultiplier() answers, > 0 (", vm.toString(multiplier), ")"));

        (ok, data) = asset.staticcall(abi.encodeWithSelector(IStockToken.oraclePaused.selector));
        require(ok && data.length == 32, "asset oraclePaused() probe failed: not a Robinhood Stock Token?");
        require(!abi.decode(data, (bool)), "asset oraclePaused() is true: the issuer has halted its oracle");
        _ok("asset oraclePaused() answers, false");
    }

    /// @dev The feed must be THE feed of EXPECTED_TICKER (descriptions are "Robinhood TSLA / USD" or
    ///      "RHNVDA / USD", so a substring test), 8 decimals, and live: a round, a positive answer, and an
    ///      update no older than MAX_PRICE_AGE, the bound the factory itself will apply to every write.
    function _feed(address feed, string memory ticker) internal view {
        IChainlinkFeed f = IChainlinkFeed(feed);
        string memory description = f.description();
        require(
            _contains(description, ticker),
            string.concat(
                "feed description mismatch: PRICE_FEED ",
                vm.toString(feed),
                " is \"",
                description,
                "\", EXPECTED_TICKER is \"",
                ticker,
                "\""
            )
        );
        _ok(string.concat("feed description contains EXPECTED_TICKER (\"", description, "\")"));

        require(f.decimals() == 8, "unexpected feed decimals");
        _ok("feed decimals == 8");

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = f.latestRoundData();
        require(roundId != 0, "feed roundId == 0");
        _ok("feed roundId != 0");
        require(answer > 0, "feed answer <= 0");
        _ok(string.concat("feed answer > 0 (", vm.toString(answer), ")"));
        require(updatedAt != 0 && updatedAt <= block.timestamp, "feed updatedAt is zero or in the future");
        uint256 age = block.timestamp - updatedAt;
        require(
            age <= MAX_PRICE_AGE,
            string.concat(
                "feed is stale: age ", vm.toString(age), " s > MAX_PRICE_AGE ", vm.toString(uint256(MAX_PRICE_AGE))
            )
        );
        _ok(string.concat("feed updatedAt within MAX_PRICE_AGE (age ", vm.toString(age), " s)"));
    }

    /// @dev Clear sanity: upstream 6436c82 ships `feeBps == 15` as a constant and the switch off. The
    ///      factory honours a later switch-on only once the admin accepts the fee (`setValoremFeeAccepted`).
    function _clear(address clear) internal view {
        IValoremClear c = IValoremClear(clear);
        require(c.feeBps() == 15, "clear feeBps != 15");
        _ok("clear feeBps == 15");
        require(!c.feesEnabled(), "clear fee switch is ON: accept it explicitly after deploy, or wait");
        _ok("clear fee switch off");
        require(c.supportsInterface(0xd9b67a26), "clear is not ERC-1155");
        _ok("clear is ERC-1155");
    }

    /// @dev Seaport 1.6 with the canonical ConduitController, so `authorizeOrder` runs before any transfer
    ///      on every fulfilment path. The controller check can be skipped by the unit test only: the mock
    ///      answers with a zero controller, and there is no other way to drive this script against it.
    function _seaport(address seaport) internal view {
        (string memory version,, address controller) = ISeaport(seaport).information();
        require(keccak256(bytes(version)) == keccak256("1.6"), "seaport is not 1.6");
        _ok("seaport.information().version == 1.6");
        if (vm.envOr("PREFLIGHT_SKIP_CONDUIT_CONTROLLER", false)) {
            require(block.chainid != 4663, "PREFLIGHT_SKIP_CONDUIT_CONTROLLER is for tests only");
            console2.log(
                "  WARN  seaport conduit controller check SKIPPED (PREFLIGHT_SKIP_CONDUIT_CONTROLLER: tests only)"
            );
        } else {
            require(controller == CONDUIT_CONTROLLER, "unexpected conduit controller");
            _ok("seaport conduit controller is the canonical 0x00000000F9490004C11Cef243f5400493c00Ad63");
        }
    }

    function _ok(string memory what) internal pure {
        console2.log(string.concat("  ok    ", what));
    }

    /// @dev Plain substring test; both strings are short (a feed description and a ticker).
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; i++) {
            bool same = true;
            for (uint256 k; same && k < n.length; k++) {
                if (h[i + k] != n[k]) same = false;
            }
            if (same) return true;
        }
        return false;
    }
}
