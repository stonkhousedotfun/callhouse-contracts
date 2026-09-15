// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IValoremClear} from "../src/interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../src/interfaces/IChainlinkFeed.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";
import {AccountFactory} from "../src/solo/AccountFactory.sol";

/// @notice Deploys the isolated 1-lot account factory. Does not touch the pooled Vault.
contract DeploySolo is Script {
    address internal constant CLEARINGHOUSE = 0x53d7A6d0489Daf3d67b9A314e0eAB2B78Acab9C6;
    address internal constant SEAPORT_16 = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    bytes32 internal constant CONDUIT_KEY = bytes32(0);
    uint32 internal constant MAX_PRICE_AGE = 4 days;
    uint256 internal constant LAUNCH_DEPOSIT_CAP = 20e18;

    function run() external returns (AccountFactory factory) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address admin = vm.envOr("ADMIN", address(0));
        if (admin == address(0)) admin = vm.envAddress("SAFE_ADMIN");
        address feeRecipient = vm.envAddress("SAFE_FEE");

        address asset = vm.envOr("ASSET", NVDA);
        address usdg = vm.envOr("USDG", USDG);
        address clear = vm.envOr("CLEARINGHOUSE", CLEARINGHOUSE);
        address seaport = vm.envOr("SEAPORT", SEAPORT_16);
        address feed = vm.envOr("PRICE_FEED", NVDA_USD_FEED);
        uint256 cap = vm.envOr("DEPOSIT_CAP", LAUNCH_DEPOSIT_CAP);

        require(IERC20Metadata(asset).decimals() == 18, "asset decimals != 18");
        require(IERC20Metadata(usdg).decimals() == 6, "usdg decimals != 6");

        vm.startBroadcast(pk);
        factory = new AccountFactory(
            IERC20(asset),
            IERC20(usdg),
            IValoremClear(clear),
            ISeaport(seaport),
            IChainlinkFeed(feed),
            MAX_PRICE_AGE,
            CONDUIT_KEY,
            admin,
            feeRecipient,
            cap
        );
        vm.stopBroadcast();

        console2.log("AccountFactory", address(factory));
        console2.log("implementation", address(factory.implementation()));
        console2.log("admin         ", admin);
        console2.log("feeRecipient  ", feeRecipient);
        console2.log("NEXT: grant KEEPER_ROLE and GUARDIAN_ROLE, then keeper setWeek + listFor.");
    }
}
