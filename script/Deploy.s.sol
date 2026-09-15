// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../src/interfaces/IChainlinkFeed.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";

/// @notice Deploys one Callhouse vault.
/// @dev Every default below was confirmed on chain 4663 by the recon pass in ops/recon/ (stonkhousedotfun/callhouse)
///      and the integration dossiers in projects/callhouse/integrations/. Run with:
///        forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast --slow --non-interactive \
///          --verify --verifier sourcify --chain 4663
///      Source verification goes through Sourcify (chain 4663 is supported and Blockscout imports a
///      Sourcify match with one click); Blockscout's own API sits behind a Cloudflare challenge that
///      `forge` cannot pass. `--non-interactive` because the Vault is above EIP-170's 24,576 B and
///      forge's broadcast step otherwise stops at a prompt, although chain 4663 allows 98,304 B.
///
///      SeaportOrderLib and ValoremLib are `public` libraries and must both be deployed and linked.
///      Foundry does this automatically during `forge script`; if you link manually, pass both
///        --libraries src/lib/SeaportOrderLib.sol:SeaportOrderLib:<address>
///        --libraries src/lib/ValoremLib.sol:ValoremLib:<address>
///
///      NO REGISTRY (decision D16). The vault validates every option type it arms from the
///      clearinghouse itself, so there is no third-party registry to wire and nothing to get wrong
///      about which market's registry is which. THE CLEARINGHOUSE IS A DEPLOY-TIME CHOICE: the
///      default is Overcall's unmodified Valorem Clear instance (whose `feeTo` key holds only the
///      15 bps fee switch, which the vault treats as opt-in); `CLEARINGHOUSE=<addr>` points the vault
///      at an instance of our own from script/DeployClear.s.sol instead.
///
///      THE ZONE IS THE VAULT (decision D1, A(ii)). Every listing is a PARTIAL_RESTRICTED Seaport
///      order whose zone is the vault; the constructor derives that, so there is no zone parameter.
contract DeployVault is Script {
    /*//////////////////////////////////////////////////////////////
             CHAIN 4663 — all explorer/eth_call confirmed
    //////////////////////////////////////////////////////////////*/

    /// @dev Overcall's ValoremOptionsClearinghouse (upstream 6436c82, Sourcify exact match).
    address internal constant CLEARINGHOUSE = 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0;
    address internal constant SEAPORT_16 = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    /// @dev Chainlink NVDA/USD AggregatorProxy, phase 1, 8 decimals, description "RHNVDA / USD".
    address internal constant NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    /// @dev Seaport pulls the ERC-1155 directly: no conduit.
    bytes32 internal constant CONDUIT_KEY = bytes32(0);

    /// @dev Four days. The NVDA feed is `us_equities_24/5` and publishes nothing all weekend (worst
    ///      observed gap 78.24 h); a tighter window would block every Saturday and Sunday arm and
    ///      fill. See {Vault.maxPriceAge} and integrations/chainlink.md.
    uint32 internal constant MAX_PRICE_AGE = 4 days;

    /// @dev README (stonkhousedotfun/callhouse) "Policy (launch)": start at 20 NVDA, not a TVL race.
    uint256 internal constant LAUNCH_DEPOSIT_CAP = 20e18;

    function run() external returns (Vault vault) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        // DEFAULT_ADMIN_ROLE goes to exactly one address at construction. ADMIN wins if set, else
        // SAFE_ADMIN. Launch plan for now: ADMIN = the deployer's own address (bootstrap phase), with
        // the Safe taking over later through script/HandoverAdmin.s.sol (docs/DEPLOY.md).
        address admin = vm.envOr("ADMIN", address(0));
        if (admin == address(0)) admin = vm.envAddress("SAFE_ADMIN");
        address feeRecipient = vm.envAddress("SAFE_FEE");

        // Allow every address to be overridden for a fork rehearsal, a second market, or our own
        // clearinghouse instance.
        address asset = vm.envOr("ASSET", NVDA);
        address usdg = vm.envOr("USDG", USDG);
        address clear = vm.envOr("CLEARINGHOUSE", CLEARINGHOUSE);
        address seaport = vm.envOr("SEAPORT", SEAPORT_16);
        address feed = vm.envOr("PRICE_FEED", NVDA_USD_FEED);
        uint256 cap = vm.envOr("DEPOSIT_CAP", LAUNCH_DEPOSIT_CAP);

        _preflight(asset, usdg, clear, seaport, feed);

        vm.startBroadcast(pk);
        vault = new Vault(
            Vault.Config({
                asset: IERC20(asset),
                usdg: IERC20(usdg),
                clear: IValoremClear(clear),
                seaport: ISeaport(seaport),
                priceFeed: IChainlinkFeed(feed),
                maxPriceAge: MAX_PRICE_AGE,
                conduitKey: CONDUIT_KEY,
                admin: admin,
                feeRecipient: feeRecipient,
                depositCap: cap,
                name: vm.envOr("VAULT_NAME", string("Callhouse NVDA")),
                symbol: vm.envOr("VAULT_SYMBOL", string("cNVDA"))
            })
        );
        vm.stopBroadcast();

        console2.log("Vault           ", address(vault));
        console2.log("asset           ", asset);
        console2.log("clearinghouse   ", clear);
        console2.log("seaport (zone = vault)", seaport);
        console2.log("priceFeed       ", feed);
        console2.log("admin           ", admin);
        console2.log("feeRecipient    ", feeRecipient);
        console2.log("depositCap      ", cap);
        console2.log("");
        if (admin.code.length == 0) {
            console2.log("");
            console2.log("WARNING: the admin is a PLAIN KEY, not a Safe. Until HandoverAdmin.s.sol has granted the");
            console2.log("Safe and renounced this key, whoever holds it has every admin power over the vault.");
        }
        console2.log("NEXT: script/Configure.s.sol grants KEEPER_ROLE and GUARDIAN_ROLE (docs/DEPLOY.md).");
    }

    /// @dev Refuse to deploy against dependencies that do not have the shape the vault assumes.
    ///      Getting any of these wrong is silent until the first fill, and by then it is collateralised.
    function _preflight(address asset, address usdg, address clear, address seaport, address feed) internal view {
        // Decimals: every unit convention in {Policy} rests on an 18-decimal asset and a 6-decimal USDG.
        require(IERC20Metadata(asset).decimals() == 18, "asset decimals != 18");
        require(IERC20Metadata(usdg).decimals() == 6, "usdg decimals != 6");

        // Clear sanity: upstream 6436c82 ships `feeBps == 15` as a constant and the switch off. The
        // vault honours a later switch-on only once governance accepts the fee.
        IValoremClear c = IValoremClear(clear);
        require(c.feeBps() == 15, "clear feeBps != 15");
        require(!c.feesEnabled(), "clear fee switch is ON: accept it explicitly after deploy, or wait");
        require(c.supportsInterface(0xd9b67a26), "clear is not ERC-1155");

        // Seaport 1.6 with the canonical ConduitController, so `authorizeOrder` runs before any
        // transfer on every fulfilment path (integrations/seaport.md).
        (string memory version,, address controller) = ISeaport(seaport).information();
        require(keccak256(bytes(version)) == keccak256("1.6"), "seaport is not 1.6");
        require(controller == 0x00000000F9490004C11Cef243f5400493c00Ad63, "unexpected conduit controller");

        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(feed).latestRoundData();
        require(answer > 0, "feed answer <= 0");
        require(updatedAt > 0, "feed never updated");
        require(IChainlinkFeed(feed).decimals() == 8, "unexpected feed decimals");

        console2.log("preflight OK. clear feeTo:", c.feeTo());
        console2.log("feed answer (8dp):", uint256(answer));
        console2.log("feed age (s):", block.timestamp - updatedAt);
    }
}
