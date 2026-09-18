// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {V2Constants} from "../../src/v2/interfaces/V2Constants.sol";
import {IMakerRegistry} from "../../src/v2/interfaces/IMakerRegistry.sol";
import {AutoRoller} from "../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../src/v2/Clearinghouse.sol";
import {KeeperRewards} from "../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../src/v2/OrderBook.sol";
import {MakerVault} from "../../src/v2/mm/MakerVault.sol";
import {ChainlinkFeedSource} from "../../src/v2/oracle/ChainlinkFeedSource.sol";
import {SettlementOracle} from "../../src/v2/oracle/SettlementOracle.sol";
import {IUniV3SwapRouter02} from "../../src/v2/periphery/PayoutDeps.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @notice Deploys the Stonkhouse v2 contract set on chain 4663 and wires it: ExpiryCalendar, ChainlinkFeedSource,
///         UniV3TwapSource, DataStreamsSource (deployed, never configured), SettlementOracle, Clearinghouse, OrderBook,
///         KeeperRewards, AutoRoller, UniV3PayoutAdapter, MakerRegistry, MakerVault, RewardsDistributor. Markets are
///         NOT registered here: `script/v2/RegisterMarkets.s.sol` does that, one market at a time.
/// @dev Driven by `script/v2/DeployV2Batch.sh`, which reads the registry with jq and exports the `V2_*` environment
///      (lib/V2DeployBase.sol lists it). By hand:
///        DEPLOYER_PK=... V2_ADMIN=0x... V2_GUARDIAN=0x... <the rest of V2_*> \
///          forge script script/v2/DeployV2.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching \
///          --non-interactive
///      Add `--verify --verifier sourcify --chain 4663` only when the explorer credential is configured;
///      the batch handles source publication separately from its read-only on-chain VerifyV2 check.
///
///      SIGNERS. The contracts are created from DEPLOYER_PK; every wiring call is sent from ADMIN_PK (default:
///      DEPLOYER_PK), whose address must be V2_ADMIN, because each constructor grants DEFAULT_ADMIN_ROLE to V2_ADMIN and
///      to nobody else. The deployer ends up holding no role. With no key at all the script broadcasts from the
///      addresses V2_DEPLOYER (default V2_ADMIN) and V2_ADMIN, which only an anvil node with those accounts unlocked
///      accepts (`--unlocked --sender`, the batch's --rehearse).
///
///      ORDER (the deploy and constructor facts are the C2-02..C2-12 hand-off notes):
///        CREATE from the deployer, in this order:
///          ExpiryCalendar(admin, V2_HOLIDAYS)            ChainlinkFeedSource(admin)       UniV3TwapSource(admin, usdg)
///          DataStreamsSource(admin, verifierProxy)       SettlementOracle(admin, guardian)
///          Clearinghouse(admin, usdg, calendar, feeRecipient, V2_BASE_URI)
///          OrderBook(clearinghouse, admin, guardian, feeRecipient, registry v2.fees)
///          KeeperRewards(usdg, admin)                    AutoRoller(orderBook, admin)
///          UniV3PayoutAdapter(admin, usdg, swapRouter02) MakerRegistry(admin)
///          MakerVault(orderBook, admin, mmQuoter, vault limits)   RewardsDistributor(usdg, admin)
///        then from the admin, each only when the chain does not already hold it:
///          structure   clearinghouse.grantRole(GUARDIAN_ROLE, guardian) (OrderBook and SettlementOracle grant it in
///                      their constructors); oracle.setClearinghouse (the only caller of oracle.pin);
///                      chainlinkSource / univ3Source / dataStreamsSource .setOracle(oracle, true) (the sources accept
///                      the oracle's pins: before RegisterMarkets, so before any series); oracle.setKeeperRewards;
///                      clearinghouse.setKeeperRewards; keeperRewards.setCaller(oracle | clearinghouse | autoRoller);
///                      autoRoller.setKeeperRewards; autoRoller.grantRole(PRICER_ROLE, pricer);
///                      orderBook.setMakerRegistry(makerRegistry); clearinghouse.setPayoutAdapter(adapter, slippage);
///                      makerVault QUOTER_ROLE (constructor; re-granted on resume if missing)
///          parameters  keeperRewards.setBounty x5 and setDailyCap, only where the value is still ZERO: a re-run never
///                      overwrites a value the admin tuned after launch (a deliberate 0 is the one it cannot tell).
///        Nothing is funded: KeeperRewards and MakerVault funding are owner steps (docs/DEPLOY-V2.md).
///
///      RESUME. Any V2_<CONTRACT> address in the environment is used instead of deploying that contract (it must have
///      code and link to the others). The batch passes the registry's recorded addresses with --resume, so a run that
///      died half way deploys only what is missing and sends only the wiring still missing.
///
///      CHECK MODE. V2_WIRING_CHECK=true sends nothing: every contract must be given, and the script reverts naming each
///      call a wiring pass would still send ("wiring incomplete"). The batch runs it before registering markets on a
///      set it did not deploy in the same invocation.
///
///      OUTPUT. `V2_ADDRESS <registry key> <address>` log lines, and with V2_DEPLOY_OUT (a path under ./broadcast) a
///      JSON object shaped like the registry's `v2.contracts`. Both are written while forge runs the script, BEFORE it
///      broadcasts; the batch checks each address has code before it records it.
contract DeployV2 is V2DeployBase {
    struct Inputs {
        Roles roles;
        External ext;
        Params params;
        uint32[] holidays;
        Contracts existing;
        uint256 expectChainId;
    }

    /// @notice What one run did: contracts created, admin calls sent, admin calls skipped because already done.
    struct Outcome {
        uint256 created;
        uint256 sent;
        uint256 skipped;
    }

    /*//////////////////////////////////////////////////////////////
                                  ENTRY
    //////////////////////////////////////////////////////////////*/

    function run() external returns (Contracts memory d) {
        Inputs memory in_ = inputsFromEnv();
        uint256 deployerPk = vm.envOr("DEPLOYER_PK", uint256(0));
        uint256 adminPk = vm.envOr("ADMIN_PK", deployerPk);
        Signer memory deployer = deployerPk != 0
            ? Signer(deployerPk, vm.addr(deployerPk))
            : Signer(0, vm.envOr("V2_DEPLOYER", in_.roles.admin));
        Signer memory admin = adminPk != 0 ? Signer(adminPk, vm.addr(adminPk)) : Signer(0, in_.roles.admin);
        require(
            admin.addr == in_.roles.admin,
            string.concat(
                "ADMIN_PK is not V2_ADMIN's key: it signs as ",
                vm.toString(admin.addr),
                ", V2_ADMIN is ",
                vm.toString(in_.roles.admin)
            )
        );
        require(
            block.chainid == in_.expectChainId,
            string.concat("chain id ", vm.toString(block.chainid), ", expected ", vm.toString(in_.expectChainId))
        );
        _logInputs(in_, deployer.addr);

        Outcome memory o;
        if (vm.envOr("V2_WIRING_CHECK", false)) {
            preflight(in_);
            d = in_.existing;
            uint256 pending = checkWiring(in_);
            require(pending == 0, string.concat("wiring incomplete: ", vm.toString(pending), " admin call(s) pending"));
            console2.log("WIRING COMPLETE: nothing to send");
        } else {
            (d, o) = runWith(in_, deployer, admin);
            console2.log("");
            console2.log(
                string.concat(
                    "DEPLOY DONE: ",
                    vm.toString(o.created),
                    " contract(s) created, ",
                    vm.toString(o.sent),
                    " admin call(s) sent, ",
                    vm.toString(o.skipped),
                    " already in place"
                )
            );
        }
        _logAddresses(d);
        string memory out = vm.envOr("V2_DEPLOY_OUT", string(""));
        if (bytes(out).length != 0) {
            vm.writeFile(out, toJson(d));
            console2.log("addresses written to", out);
        }
        if (in_.roles.admin.code.length == 0) {
            console2.log("WARNING: the admin is a PLAIN KEY, not a Safe. Whoever holds it holds every admin power of");
            console2.log(
                "every v2 contract (fees under their ceilings, pointers for new series, bounty budget, vault)."
            );
        }
    }

    /// @notice Deploy what `in_.existing` lacks, then send the wiring the chain does not hold yet.
    function runWith(Inputs memory in_, Signer memory deployer, Signer memory admin)
        public
        returns (Contracts memory d, Outcome memory o)
    {
        preflight(in_);
        (d, o.created) = _deploy(in_, deployer);
        _linkage(in_, d);
        Call[] memory calls;
        (calls, o.skipped) = _wiring(in_, d);
        for (uint256 i; i < calls.length; ++i) {
            console2.log(string.concat("  call  ", calls[i].what));
        }
        _execute(admin, calls);
        o.sent = calls.length;
        _postCheck(in_, d);
    }

    /// @notice The number of admin calls a wiring pass would still send to the complete set `in_.existing`. Read-only.
    function checkWiring(Inputs memory in_) public view returns (uint256 pending) {
        Contracts memory c = in_.existing;
        _code(c.expiryCalendar, "V2_EXPIRY_CALENDAR");
        _code(c.chainlinkSource, "V2_SOURCE_CHAINLINK");
        _code(c.univ3Source, "V2_SOURCE_UNIV3");
        _code(c.dataStreamsSource, "V2_SOURCE_DATA_STREAMS");
        _code(c.settlementOracle, "V2_SETTLEMENT_ORACLE");
        _code(c.clearinghouse, "V2_CLEARINGHOUSE");
        _code(c.orderBook, "V2_ORDER_BOOK");
        _code(c.keeperRewards, "V2_KEEPER_REWARDS");
        _code(c.autoRoller, "V2_AUTO_ROLLER");
        _code(c.payoutAdapter, "V2_PAYOUT_ADAPTER");
        _code(c.makerRegistry, "V2_MAKER_REGISTRY");
        _code(c.makerVault, "V2_MAKER_VAULT");
        _code(c.rewardsDistributor, "V2_REWARDS_DISTRIBUTOR");
        _linkage(in_, c);
        (Call[] memory calls,) = _wiring(in_, c);
        for (uint256 i; i < calls.length; ++i) {
            console2.log(string.concat("  PENDING  ", calls[i].what));
        }
        return calls.length;
    }

    /*//////////////////////////////////////////////////////////////
                                  INPUTS
    //////////////////////////////////////////////////////////////*/

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.roles = rolesFromEnv();
        in_.ext = externalFromEnv();
        in_.params = paramsFromEnv();
        in_.holidays = holidaysFromEnv();
        in_.existing = contractsFromEnv();
        in_.expectChainId = vm.envOr("V2_EXPECT_CHAIN_ID", CHAIN_ID_4663);
    }

    /*//////////////////////////////////////////////////////////////
                                PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @notice Refuses inputs the contracts would accept but the launch must not: each line prints `ok` as it passes and
    ///         the first failure reverts with the values involved, before anything is created or sent.
    function preflight(Inputs memory in_) public view {
        console2.log("preflight (deploy)");
        Roles memory r = in_.roles;
        _nonZero(r.admin, "V2_ADMIN");
        _nonZero(r.guardian, "V2_GUARDIAN");
        _nonZero(r.feeRecipient, "V2_FEE_RECIPIENT");
        _nonZero(r.cranker, "V2_CRANKER");
        _nonZero(r.pricer, "V2_PRICER");
        _nonZero(r.mmQuoter, "V2_MM_QUOTER");
        require(r.admin != r.guardian, "V2_ADMIN and V2_GUARDIAN must be different addresses");
        address[5] memory keys = [r.admin, r.guardian, r.cranker, r.pricer, r.mmQuoter];
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                require(
                    keys[i] != keys[j],
                    "admin, guardian, cranker, pricer and mmQuoter must be five different addresses (a bot key never holds admin or guardian powers)"
                );
            }
        }
        _ok("admin, guardian, cranker, pricer, mmQuoter: five distinct non-zero addresses; fee recipient non-zero");

        External memory e = in_.ext;
        _code(e.usdg, "V2_USDG");
        string memory symbol = IERC20Metadata(e.usdg).symbol();
        require(
            _eq(symbol, "USDG"),
            string.concat(
                "usdg symbol mismatch: V2_USDG ", vm.toString(e.usdg), " is \"", symbol, "\", expected \"USDG\""
            )
        );
        require(IERC20Metadata(e.usdg).decimals() == 6, "usdg decimals != 6");
        _ok("usdg: symbol USDG, 6 decimals");

        _code(e.swapRouter02, "V2_SWAP_ROUTER02");
        address factory = IUniV3SwapRouter02(e.swapRouter02).factory();
        require(
            factory == e.univ3Factory,
            string.concat(
                "swapRouter02.factory() ",
                vm.toString(factory),
                " is not V2_UNIV3_FACTORY ",
                vm.toString(e.univ3Factory)
            )
        );
        _code(factory, "swapRouter02.factory()");
        _ok("swapRouter02 has code, its factory() is V2_UNIV3_FACTORY and has code");
        _code(e.dataStreamsVerifier, "V2_DATA_STREAMS_VERIFIER");
        _ok("Data Streams VerifierProxy has code (DataStreamsSource is deployed disabled)");

        require(in_.holidays.length != 0, "V2_HOLIDAYS is empty");
        for (uint256 i = 1; i < in_.holidays.length; ++i) {
            require(in_.holidays[i] > in_.holidays[i - 1], "V2_HOLIDAYS must be strictly increasing day indexes");
        }
        _ok(string.concat("holidays: ", vm.toString(in_.holidays.length), " increasing day indexes"));

        Params memory p = in_.params;
        _checkFees(p.fees);
        _ok("fee parameters under their compiled ceilings");
        require(
            p.payoutSlippageBps <= V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS,
            "V2_PAYOUT_SLIPPAGE_BPS above MAX_PAYOUT_SLIPPAGE_CEIL_BPS (300)"
        );
        _ok(string.concat("payout slippage ", vm.toString(p.payoutSlippageBps), " bps <= 300"));
        require(p.bountySnapshot <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_SNAPSHOT above MAX_BOUNTY (1000000)");
        require(p.bountyFinalize <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_FINALIZE above MAX_BOUNTY (1000000)");
        require(p.bountySettle <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_SETTLE above MAX_BOUNTY (1000000)");
        require(p.bountyRedeem <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_REDEEM above MAX_BOUNTY (1000000)");
        require(p.bountyRoll <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_ROLL above MAX_BOUNTY (1000000)");
        require(p.bountyCancelStale <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_CANCEL_STALE above MAX_BOUNTY (1000000)");
        _ok("bounties <= MAX_BOUNTY (six actions from INTERFACE_VERSION 7)");
        if (p.dailyCap == 0) {
            _warn("V2_KEEPER_DAILY_CAP is 0: KeeperRewards will pay no bounty until the admin sets one");
        } else {
            _ok(string.concat("keeper daily cap ", vm.toString(p.dailyCap), " USDG base units"));
        }
        require(p.vaultLimits.maxSeriesUnits != 0, "V2_VAULT_MAX_SERIES_UNITS must be > 0");
        require(p.vaultLimits.maxTotalNotional != 0, "V2_VAULT_MAX_TOTAL_NOTIONAL must be > 0");
        require(p.vaultLimits.askToleranceBps <= V2Constants.BPS, "V2_VAULT_ASK_TOLERANCE_BPS above 10000");
        require(p.vaultLimits.maxBidBpsOfSpot <= V2Constants.BPS, "V2_VAULT_MAX_BID_BPS_OF_SPOT above 10000");
        // INTERFACE_VERSION 7 (c21): 0 is a spend freeze -- the quoter can unwind but cannot place a bid, take or
        // replace upwards. That is a deliberate incident lever (`setLimits`), never a deploy value.
        require(
            p.vaultLimits.maxDailyOutflow != 0,
            "V2_VAULT_MAX_DAILY_OUTFLOW must be > 0 (0 deploys the vault frozen: no bid, take or replace-up)"
        );
        _ok(
            string.concat(
                "maker vault limits: non-zero sizes, bps <= 10000, maxDailyOutflow ",
                vm.toString(uint256(p.vaultLimits.maxDailyOutflow)),
                " USDG base units per 24 h window"
            )
        );
        bytes memory uri = bytes(p.baseUri);
        require(uri.length != 0 && uri[uri.length - 1] == "/", "V2_BASE_URI must be non-empty and end with \"/\"");
        _ok(string.concat("base URI ", p.baseUri));

        _existing(in_.existing);
        console2.log("preflight OK");
    }

    /// @dev Every address given for resume must hold code.
    function _existing(Contracts memory c) internal view {
        _codeIfSet(c.expiryCalendar, "V2_EXPIRY_CALENDAR");
        _codeIfSet(c.chainlinkSource, "V2_SOURCE_CHAINLINK");
        _codeIfSet(c.univ3Source, "V2_SOURCE_UNIV3");
        _codeIfSet(c.dataStreamsSource, "V2_SOURCE_DATA_STREAMS");
        _codeIfSet(c.settlementOracle, "V2_SETTLEMENT_ORACLE");
        _codeIfSet(c.clearinghouse, "V2_CLEARINGHOUSE");
        _codeIfSet(c.orderBook, "V2_ORDER_BOOK");
        _codeIfSet(c.keeperRewards, "V2_KEEPER_REWARDS");
        _codeIfSet(c.autoRoller, "V2_AUTO_ROLLER");
        _codeIfSet(c.payoutAdapter, "V2_PAYOUT_ADAPTER");
        _codeIfSet(c.makerRegistry, "V2_MAKER_REGISTRY");
        _codeIfSet(c.makerVault, "V2_MAKER_VAULT");
        _codeIfSet(c.rewardsDistributor, "V2_REWARDS_DISTRIBUTOR");
    }

    function _codeIfSet(address a, string memory name) internal view {
        if (a == address(0)) return;
        require(a.code.length != 0, string.concat(name, " ", vm.toString(a), " has no code (resume)"));
        _skip(string.concat(name, " ", vm.toString(a), ": already deployed, reused"));
    }

    /*//////////////////////////////////////////////////////////////
                                  DEPLOY
    //////////////////////////////////////////////////////////////*/

    function _deploy(Inputs memory in_, Signer memory deployer) internal returns (Contracts memory d, uint256 created) {
        d = in_.existing;
        Roles memory r = in_.roles;
        address usdg = in_.ext.usdg;
        _startBroadcast(deployer);
        if (d.expiryCalendar == address(0)) {
            d.expiryCalendar = _create(ART_EXPIRY_CALENDAR, abi.encode(r.admin, in_.holidays));
            ++created;
        }
        if (d.chainlinkSource == address(0)) {
            d.chainlinkSource = _create(ART_CHAINLINK_SOURCE, abi.encode(r.admin));
            ++created;
        }
        if (d.univ3Source == address(0)) {
            d.univ3Source = _create(ART_UNIV3_SOURCE, abi.encode(r.admin, usdg));
            ++created;
        }
        if (d.dataStreamsSource == address(0)) {
            d.dataStreamsSource = _create(ART_DATA_STREAMS_SOURCE, abi.encode(r.admin, in_.ext.dataStreamsVerifier));
            ++created;
        }
        if (d.settlementOracle == address(0)) {
            d.settlementOracle = _create(ART_SETTLEMENT_ORACLE, abi.encode(r.admin, r.guardian));
            ++created;
        }
        if (d.clearinghouse == address(0)) {
            d.clearinghouse = _create(
                ART_CLEARINGHOUSE, abi.encode(r.admin, usdg, d.expiryCalendar, r.feeRecipient, in_.params.baseUri)
            );
            ++created;
        }
        if (d.orderBook == address(0)) {
            d.orderBook = _create(
                ART_ORDER_BOOK, abi.encode(d.clearinghouse, r.admin, r.guardian, r.feeRecipient, in_.params.fees)
            );
            ++created;
        }
        if (d.keeperRewards == address(0)) {
            d.keeperRewards = _create(ART_KEEPER_REWARDS, abi.encode(usdg, r.admin));
            ++created;
        }
        if (d.autoRoller == address(0)) {
            d.autoRoller = _create(ART_AUTO_ROLLER, abi.encode(d.orderBook, r.admin));
            ++created;
        }
        if (d.payoutAdapter == address(0)) {
            d.payoutAdapter = _create(ART_PAYOUT_ADAPTER, abi.encode(r.admin, usdg, in_.ext.swapRouter02));
            ++created;
        }
        if (d.makerRegistry == address(0)) {
            d.makerRegistry = _create(ART_MAKER_REGISTRY, abi.encode(r.admin));
            ++created;
        }
        if (d.makerVault == address(0)) {
            d.makerVault =
                _create(ART_MAKER_VAULT, abi.encode(d.orderBook, r.admin, r.mmQuoter, in_.params.vaultLimits));
            ++created;
        }
        if (d.rewardsDistributor == address(0)) {
            d.rewardsDistributor = _create(ART_REWARDS_DISTRIBUTOR, abi.encode(usdg, r.admin));
            ++created;
        }
        vm.stopBroadcast();
    }

    /// @dev CREATE from the artifact's init code: the set is ~117 kB of init code, more than a script contract holding
    ///      it as `new` expressions could itself be (98,304 B). forge records each as a CREATE from the broadcaster.
    function _create(string memory artifact, bytes memory args) internal returns (address a) {
        bytes memory initCode = abi.encodePacked(vm.getCode(artifact), args);
        assembly {
            a := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(a != address(0) && a.code.length != 0, string.concat("deploy failed: ", artifact));
    }

    /// @dev The immutable links between the contracts, for a set that mixes reused and new contracts.
    function _linkage(Inputs memory in_, Contracts memory d) internal view {
        require(Clearinghouse(d.clearinghouse).usdg() == in_.ext.usdg, "clearinghouse.usdg() is not V2_USDG");
        require(
            OrderBook(d.orderBook).clearinghouse() == d.clearinghouse,
            "orderBook.clearinghouse() is not the clearinghouse"
        );
        require(
            address(AutoRoller(d.autoRoller).orderBook()) == d.orderBook, "autoRoller.orderBook() is not the order book"
        );
        require(
            address(MakerVault(d.makerVault).orderBook()) == d.orderBook, "makerVault.orderBook() is not the order book"
        );
        require(address(KeeperRewards(d.keeperRewards).usdg()) == in_.ext.usdg, "keeperRewards.usdg() is not V2_USDG");
    }

    /*//////////////////////////////////////////////////////////////
                                  WIRING
    //////////////////////////////////////////////////////////////*/

    /// @dev The admin calls the chain does not hold yet, in dependency order, and how many are already in place.
    function _wiring(Inputs memory in_, Contracts memory d)
        internal
        view
        returns (Call[] memory calls, uint256 skipped)
    {
        Call[] memory buf = new Call[](29); // 28 through v6, + the v7 CANCEL_STALE bounty
        uint256 n;
        Roles memory r = in_.roles;
        Params memory p = in_.params;
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        SettlementOracle oracle = SettlementOracle(d.settlementOracle);
        KeeperRewards kr = KeeperRewards(d.keeperRewards);
        AutoRoller roller = AutoRoller(d.autoRoller);
        OrderBook book = OrderBook(d.orderBook);
        console2.log("wiring (admin)");

        // --- roles
        (n, skipped) = _grant(
            buf,
            n,
            skipped,
            d.clearinghouse,
            V2Constants.GUARDIAN_ROLE,
            r.guardian,
            "clearinghouse GUARDIAN_ROLE -> guardian"
        );
        (n, skipped) = _grant(
            buf, n, skipped, d.orderBook, V2Constants.GUARDIAN_ROLE, r.guardian, "orderBook GUARDIAN_ROLE -> guardian"
        );
        (n, skipped) = _grant(
            buf,
            n,
            skipped,
            d.settlementOracle,
            V2Constants.GUARDIAN_ROLE,
            r.guardian,
            "settlementOracle GUARDIAN_ROLE -> guardian"
        );
        (n, skipped) = _grant(
            buf, n, skipped, d.autoRoller, V2Constants.PRICER_ROLE, r.pricer, "autoRoller PRICER_ROLE -> pricer"
        );
        (n, skipped) = _grant(
            buf, n, skipped, d.makerVault, V2Constants.QUOTER_ROLE, r.mmQuoter, "makerVault QUOTER_ROLE -> mmQuoter"
        );

        // --- pointers
        if (oracle.clearinghouse() != d.clearinghouse) {
            buf[n++] = Call(
                d.settlementOracle,
                abi.encodeCall(oracle.setClearinghouse, (d.clearinghouse)),
                "settlementOracle.setClearinghouse(clearinghouse)"
            );
        } else {
            _skip("settlementOracle.clearinghouse() already the clearinghouse");
            ++skipped;
        }
        // The three sources accept the oracle's pins (INTERFACE_VERSION 6). Part of the deploy, so it lands before
        // RegisterMarkets and before any series can exist: pinning fails closed, so while a listed source does not list
        // the oracle every first series of an expiry reverts (V2Errors.SourceNotPinned(source, NotAuthorized)).
        (n, skipped) = _sourceOracle(buf, n, skipped, d.chainlinkSource, d.settlementOracle, "chainlinkSource");
        (n, skipped) = _sourceOracle(buf, n, skipped, d.univ3Source, d.settlementOracle, "univ3Source");
        (n, skipped) = _sourceOracle(buf, n, skipped, d.dataStreamsSource, d.settlementOracle, "dataStreamsSource");
        if (oracle.keeperRewards() != d.keeperRewards) {
            buf[n++] = Call(
                d.settlementOracle,
                abi.encodeCall(oracle.setKeeperRewards, (d.keeperRewards)),
                "settlementOracle.setKeeperRewards(keeperRewards)"
            );
        } else {
            _skip("settlementOracle.keeperRewards() already set");
            ++skipped;
        }
        if (address(ch.keeperRewards()) != d.keeperRewards) {
            buf[n++] = Call(
                d.clearinghouse,
                abi.encodeCall(ch.setKeeperRewards, (d.keeperRewards)),
                "clearinghouse.setKeeperRewards(keeperRewards)"
            );
        } else {
            _skip("clearinghouse.keeperRewards() already set");
            ++skipped;
        }
        if (ch.payoutAdapter() != d.payoutAdapter) {
            buf[n++] = Call(
                d.clearinghouse,
                abi.encodeCall(ch.setPayoutAdapter, (d.payoutAdapter, p.payoutSlippageBps)),
                string.concat(
                    "clearinghouse.setPayoutAdapter(payoutAdapter, ", vm.toString(p.payoutSlippageBps), " bps)"
                )
            );
        } else {
            _skip("clearinghouse.payoutAdapter() already the adapter (slippage bound left as set)");
            ++skipped;
        }
        if (address(roller.keeperRewards()) != d.keeperRewards) {
            buf[n++] = Call(
                d.autoRoller,
                abi.encodeCall(roller.setKeeperRewards, (d.keeperRewards)),
                "autoRoller.setKeeperRewards(keeperRewards)"
            );
        } else {
            _skip("autoRoller.keeperRewards() already set");
            ++skipped;
        }
        if (address(book.makerRegistry()) != d.makerRegistry) {
            buf[n++] = Call(
                d.orderBook,
                abi.encodeCall(book.setMakerRegistry, (IMakerRegistry(d.makerRegistry))),
                "orderBook.setMakerRegistry(makerRegistry)"
            );
        } else {
            _skip("orderBook.makerRegistry() already set");
            ++skipped;
        }

        // --- bounty callers
        (n, skipped) = _caller(buf, n, skipped, kr, d.settlementOracle, "settlementOracle");
        (n, skipped) = _caller(buf, n, skipped, kr, d.clearinghouse, "clearinghouse");
        (n, skipped) = _caller(buf, n, skipped, kr, d.autoRoller, "autoRoller");

        // --- parameters: only where still zero
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_SNAPSHOT, p.bountySnapshot, "SNAPSHOT");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_FINALIZE, p.bountyFinalize, "FINALIZE");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_SETTLE, p.bountySettle, "SETTLE");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_REDEEM, p.bountyRedeem, "REDEEM");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_ROLL, p.bountyRoll, "ROLL");
        // INTERFACE_VERSION 7 (c16): the permissionless stale-ask cancel. Paid at most once per ROLL, so the
        // dailyCap model is unchanged.
        (n, skipped) =
            _bounty(buf, n, skipped, kr, V2Constants.ACTION_CANCEL_STALE, p.bountyCancelStale, "CANCEL_STALE");
        if (kr.dailyCap() == 0 && p.dailyCap != 0) {
            buf[n++] = Call(
                d.keeperRewards,
                abi.encodeCall(kr.setDailyCap, (p.dailyCap)),
                string.concat("keeperRewards.setDailyCap(", vm.toString(p.dailyCap), ")")
            );
        } else {
            _skip(string.concat("keeperRewards.dailyCap() already ", vm.toString(kr.dailyCap())));
            ++skipped;
        }
        calls = _trim(buf, n);
    }

    function _grant(
        Call[] memory buf,
        uint256 n,
        uint256 skipped,
        address target,
        bytes32 role,
        address account,
        string memory what
    ) internal view returns (uint256, uint256) {
        if (IAccessControl(target).hasRole(role, account)) {
            _skip(string.concat(what, ": already granted"));
            return (n, skipped + 1);
        }
        buf[n] =
            Call(target, abi.encodeCall(IAccessControl.grantRole, (role, account)), string.concat("grantRole: ", what));
        return (n + 1, skipped);
    }

    /// @dev `source.setOracle(oracle, true)` unless the source already lists the oracle. The three sources share the
    ///      `isOracle` / `setOracle` surface, so one ChainlinkFeedSource-typed encoding serves all of them.
    function _sourceOracle(
        Call[] memory buf,
        uint256 n,
        uint256 skipped,
        address source,
        address oracle,
        string memory name
    ) internal view returns (uint256, uint256) {
        if (ChainlinkFeedSource(source).isOracle(oracle)) {
            _skip(string.concat(name, ".isOracle(settlementOracle) already true"));
            return (n, skipped + 1);
        }
        buf[n] = Call(
            source,
            abi.encodeCall(ChainlinkFeedSource.setOracle, (oracle, true)),
            string.concat(name, ".setOracle(settlementOracle, true)")
        );
        return (n + 1, skipped);
    }

    function _caller(
        Call[] memory buf,
        uint256 n,
        uint256 skipped,
        KeeperRewards kr,
        address caller,
        string memory name
    ) internal view returns (uint256, uint256) {
        if (kr.isCaller(caller)) {
            _skip(string.concat("keeperRewards caller ", name, ": already registered"));
            return (n, skipped + 1);
        }
        buf[n] = Call(
            address(kr),
            abi.encodeCall(kr.setCaller, (caller, true)),
            string.concat("keeperRewards.setCaller(", name, ", true)")
        );
        return (n + 1, skipped);
    }

    function _bounty(
        Call[] memory buf,
        uint256 n,
        uint256 skipped,
        KeeperRewards kr,
        bytes32 action,
        uint256 amount,
        string memory name
    ) internal view returns (uint256, uint256) {
        uint256 current = kr.bounty(action);
        if (current != 0 || amount == 0) {
            _skip(string.concat("keeperRewards bounty ", name, " already ", vm.toString(current)));
            return (n, skipped + 1);
        }
        buf[n] = Call(
            address(kr),
            abi.encodeCall(kr.setBounty, (action, amount)),
            string.concat("keeperRewards.setBounty(", name, ", ", vm.toString(amount), ")")
        );
        return (n + 1, skipped);
    }

    /// @dev Re-reads the wiring after the calls (under `forge script` this is the simulation; VerifyV2 is the gate).
    function _postCheck(Inputs memory in_, Contracts memory d) internal view {
        (Call[] memory left,) = _wiring(in_, d);
        require(left.length == 0, "post-check: wiring still incomplete after the admin calls");
        console2.log("post-check: wiring complete");
    }

    /*//////////////////////////////////////////////////////////////
                                  OUTPUT
    //////////////////////////////////////////////////////////////*/

    function _logInputs(Inputs memory in_, address deployer) internal view {
        console2.log(
            string.concat("inputs (chain ", vm.toString(block.chainid), ", block ", vm.toString(block.number), ")")
        );
        console2.log("  deployer            ", deployer);
        console2.log("  V2_ADMIN            ", in_.roles.admin);
        console2.log("  V2_GUARDIAN         ", in_.roles.guardian);
        console2.log("  V2_FEE_RECIPIENT    ", in_.roles.feeRecipient);
        console2.log("  V2_CRANKER          ", in_.roles.cranker);
        console2.log("  V2_PRICER           ", in_.roles.pricer);
        console2.log("  V2_MM_QUOTER        ", in_.roles.mmQuoter);
        console2.log("  V2_USDG             ", in_.ext.usdg);
        console2.log("  V2_SWAP_ROUTER02    ", in_.ext.swapRouter02);
        console2.log("  V2_UNIV3_FACTORY    ", in_.ext.univ3Factory);
        console2.log("  V2_DATA_STREAMS_VERIFIER", in_.ext.dataStreamsVerifier);
    }

    function _logAddresses(Contracts memory d) internal pure {
        console2.log("V2_ADDRESS expiryCalendar", d.expiryCalendar);
        console2.log("V2_ADDRESS sources.chainlink", d.chainlinkSource);
        console2.log("V2_ADDRESS sources.univ3", d.univ3Source);
        console2.log("V2_ADDRESS sources.dataStreams", d.dataStreamsSource);
        console2.log("V2_ADDRESS settlementOracle", d.settlementOracle);
        console2.log("V2_ADDRESS clearinghouse", d.clearinghouse);
        console2.log("V2_ADDRESS orderBook", d.orderBook);
        console2.log("V2_ADDRESS keeperRewards", d.keeperRewards);
        console2.log("V2_ADDRESS autoRoller", d.autoRoller);
        console2.log("V2_ADDRESS payoutAdapter", d.payoutAdapter);
        console2.log("V2_ADDRESS makerRegistry", d.makerRegistry);
        console2.log("V2_ADDRESS makerVault", d.makerVault);
        console2.log("V2_ADDRESS rewardsDistributor", d.rewardsDistributor);
    }

    /// @notice The set as JSON in the shape of the registry's `v2.contracts`.
    function toJson(Contracts memory d) public pure returns (string memory) {
        return string.concat(
            "{\n  \"clearinghouse\": ",
            _q(d.clearinghouse),
            ",\n  \"orderBook\": ",
            _q(d.orderBook),
            ",\n  \"settlementOracle\": ",
            _q(d.settlementOracle),
            ",\n  \"expiryCalendar\": ",
            _q(d.expiryCalendar),
            ",\n  \"keeperRewards\": ",
            _q(d.keeperRewards),
            ",\n  \"autoRoller\": ",
            _q(d.autoRoller),
            ",\n  \"payoutAdapter\": ",
            _q(d.payoutAdapter),
            ",\n  \"makerVault\": ",
            _q(d.makerVault),
            ",\n  \"makerRegistry\": ",
            _q(d.makerRegistry),
            ",\n  \"rewardsDistributor\": ",
            _q(d.rewardsDistributor),
            ",\n  \"sources\": {\"chainlink\": ",
            _q(d.chainlinkSource),
            ", \"univ3\": ",
            _q(d.univ3Source),
            ", \"dataStreams\": ",
            _q(d.dataStreamsSource),
            "}\n}\n"
        );
    }

    function _q(address a) internal pure returns (string memory) {
        return a == address(0) ? "null" : string.concat("\"", vm.toString(a), "\"");
    }
}
