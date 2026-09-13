// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {Policy, PolicyParams} from "../src/Policy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";
import {IOvercallRegistry} from "../src/interfaces/IOvercallRegistry.sol";
import {IChainlinkFeed} from "../src/interfaces/IChainlinkFeed.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";

/// @notice Deploys one Callhouse vault.
/// @dev Every default below was confirmed on chain 4663 by the recon pass in ops/recon/.
///      Run with:
///        forge script script/Deploy.s.sol --rpc-url $RH_RPC --broadcast \
///          --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
///
///      SeaportOrderLib is a `public` library and must be deployed and linked. Foundry does this
///      automatically during `forge script`; if you link manually, pass
///      --libraries src/lib/SeaportOrderLib.sol:SeaportOrderLib:<address>.
contract DeployVault is Script {
    /*//////////////////////////////////////////////////////////////
             CHAIN 4663 — all explorer/eth_call confirmed
    //////////////////////////////////////////////////////////////*/

    address internal constant CLEARINGHOUSE = 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0;
    address internal constant SEAPORT_16 = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    /// @dev The NVDA market registry. NOT the top-level `registry` key in Overcall's frontend
    ///      config — that one is the JUGGERNAUT market and wiring it here would collateralise
    ///      calls with the wrong token. See ops/recon/R1-overcall-registry.md.
    address internal constant REGISTRY_NVDA = 0x8E973cE1A6884E28Ad3E377d5f670Bc0b463f4EA;

    /// @dev Overcall's premium fee recipient, taken from a real filled order's second
    ///      consideration item. Also the Valorem fee-switch key.
    address internal constant OVERCALL_FEE_RECIPIENT = 0xdAe7e82A2E7D566C67E87C164B05a1C560190782;

    /// @dev Chainlink NVDA/USD AggregatorProxy, phase 1, 8 decimals, description "RHNVDA / USD".
    address internal constant NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    /// @dev Overcall lists with no zone and no conduit. Seaport pulls the ERC-1155 directly.
    bytes32 internal constant CONDUIT_KEY = bytes32(0);
    address internal constant SEAPORT_ZONE = address(0);

    /// @dev Four days. The NVDA feed is `us_equities_24/5` and stops all weekend; a tighter
    ///      window would block every Saturday and Sunday write. See ops/recon/R5-price-feed.md.
    uint32 internal constant MAX_PRICE_AGE = 4 days;

    /// @dev README "Policy (launch)": start at 20 NVDA, not a TVL race.
    uint256 internal constant LAUNCH_DEPOSIT_CAP = 20e18;

    function run() external returns (Vault vault) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address admin = vm.envAddress("SAFE_ADMIN");
        address feeRecipient = vm.envAddress("SAFE_FEE");

        // Allow every address to be overridden for a fork rehearsal or a second market.
        address asset = vm.envOr("ASSET", NVDA);
        address usdg = vm.envOr("USDG", USDG);
        address clear = vm.envOr("CLEARINGHOUSE", CLEARINGHOUSE);
        address seaport = vm.envOr("SEAPORT", SEAPORT_16);
        address registry = vm.envOr("REGISTRY", REGISTRY_NVDA);
        address feed = vm.envOr("PRICE_FEED", NVDA_USD_FEED);
        address overcallFee = vm.envOr("OVERCALL_FEE_RECIPIENT", OVERCALL_FEE_RECIPIENT);
        uint256 cap = vm.envOr("DEPOSIT_CAP", LAUNCH_DEPOSIT_CAP);

        _preflight(asset, usdg, clear, registry, feed);

        vm.startBroadcast(pk);
        vault = new Vault(
            Vault.Config({
                asset: IERC20(asset),
                usdg: IERC20(usdg),
                clear: IValoremClear(clear),
                seaport: ISeaport(seaport),
                registry: IOvercallRegistry(registry),
                priceFeed: IChainlinkFeed(feed),
                maxPriceAge: MAX_PRICE_AGE,
                overcallFeeRecipient: overcallFee,
                conduitKey: CONDUIT_KEY,
                seaportZone: SEAPORT_ZONE,
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
        console2.log("registry        ", registry);
        console2.log("priceFeed       ", feed);
        console2.log("admin (Safe)    ", admin);
        console2.log("feeRecipient    ", feeRecipient);
        console2.log("depositCap      ", cap);
        console2.log("");
        console2.log("NEXT: run script/Configure.s.sol to grant KEEPER_ROLE and GUARDIAN_ROLE.");
    }

    /// @dev Refuse to deploy against a registry that does not describe this pair. Getting this
    ///      wrong is silent until the first roll, and by then it is collateralised.
    function _preflight(address asset, address usdg, address clear, address registry, address feed) internal view {
        IOvercallRegistry r = IOvercallRegistry(registry);
        require(r.collateralToken() == asset, "registry collateral != asset");
        require(r.exerciseToken() == usdg, "registry exercise != usdg");
        require(r.clearinghouse() == clear, "registry clearinghouse != clear");
        require(r.lotSize() == 1e18, "unexpected lot size");

        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(feed).latestRoundData();
        require(answer > 0, "feed answer <= 0");
        require(updatedAt > 0, "feed never updated");
        require(IChainlinkFeed(feed).decimals() == 8, "unexpected feed decimals");

        console2.log("preflight OK. registry cycle:", r.cycleNumber());
        console2.log("feed answer (8dp):", uint256(answer));
        console2.log("feed age (s):", block.timestamp - updatedAt);
    }
}
