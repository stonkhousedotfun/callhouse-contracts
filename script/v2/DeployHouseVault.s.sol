// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IExpiryCalendar} from "../../src/v2/interfaces/IExpiryCalendar.sol";
import {IOrderBook} from "../../src/v2/interfaces/IOrderBook.sol";
import {ISettlementOracle} from "../../src/v2/interfaces/ISettlementOracle.sol";
import {HouseVault} from "../../src/v2/periphery/house/HouseVault.sol";
import {HouseVaultFactory} from "../../src/v2/periphery/house/HouseVaultFactory.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @notice Deploys the `HouseVaultFactory` for a v8 set that is already on chain, and creates the launch-set House
///         vaults through it. `createVault` is `restricted` (LISTING), so WHO creates depends on what the manager
///         answers: the deployer directly while it still holds LISTING at delay 0 (T-OP-153's deferred hand-back
///         window, the launch path); the Admin Safe through the LISTING schedule (a rehearsal fork impersonates it;
///         a real Safe signs); and when nobody here can, the exact Safe calls are PRINTED and the run stops.
///
///           # factory + the vaults (launch: inside the deferred window) or the printed Safe calls (post-launch)
///           DEPLOYER_PK=... V2_ACCESS_MANAGER=0x... V2_ORDER_BOOK=0x... V2_EXPIRY_CALENDAR=0x... \
///             V2_SETTLEMENT_ORACLE=0x... V2_FEE_SPLITTER=0x... V2_ADMIN_SAFE=0x... \
///             V2_TICKERS=NVDA,SPCX V2_MARKET_NVDA_ASSET=0x... V2_MARKET_SPCX_ASSET=0x... \
///             V2_HOUSE_LIMITS_FILE=script/v2/fixtures/house-limits.v8.json \
///             forge script script/v2/DeployHouseVault.s.sol --rpc-url "$RH_RPC" --broadcast
///
/// @dev WHY THIS FILE EXISTS (T-OP-141, the sibling of T-OP-116). `HouseVaultFactory` and `HouseVault` are two of
///      the six `roles.v8.json` targets `DeployV8.s.sol` lists in `_externallySupplied()` as "created by their own
///      tasks" and supplied BY ADDRESS (`V2_HOUSE_VAULT_FACTORY`, `V2_HOUSE_VAULT`; `V2DeployBase.sol:353-354`).
///      Until this file the only construction of the pair in the repository was `DevDeploy.s.sol:664-692`, a dev
///      path that grants LISTING to the admin key at delay 0 and calls `createVault` from it, and T-OP-116's
///      externals stage therefore reports both as UNSUPPLIED by name. The pattern here is
///      `script/v2/DeployEarnVault.s.sol` (constructor inputs by `V2_*` name, preflight by re-derivation, read-back
///      off the deployed contract, printed Safe calls for what the deployer cannot do).
///
///      THE TWO HALVES HAVE DIFFERENT AUTHORITY, AND THE SCRIPT SAYS SO INSTEAD OF BLURRING IT.
///        1. The FACTORY is a plain `new`: anyone can deploy it, its `Managed(authority_)` binds it to the v8
///           manager, and it holds no role. The deployer sends it.
///        2. Each VAULT is `HouseVaultFactory.createVault`, `restricted` on the factory: `roles.v8.json` maps
///           `createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)` to LISTING, and
///           after hand-over LISTING is held by the Admin Safe with `delaysS.LISTING` (read, never typed). So the
///           call is scheduled on the manager, waited out, then sent to the FACTORY by the Safe -- `manager.execute`
///           would make the factory see `msg.sender == manager` (06-QUIRKS D.2), so the execution is a direct
///           target call, exactly as `RegisterMarkets.s.sol:_executeScheduled` sends the LISTING lane's calls.
///
///      THE WAIT IS A NODE-CLOCK JUMP BETWEEN TWO FORGE INVOCATIONS, NOT `vm.warp`. The row text sketched
///      "schedule, vm.warp past the delay, execute" in one run. `RegisterMarkets.s.sol:1149-1156` explains why that
///      cannot work under `--broadcast`: forge simulates first and replays the collected transactions on the node
///      afterwards, where the AccessManager still sees the delay unexpired and reverts. So this script takes the
///      same `V2_SCHEDULE` / `V2_SCHEDULE_PHASE` contract the registration path takes:
///        - `V2_SCHEDULE` unset:            the vault calls are sent raw ONLY if `canCall` says immediate (LISTING
///                                          at delay 0, the DevDeploy shape); a delayed signer is refused BEFORE
///                                          anything is broadcast, with the instruction below.
///        - `V2_SCHEDULE_PHASE=schedule`:   the Safe schedules `createVault` on the manager (impersonated on a
///                                          fork: `V2_UNLOCKED_ADMIN=true`; a real Safe signs its own schedule).
///        - `V2_SCHEDULE_PHASE=execute`:    after the clock has moved past `delaysS.LISTING`, the Safe calls the
///                                          factory directly; the vault addresses are read back from `vaultOf`.
///        - NO Safe signer (no `V2_UNLOCKED_ADMIN`, no `ADMIN_PK`) but the DEPLOYER can call `createVault`
///          IMMEDIATELY (`canCall` says so: DeployV8's transient LISTING self-grant during a T-OP-153
///          `V2_DEFER_HANDBACK` window, or the DevDeploy shape): the deployer creates the vaults directly, no
///          schedule. Read from the manager, never assumed -- after hand-over the same deployer gets "not
///          immediate" and falls through to the next case.
///        - NOBODY here can create: the script deploys the factory (or reuses `V2_HOUSE_VAULT_FACTORY` if set),
///          PRINTS every Safe call with target, selector, calldata and the delay, writes them to
///          `V2_HOUSE_DEPLOY_OUT` under `pendingCreateVault` with `safeActionRequired: true`, and returns 0 without
///          sending a vault call. A forge script cannot choose its process exit code, so the rc=90 "Safe action
///          required" stop is the CALLER's (T-OP-116's externals stage reads `safeActionRequired` and exits 90);
///          a caller that wants the stop as a NON-ZERO exit sets `V2_HOUSE_REQUIRE_VAULTS=true`, and the script
///          then reverts naming the first vault it could not create -- after the report, so the calls are printed.
///
///      THE LIMITS COME FROM ONE FILE, PER TICKER, AND A MISSING VALUE IS A STOP BY NAME (coordinator amendment
///      M-b02234cf247c4d5f, owner decision 05:50Z; it replaced the per-field `V2_HOUSE_LIMITS_*` env seam of the
///      first draft). `HouseVault.Limits` (`HouseVault.sol:99-106`) mirrors `MakerVault.Limits` field for field.
///      `V2_HOUSE_LIMITS_FILE` names a JSON file keyed by ticker, each ticker an object with the six fields under
///      the struct's own names:
///        { "NVDA": { "maxSeriesUnits": u64, "maxTotalNotional": u128, "askToleranceBps": u16,
///                    "maxBidBpsOfSpot": u16, "maxOrderLifetime": u32, "maxDailyOutflow": u128 }, "SPCX": {...} }
///      T-OP-158 produces `script/v2/fixtures/house-limits.v8.json` in that shape; until it lands, a run STOPs on
///      the missing file, and a launch ticker or field the file lacks STOPs naming the ticker and the field. There
///      is NO default: `DevDeploy.s.sol:855-863`'s literal is a dev vault's guard rail and does not reach a launch
///      vault through this script by any flag. The test pins the STOP for each of file / ticker / field.
///      `foundry.toml` `fs_permissions` must grant READ on the file's path for `vm.readFile` to open it (scripts
///      obey the same list as tests; the manifest has its own entry) -- that grant travels with the file (T-OP-158).
///
///      WHAT THIS SCRIPT DOES NOT DO, ON PURPOSE. It maps no selectors: a vault deployed by the factory is born with
///      no `(target, selector) -> role` rows (`HouseVaultFactory.sol` NatSpec), and mapping them is ADMIN work with
///      `delaysS.ADMIN` (48 h) that T-OP-116's mapping sub-step owns; the rows are printed here as Safe calls so
///      nothing is forgotten, and NOT sent. It grants no roles (`DevDeploy._wireHouseVault` grants TREASURY_ADMIN /
///      QUOTER / CONFIG_ADMIN / GUARDIAN to the dev admin; on v8 those holders are the manifest's, already granted by
///      DeployV8 step 6). It writes no registry: `v2.contracts.houseVaultFactory` and the vault key(s) are written
///      back by the shell stage that ran it, from the JSON this script writes.
///
///      ONE VAULT PER LAUNCH TICKER, NAMED FROM THE TICKER. `DevDeploy` hard-codes "Stonkhouse House NVDA" /
///      "hNVDA" for `markets[0]`; here the name and symbol are derived per ticker ("Stonkhouse House <T>", "h<T>")
///      so the launch set (`V2_TICKERS`, exported by the registry projection from `launchSet.markets`; NVDA and SPCX
///      today) gets one vault each. THE REGISTRY HOME, ruled by the coordinator on this row's question
///      (owner answer A): `v2.contracts.houseVault` stays ONE address and is the FIRST launch
///      ticker's vault, so VerifyV8's single `HouseVault` target and every address|null consumer keep working; the
///      per-ticker vaults live at `markets[].v2.houseVault`, a per-market write-back field like `registeredAt`
///      (the callhouse schema row is the coordinator's, not this one). So the JSON out carries BOTH: `houseVault`
///      (the first ticker's, or zero until it exists) and `houseVaults` keyed by ticker.
contract DeployHouseVault is V2DeployBase {
    using stdJson for string;

    /// @dev The env name of the limits file, and the six field names as the file (and the struct) spell them.
    string internal constant LIMITS_FILE_ENV = "V2_HOUSE_LIMITS_FILE";
    string internal constant F_MAX_SERIES_UNITS = "maxSeriesUnits";
    string internal constant F_MAX_TOTAL_NOTIONAL = "maxTotalNotional";
    string internal constant F_ASK_TOLERANCE_BPS = "askToleranceBps";
    string internal constant F_MAX_BID_BPS_OF_SPOT = "maxBidBpsOfSpot";
    string internal constant F_MAX_ORDER_LIFETIME = "maxOrderLifetime";
    string internal constant F_MAX_DAILY_OUTFLOW = "maxDailyOutflow";

    /// @dev The manifest target names of the pair, as `roles.v8.json` and `DeployV8._externallySupplied` spell them.
    string internal constant TARGET_FACTORY = "HouseVaultFactory";
    string internal constant TARGET_VAULT = "HouseVault";
    /// @dev The role that guards `createVault`, read from the manifest at run time; the name is pinned here only so
    ///      a manifest that moved the selector to another lane reddens the preflight by name.
    string internal constant CREATE_VAULT_ROLE = "LISTING";

    struct Inputs {
        address manager; // V2_ACCESS_MANAGER
        address orderBook; // V2_ORDER_BOOK
        address calendar; // V2_EXPIRY_CALENDAR
        address oracle; // V2_SETTLEMENT_ORACLE
        address splitter; // V2_FEE_SPLITTER
        address adminSafe; // V2_ADMIN_SAFE: the LISTING holder that creates vaults
        /// @dev Optional. A factory already deployed by an earlier phase of this script (`V2_HOUSE_VAULT_FACTORY`);
        ///      zero means "deploy one".
        address factory;
        string[] tickers; // V2_TICKERS
        address[] underlyings; // V2_MARKET_<T>_ASSET, in ticker order
        HouseVault.Limits[] limits; // per ticker, from V2_HOUSE_LIMITS_FILE
        string limitsFile; // the path the limits were read from (reported)
    }

    struct Built {
        address factory;
        address[] vaults; // per ticker; zero when the vault call was printed rather than sent
        bool safeActionRequired; // true when at least one createVault was printed, not sent
    }

    /*//////////////////////////////////////////////////////////////
                                INPUTS
    //////////////////////////////////////////////////////////////*/

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.manager = vm.envAddress("V2_ACCESS_MANAGER");
        in_.orderBook = vm.envAddress("V2_ORDER_BOOK");
        in_.calendar = vm.envAddress("V2_EXPIRY_CALENDAR");
        in_.oracle = vm.envAddress("V2_SETTLEMENT_ORACLE");
        in_.splitter = vm.envAddress("V2_FEE_SPLITTER");
        in_.adminSafe = vm.envAddress("V2_ADMIN_SAFE");
        in_.factory = vm.envOr("V2_HOUSE_VAULT_FACTORY", address(0));
        in_.tickers = vm.envString("V2_TICKERS", ",");
        in_.underlyings = new address[](in_.tickers.length);
        for (uint256 i; i < in_.tickers.length; ++i) {
            in_.underlyings[i] = vm.envAddress(_mk(in_.tickers[i], "ASSET"));
        }
        in_.limitsFile = vm.envString(LIMITS_FILE_ENV);
        in_.limits = limitsFromFile(in_.limitsFile, in_.tickers);
    }

    /// @notice The per-ticker guard rails from the limits file. STOPs by name on a missing file, a ticker the
    ///         file lacks, or a field the ticker's object lacks; there is no default.
    function limitsFromFile(string memory path, string[] memory tickers)
        public
        view
        returns (HouseVault.Limits[] memory ls)
    {
        require(bytes(path).length != 0, string.concat(LIMITS_FILE_ENV, " is not set: the House vault limits file"));
        require(
            vm.exists(path),
            string.concat(
                LIMITS_FILE_ENV, " names ", path, ", which does not exist (T-OP-158 produces house-limits.v8.json)"
            )
        );
        string memory json = vm.readFile(path);
        ls = new HouseVault.Limits[](tickers.length);
        for (uint256 i; i < tickers.length; ++i) {
            string memory t = tickers[i];
            require(
                vm.keyExistsJson(json, string.concat(".", t)),
                string.concat(path, " has no entry for launch ticker ", t, ": every launch ticker needs its six limits")
            );
            ls[i] = HouseVault.Limits({
                maxSeriesUnits: _u64(
                    _field(json, path, t, F_MAX_SERIES_UNITS), string.concat(t, ".", F_MAX_SERIES_UNITS)
                ),
                maxTotalNotional: _u128(
                    _field(json, path, t, F_MAX_TOTAL_NOTIONAL), string.concat(t, ".", F_MAX_TOTAL_NOTIONAL)
                ),
                askToleranceBps: _u16(
                    _field(json, path, t, F_ASK_TOLERANCE_BPS), string.concat(t, ".", F_ASK_TOLERANCE_BPS)
                ),
                maxBidBpsOfSpot: _u16(
                    _field(json, path, t, F_MAX_BID_BPS_OF_SPOT), string.concat(t, ".", F_MAX_BID_BPS_OF_SPOT)
                ),
                maxOrderLifetime: _u32(
                    _field(json, path, t, F_MAX_ORDER_LIFETIME), string.concat(t, ".", F_MAX_ORDER_LIFETIME)
                ),
                maxDailyOutflow: _u128(
                    _field(json, path, t, F_MAX_DAILY_OUTFLOW), string.concat(t, ".", F_MAX_DAILY_OUTFLOW)
                )
            });
        }
    }

    /// @dev One field of one ticker, or a revert naming the file, the ticker and the field.
    function _field(string memory json, string memory path, string memory t, string memory f)
        internal
        view
        returns (uint256)
    {
        string memory key = string.concat(".", t, ".", f);
        require(
            vm.keyExistsJson(json, key),
            string.concat(path, ": ", t, " has no ", f, ": every launch ticker needs all six HouseVault.Limits fields")
        );
        return json.readUint(key);
    }

    /*//////////////////////////////////////////////////////////////
                                ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @dev How the vault calls may be sent, decided by the caller from its environment (see {run}) or by a test.
    struct SafeAuth {
        /// @dev Zero pk + zero addr: nobody here can act as the Safe; the deployer is then tried for an IMMEDIATE
        ///      call, and failing that the calls are printed, not sent.
        Signer safe;
        bool scheduleOn; // V2_SCHEDULE
        string phase; // V2_SCHEDULE_PHASE: "", "schedule" or "execute"
        bool requireVaults; // V2_HOUSE_REQUIRE_VAULTS: an uncreated vault is a revert (after the report)
    }

    function run() external returns (Built memory built) {
        Inputs memory in_ = inputsFromEnv();
        uint256 expectChainId = vm.envUint("V2_EXPECT_CHAIN_ID");
        require(
            block.chainid == expectChainId,
            string.concat("chain id ", vm.toString(block.chainid), ", expected ", vm.toString(expectChainId))
        );
        uint256 pk = vm.envOr("DEPLOYER_PK", uint256(0));
        Signer memory deployer = pk != 0 ? Signer(pk, vm.addr(pk)) : Signer(0, vm.envOr("V2_DEPLOYER", address(0)));

        // The Safe signer: ADMIN_PK when a key holds LISTING (dev), the unlocked Safe on a rehearsal fork
        // (`V2_UNLOCKED_ADMIN=true`, set by DeployV2Batch.sh --rehearse and only there), otherwise nobody.
        uint256 adminPk = vm.envOr("ADMIN_PK", uint256(0));
        SafeAuth memory auth;
        if (adminPk != 0) auth.safe = Signer(adminPk, vm.addr(adminPk));
        else if (vm.envOr("V2_UNLOCKED_ADMIN", false)) auth.safe = Signer(0, in_.adminSafe);
        auth.scheduleOn = vm.envOr("V2_SCHEDULE", false);
        auth.phase = vm.envOr("V2_SCHEDULE_PHASE", string(""));
        auth.requireVaults = vm.envOr("V2_HOUSE_REQUIRE_VAULTS", false);

        built = runWith(in_, deployer, auth);
        _report(in_, built, createVaultCalls(in_, built.factory));
        requireCreated(in_, built, auth);
    }

    /// @dev `V2_HOUSE_REQUIRE_VAULTS`: the caller asked for a missing vault to be a non-zero exit, not a report.
    ///      Runs AFTER {_report} so the Safe calls are on the log and in the JSON before the revert.
    function requireCreated(Inputs memory in_, Built memory built, SafeAuth memory auth) public pure {
        if (!auth.requireVaults) return;
        for (uint256 i; i < built.vaults.length; ++i) {
            require(
                built.vaults[i] != address(0),
                string.concat(
                    "V2_HOUSE_REQUIRE_VAULTS: HouseVault ",
                    in_.tickers[i],
                    " was not created: no signer here holds LISTING immediately and no Safe phase ran; the",
                    " createVault call is printed above and recorded under pendingCreateVault"
                )
            );
        }
    }

    /// @notice The whole sequence from explicit inputs: the entry the unit fixture drives (`vm.setEnv` is shared by
    ///         every test thread, so env-driven tests are confined to DeployV2Env.t.sol).
    function runWith(Inputs memory in_, Signer memory deployer, SafeAuth memory auth)
        public
        returns (Built memory built)
    {
        preflight(in_);

        // ---- 1. the factory: a plain deploy from the deployer, or the one an earlier phase already made
        built.vaults = new address[](in_.tickers.length);
        if (in_.factory == address(0)) {
            require(
                deployer.pk != 0 || deployer.addr != address(0),
                "no DEPLOYER_PK and no V2_DEPLOYER: nothing can send the factory deploy"
            );
            _startBroadcast(deployer);
            built.factory = address(
                new HouseVaultFactory(
                    IOrderBook(in_.orderBook),
                    in_.manager,
                    IExpiryCalendar(in_.calendar),
                    ISettlementOracle(in_.oracle),
                    in_.splitter
                )
            );
            vm.stopBroadcast();
        } else {
            built.factory = in_.factory;
        }
        _readBackFactory(in_, built.factory);

        // ---- 2. the vaults: the LISTING lane, sent only by a signer the manager lets act as the Safe
        Call[] memory calls = createVaultCalls(in_, built.factory);
        built.safeActionRequired = !_sendAsSafe(in_, auth, deployer, built.factory, calls);
        for (uint256 i; i < in_.tickers.length; ++i) {
            built.vaults[i] = HouseVaultFactory(built.factory).vaultOf(in_.underlyings[i]);
            if (built.vaults[i] != address(0)) _readBackVault(in_, built.factory, built.vaults[i], i);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @notice Everything that must hold before a byte is deployed. Every failure names the variable that was wrong.
    function preflight(Inputs memory in_) public view {
        // 1. The manager is the v8 AccessManager (an EOA authority makes every `restricted` call revert and can
        //    never be replaced: `Managed.setAuthority` is callable only by the authority itself).
        _code(in_.manager, "V2_ACCESS_MANAGER");
        require(
            AccessManager(in_.manager).ADMIN_ROLE() == 0
                && AccessManager(in_.manager).PUBLIC_ROLE() == type(uint64).max,
            string.concat("V2_ACCESS_MANAGER ", vm.toString(in_.manager), " does not answer as an AccessManager")
        );

        // 2. The three sources the factory hands to EVERY vault are contracts on THIS manager. The factory's own
        //    constructor refuses a zero address (`NoSource`); a wrong non-zero one is the plausible failure, and it
        //    would be immutable in every vault the factory ever makes.
        _onManager(in_.orderBook, "V2_ORDER_BOOK", in_.manager);
        _onManager(in_.calendar, "V2_EXPIRY_CALENDAR", in_.manager);
        _onManager(in_.oracle, "V2_SETTLEMENT_ORACLE", in_.manager);
        _code(in_.splitter, "V2_FEE_SPLITTER");
        _code(in_.adminSafe, "V2_ADMIN_SAFE");

        // 3. A reused factory (execute phase, or a resume) must be the one this manager governs and must have been
        //    built from these inputs -- otherwise the vaults would be created on a stranger's factory.
        if (in_.factory != address(0)) _readBackFactory(in_, in_.factory);

        // 4. Every launch-set underlying is an 18-dp token (HouseVault quotes in 0.01-share units of an 18-dp Stock
        //    Token; a 6-dp asset here would be off by 10^12 in every limit).
        require(in_.tickers.length != 0, "V2_TICKERS is empty: no launch-set ticker to create a House vault for");
        for (uint256 i; i < in_.tickers.length; ++i) {
            string memory name = _mk(in_.tickers[i], "ASSET");
            _code(in_.underlyings[i], name);
            uint8 dec = IERC20Metadata(in_.underlyings[i]).decimals();
            require(
                dec == 18,
                string.concat(
                    name,
                    " ",
                    vm.toString(in_.underlyings[i]),
                    " reports ",
                    vm.toString(uint256(dec)),
                    " decimals, not 18"
                )
            );
            for (uint256 j; j < i; ++j) {
                require(
                    in_.underlyings[j] != in_.underlyings[i],
                    string.concat(
                        name,
                        " repeats an earlier ticker's asset: one vault per underlying, the factory refuses a second"
                    )
                );
            }
        }

        // 5. The manifest still guards `createVault` with the lane this script schedules on. Read, not typed: if
        //    the row moved, the printed Safe calls and the impersonation would name the wrong role.
        string memory json = rolesJson();
        string memory sig = _createVaultSig();
        string memory roleName = roleNameOfSig(json, TARGET_FACTORY, sig);
        require(
            keccak256(bytes(roleName)) == keccak256(bytes(CREATE_VAULT_ROLE)),
            string.concat("roles.v8.json maps HouseVaultFactory.", sig, " to ", roleName, ", not ", CREATE_VAULT_ROLE)
        );

        // 6. One Limits per ticker, in range for the contract's own checks (bps fields <= 10_000), so a bad value is
        //    named here rather than surfacing as the vault constructor's bare revert inside `createVault`.
        require(in_.limits.length == in_.tickers.length, "one HouseVault.Limits per launch ticker, in ticker order");
        for (uint256 i; i < in_.tickers.length; ++i) {
            string memory t = in_.tickers[i];
            HouseVault.Limits memory l = in_.limits[i];
            require(l.askToleranceBps <= 10_000, string.concat(t, ".", F_ASK_TOLERANCE_BPS, " exceeds 10000 bps"));
            require(l.maxBidBpsOfSpot <= 10_000, string.concat(t, ".", F_MAX_BID_BPS_OF_SPOT, " exceeds 10000 bps"));
            require(
                l.maxSeriesUnits != 0, string.concat(t, ".", F_MAX_SERIES_UNITS, " is 0: the vault could never quote")
            );
            require(
                l.maxTotalNotional != 0,
                string.concat(t, ".", F_MAX_TOTAL_NOTIONAL, " is 0: the vault could never quote")
            );
        }
    }

    /// @dev `a` has code and answers to `manager` as its authority.
    function _onManager(address a, string memory name, address manager) internal view {
        _code(a, name);
        address auth = IAccessManaged(a).authority();
        require(
            auth == manager,
            string.concat(
                name,
                " ",
                vm.toString(a),
                " answers to ",
                vm.toString(auth),
                ", not V2_ACCESS_MANAGER: the vaults and their sources would be governed by different managers"
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                        THE VAULT CALLS, AS CALLDATA
    //////////////////////////////////////////////////////////////*/

    /// @notice One `createVault` per launch ticker, as the calldata the Safe sends to the FACTORY.
    function createVaultCalls(Inputs memory in_, address factory) public pure returns (Call[] memory calls) {
        calls = new Call[](in_.tickers.length);
        for (uint256 i; i < in_.tickers.length; ++i) {
            string memory t = in_.tickers[i];
            calls[i] = Call({
                to: factory,
                data: abi.encodeCall(
                    HouseVaultFactory.createVault,
                    (in_.underlyings[i], in_.limits[i], string.concat("Stonkhouse House ", t), string.concat("h", t))
                ),
                what: string.concat("HouseVaultFactory.createVault(", t, ") -> ", CREATE_VAULT_ROLE)
            });
        }
    }

    /// @notice The `setTargetFunctionRole` calls the Admin Safe must execute so the factory and each created vault
    ///         carry their manifest rows. One call per signature per target, roles READ from `roles.v8.json`; the
    ///         ADMIN lane (`delaysS.ADMIN`) owns sending them (T-OP-116's mapping sub-step), never this script.
    function mappingCalls(address manager, address factory, string[] memory tickers, address[] memory vaults)
        public
        view
        returns (Call[] memory calls)
    {
        string memory json = rolesJson();
        string[] memory fSigs = targetSigs(json, TARGET_FACTORY);
        string[] memory vSigs = targetSigs(json, TARGET_VAULT);
        require(fSigs.length != 0, "roles.v8.json lists no selectors for HouseVaultFactory");
        require(vSigs.length != 0, "roles.v8.json lists no selectors for HouseVault");
        uint256 nVaults;
        for (uint256 i; i < vaults.length; ++i) {
            if (vaults[i] != address(0)) ++nVaults;
        }
        calls = new Call[](fSigs.length + nVaults * vSigs.length);
        uint256 n;
        for (uint256 i; i < fSigs.length; ++i) {
            calls[n++] = _mapRow(json, manager, factory, TARGET_FACTORY, TARGET_FACTORY, fSigs[i]);
        }
        for (uint256 v; v < vaults.length; ++v) {
            if (vaults[v] == address(0)) continue;
            for (uint256 i; i < vSigs.length; ++i) {
                calls[n++] = _mapRow(
                    json, manager, vaults[v], TARGET_VAULT, string.concat(TARGET_VAULT, "(", tickers[v], ")"), vSigs[i]
                );
            }
        }
    }

    function _mapRow(
        string memory json,
        address manager,
        address target,
        string memory targetName,
        string memory label,
        string memory sig
    ) internal pure returns (Call memory) {
        string memory roleName = roleNameOfSig(json, targetName, sig);
        bytes4[] memory one = new bytes4[](1);
        one[0] = selectorOf(sig);
        return Call({
            to: manager,
            data: abi.encodeCall(AccessManager.setTargetFunctionRole, (target, one, roleIdOf(json, roleName))),
            what: string.concat(label, ".", sig, " -> ", roleName)
        });
    }

    /// @dev The manifest spelling of `createVault`, derived from the type rather than typed.
    function _createVaultSig() internal pure returns (string memory) {
        return "createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)";
    }

    /// @dev Sends `calls` as the Safe when a signer that the node honours exists, through the manager's schedule
    ///      when the lane is delayed; returns false when the calls were NOT sent (printed for the Safe instead).
    ///      Mirrors `RegisterMarkets.s.sol:_executeScheduled`, phase by phase; see the contract NatSpec.
    function _sendAsSafe(
        Inputs memory in_,
        SafeAuth memory auth,
        Signer memory deployer,
        address factory,
        Call[] memory calls
    ) internal returns (bool sent) {
        Signer memory safe = auth.safe;
        if (safe.pk == 0 && safe.addr == address(0)) {
            // nobody here can act as the Safe: the deployer may still hold LISTING immediately (T-OP-153 window,
            // DevDeploy shape) -- asked of the manager, never assumed; otherwise print, do not send
            return _sendAsDeployerIfImmediate(in_, deployer, factory, calls);
        }
        require(
            safe.addr == in_.adminSafe,
            string.concat(
                "ADMIN_PK signs as ", vm.toString(safe.addr), ", V2_ADMIN_SAFE is ", vm.toString(in_.adminSafe)
            )
        );
        AccessManager mgr = AccessManager(in_.manager);
        uint32 listingDelay = roleDelayOf(rolesJson(), CREATE_VAULT_ROLE);
        string memory phase = auth.phase;
        bool scheduleOn = auth.scheduleOn;
        require(
            scheduleOn || bytes(phase).length == 0,
            "V2_SCHEDULE_PHASE without V2_SCHEDULE: there is nothing to schedule and nothing to execute"
        );
        bool isSchedule = keccak256(bytes(phase)) == keccak256("schedule");
        bool isExecute = keccak256(bytes(phase)) == keccak256("execute");
        require(
            !scheduleOn || isSchedule || isExecute,
            string.concat("V2_SCHEDULE_PHASE must be schedule or execute, got '", phase, "'")
        );
        sent = true;
        for (uint256 i; i < calls.length; ++i) {
            // an already-created vault (a re-run, or the execute phase after a partial one) is left alone
            if (HouseVaultFactory(factory).vaultOf(in_.underlyings[i]) != address(0)) continue;
            // casting to 'bytes4' keeps the leading four bytes on purpose: they are the call's selector
            // forge-lint: disable-next-line(unsafe-typecast)
            (bool immediate, uint32 delay) = mgr.canCall(safe.addr, calls[i].to, bytes4(calls[i].data));
            if (immediate) {
                if (isSchedule) continue; // nothing to schedule for an immediate call
                _startBroadcast(safe);
                (bool ok,) = calls[i].to.call(calls[i].data);
                vm.stopBroadcast();
                require(ok, string.concat("createVault reverted: ", calls[i].what));
                console2.log(string.concat("  created ", calls[i].what));
                continue;
            }
            require(
                delay != 0,
                string.concat(
                    "the Safe cannot call ",
                    calls[i].what,
                    ": canCall answers neither immediate nor delayed, so the factory's createVault is unmapped or ",
                    vm.toString(safe.addr),
                    " does not hold LISTING"
                )
            );
            // AN UNMAPPED SELECTOR IS NOT "UNCALLABLE" FOR THE SAFE: AccessManager answers ADMIN_ROLE for a
            // (target, selector) nobody mapped, and the Safe holds ADMIN, so canCall says "delayed by delaysS.ADMIN"
            // (48 h) for a factory whose createVault was never mapped to LISTING. Scheduling that would work and
            // would be the wrong lane. The delay the manager answers must be the manifest's LISTING delay; anything
            // else means the mapping rows (pendingTargetFunctionRole) have not been executed yet.
            require(
                delay == listingDelay,
                string.concat(
                    "the manager answers a ",
                    vm.toString(uint256(delay)),
                    " s delay for ",
                    calls[i].what,
                    ", not delaysS.LISTING ",
                    vm.toString(uint256(listingDelay)),
                    " s: HouseVaultFactory.createVault is not mapped to LISTING on this factory yet (an unmapped",
                    " selector answers to ADMIN). Execute the setTargetFunctionRole rows this script prints first"
                )
            );
            require(
                scheduleOn,
                string.concat(
                    "a delayed LISTING call cannot be sent by a single run: ",
                    calls[i].what,
                    " waits ",
                    vm.toString(uint256(delay)),
                    "s. Re-run with V2_SCHEDULE=true V2_SCHEDULE_PHASE=schedule, move the node clock past the delay,",
                    " then run again with V2_SCHEDULE_PHASE=execute and V2_HOUSE_VAULT_FACTORY set to this factory"
                )
            );
            if (isSchedule) {
                _startBroadcast(safe);
                (bytes32 opId, uint32 nonce) = mgr.schedule(calls[i].to, calls[i].data, 0);
                vm.stopBroadcast();
                console2.log(string.concat("  scheduled ", calls[i].what));
                console2.log("  opId", vm.toString(opId));
                console2.log("  nonce", vm.toString(uint256(nonce)));
                console2.log("  delayS", vm.toString(uint256(delay)));
                console2.log("  readyAt", vm.toString(uint256(mgr.getSchedule(opId))));
                sent = false; // scheduled is not created: the caller must come back after the delay
                continue;
            }
            _startBroadcast(safe);
            (bool ok2,) = calls[i].to.call(calls[i].data);
            vm.stopBroadcast();
            require(
                ok2, string.concat("delayed createVault reverted (not yet ready, or never scheduled): ", calls[i].what)
            );
            console2.log(string.concat("  executed ", calls[i].what));
        }
    }

    /// @dev The deployer creates the vaults only if the manager lets it do so IMMEDIATELY for every one of them; a
    ///      partial answer (one immediate, one not) sends nothing, so the run never half-creates a launch set.
    function _sendAsDeployerIfImmediate(Inputs memory in_, Signer memory deployer, address factory, Call[] memory calls)
        internal
        returns (bool sent)
    {
        if (deployer.pk == 0 && deployer.addr == address(0)) return false;
        AccessManager mgr = AccessManager(in_.manager);
        for (uint256 i; i < calls.length; ++i) {
            if (HouseVaultFactory(factory).vaultOf(in_.underlyings[i]) != address(0)) continue;
            // casting to 'bytes4' keeps the leading four bytes on purpose: they are the call's selector
            // forge-lint: disable-next-line(unsafe-typecast)
            (bool immediate,) = mgr.canCall(deployer.addr, calls[i].to, bytes4(calls[i].data));
            if (!immediate) return false;
        }
        for (uint256 i; i < calls.length; ++i) {
            if (HouseVaultFactory(factory).vaultOf(in_.underlyings[i]) != address(0)) continue;
            _startBroadcast(deployer);
            (bool ok,) = calls[i].to.call(calls[i].data);
            vm.stopBroadcast();
            require(ok, string.concat("createVault reverted (deployer, immediate): ", calls[i].what));
            console2.log(string.concat("  created (deployer holds LISTING immediately) ", calls[i].what));
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                               READ BACK
    //////////////////////////////////////////////////////////////*/

    /// @dev The factory's immutables, read off the deployed contract rather than assumed from the arguments.
    function _readBackFactory(Inputs memory in_, address factory) internal view {
        _code(factory, "V2_HOUSE_VAULT_FACTORY");
        HouseVaultFactory f = HouseVaultFactory(factory);
        require(f.authority() == in_.manager, "HouseVaultFactory is not on V2_ACCESS_MANAGER");
        require(address(f.orderBook()) == in_.orderBook, "HouseVaultFactory does not quote on V2_ORDER_BOOK");
        require(address(f.calendar()) == in_.calendar, "HouseVaultFactory does not use V2_EXPIRY_CALENDAR");
        require(address(f.oracle()) == in_.oracle, "HouseVaultFactory does not seed V2_SETTLEMENT_ORACLE");
        require(f.splitter() == in_.splitter, "HouseVaultFactory does not pay V2_FEE_SPLITTER");
    }

    /// @dev One created vault: bound to this factory's sources, holding the requested underlying and limits.
    function _readBackVault(Inputs memory in_, address factory, address vault, uint256 i) internal view {
        HouseVault v = HouseVault(vault);
        string memory t = in_.tickers[i];
        require(v.authority() == in_.manager, string.concat("HouseVault ", t, " is not on V2_ACCESS_MANAGER"));
        require(
            address(v.underlying()) == in_.underlyings[i],
            string.concat("HouseVault ", t, " does not hold its ticker's asset")
        );
        require(
            HouseVaultFactory(factory).vaultOf(in_.underlyings[i]) == vault,
            string.concat("factory does not index HouseVault ", t)
        );
        HouseVault.Limits memory l = v.limits();
        HouseVault.Limits memory w = in_.limits[i];
        require(
            l.maxSeriesUnits == w.maxSeriesUnits && l.maxTotalNotional == w.maxTotalNotional
                && l.askToleranceBps == w.askToleranceBps && l.maxBidBpsOfSpot == w.maxBidBpsOfSpot
                && l.maxOrderLifetime == w.maxOrderLifetime && l.maxDailyOutflow == w.maxDailyOutflow,
            string.concat("HouseVault ", t, " limits differ from the limits file it was created with")
        );
    }

    /*//////////////////////////////////////////////////////////////
                                REPORT
    //////////////////////////////////////////////////////////////*/

    /// @dev What was built and what the Safe must still do, printed and written; nothing privileged is attempted.
    function _report(Inputs memory in_, Built memory built, Call[] memory calls) internal {
        console2.log("HouseVaultFactory deployed");
        console2.log("  V2_HOUSE_VAULT_FACTORY", built.factory);
        console2.log(string.concat("  limits from ", in_.limitsFile));
        uint256 created;
        for (uint256 i; i < in_.tickers.length; ++i) {
            if (built.vaults[i] != address(0)) {
                ++created;
                // the first launch ticker's vault is ALSO the single v2.contracts.houseVault / V2_HOUSE_VAULT slot
                if (i == 0) console2.log("  V2_HOUSE_VAULT", built.vaults[0]);
                console2.log(string.concat("  V2_HOUSE_VAULT_", in_.tickers[i]), built.vaults[i]);
            } else {
                console2.log(
                    string.concat("  V2_HOUSE_VAULT_", in_.tickers[i], " NOT CREATED: LISTING call pending (Safe)")
                );
            }
        }

        string memory json = rolesJson();
        uint32 delay = roleDelayOf(json, CREATE_VAULT_ROLE);
        if (built.safeActionRequired) {
            console2.log("");
            console2.log(
                "SAFE ACTION REQUIRED (LISTING lane). The Admin Safe schedules each call on the manager, waits"
            );
            console2.log(
                string.concat(
                    "delaysS.LISTING = ",
                    vm.toString(uint256(delay)),
                    " s, then sends the SAME calldata to the FACTORY (not manager.execute):"
                )
            );
            for (uint256 i; i < calls.length; ++i) {
                if (built.vaults[i] != address(0)) continue;
                console2.log(string.concat("  ", calls[i].what));
                console2.log(string.concat("    schedule to   ", vm.toString(in_.manager)));
                console2.log(
                    string.concat(
                        "    schedule data ",
                        vm.toString(abi.encodeCall(AccessManager.schedule, (calls[i].to, calls[i].data, 0)))
                    )
                );
                console2.log(string.concat("    then call     ", vm.toString(calls[i].to)));
                console2.log(string.concat("    with data     ", vm.toString(calls[i].data)));
            }
        }

        Call[] memory maps = mappingCalls(in_.manager, built.factory, in_.tickers, built.vaults);
        console2.log("");
        console2.log("NEXT, and none of it can be done by this script:");
        console2.log(
            string.concat(
                "  1. the factory's and each vault's manifest selectors are UNMAPPED until the Admin Safe schedules the ",
                vm.toString(maps.length),
                " rows below"
            )
        );
        console2.log(
            string.concat(
                "     (ADMIN lane, delaysS.ADMIN = ",
                vm.toString(uint256(roleDelayOf(json, "ADMIN"))),
                " s; T-OP-116's mapping sub-step rehearses them). Until then VerifyV8 FAILS on"
            )
        );
        console2.log("     HouseVaultFactory / HouseVault, by design. Vaults created later need their own rows.");
        for (uint256 i; i < maps.length; ++i) {
            console2.log(string.concat("       ", maps[i].what));
            console2.log(string.concat("         to   ", vm.toString(maps[i].to)));
            console2.log(string.concat("         data ", vm.toString(maps[i].data)));
        }
        console2.log("  2. write back v2.contracts.houseVaultFactory and the vault address(es) from the JSON below.");

        // ---- JSON out: the shell stage reads this; nothing above is the record
        string memory outKey = "out";
        vm.serializeAddress(outKey, "houseVaultFactory", built.factory);
        // v2.contracts.houseVault = the FIRST launch ticker's vault (answer A); zero until the Safe has created it
        vm.serializeAddress(outKey, "houseVault", built.vaults.length != 0 ? built.vaults[0] : address(0));
        vm.serializeAddress(outKey, "accessManager", in_.manager);
        vm.serializeBool(outKey, "safeActionRequired", built.safeActionRequired);
        vm.serializeString(outKey, "limitsFile", in_.limitsFile);
        vm.serializeUint(outKey, "listingDelayS", delay);
        vm.serializeUint(outKey, "deployBlock", block.number);
        vm.serializeUint(outKey, "chainId", block.chainid);
        string memory vaultsKey = "houseVaults";
        string memory vaultsJson = "{}";
        for (uint256 i; i < in_.tickers.length; ++i) {
            vaultsJson = vm.serializeAddress(vaultsKey, in_.tickers[i], built.vaults[i]);
        }
        vm.serializeString(outKey, "houseVaults", vaultsJson);
        string[] memory rows = new string[](calls.length);
        uint256 n;
        for (uint256 i; i < calls.length; ++i) {
            if (built.vaults[i] != address(0)) continue;
            string memory key = string.concat("pending", vm.toString(i));
            vm.serializeString(key, "what", calls[i].what);
            vm.serializeAddress(key, "scheduleTo", in_.manager);
            vm.serializeBytes(
                key, "scheduleData", abi.encodeCall(AccessManager.schedule, (calls[i].to, calls[i].data, 0))
            );
            vm.serializeAddress(key, "to", calls[i].to);
            rows[n++] = vm.serializeBytes(key, "data", calls[i].data);
        }
        string[] memory pending = new string[](n);
        for (uint256 i; i < n; ++i) {
            pending[i] = rows[i];
        }
        vm.serializeString(outKey, "pendingCreateVault", pending);
        string[] memory mapRows = new string[](maps.length);
        for (uint256 i; i < maps.length; ++i) {
            string memory key = string.concat("map", vm.toString(i));
            vm.serializeString(key, "what", maps[i].what);
            vm.serializeAddress(key, "to", maps[i].to);
            mapRows[i] = vm.serializeBytes(key, "data", maps[i].data);
        }
        string memory outJson = vm.serializeString(outKey, "pendingTargetFunctionRole", mapRows);
        console2.log(outJson);
        string memory outPath = vm.envOr("V2_HOUSE_DEPLOY_OUT", string(""));
        if (bytes(outPath).length != 0) {
            vm.writeJson(outJson, outPath);
            console2.log("wrote %s", outPath);
        }
        created; // the count is for the reader of the log above
    }
}
