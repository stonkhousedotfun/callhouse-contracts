// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice The v7 market row as the LIVE Clearinghouse stores it. Declared here, not imported from `src/v2`, because
///         this tool freezes the DEPLOYED v7 set: `src/v2` on the `v8` branch is a different contract and a tuple
///         change there must never silently change the calldata the owner signs. `FreezeV7.SET_MARKET_CONFIG` pins
///         the selector this tuple produces, and the tool refuses to build a call that does not match it.
struct MarketConfigV7 {
    bool enabled;
    bool mintPaused;
    uint64 strikeTick;
    uint16 exerciseFeeBps;
    address oracle;
    uint32 mintFeePpm;
}

/// @notice The v7 series row. Appended twice by v7 (`mintFeePpm`, `mintFeesHeld`); pinned here for the same reason.
struct SeriesV7 {
    address underlying;
    bool isPut;
    uint40 expiry;
    uint128 strike;
    address oracle;
    uint16 exerciseFeeBps;
    bool settled;
    uint128 settlementPrice;
    uint128 longPayoutPerUnit;
    uint128 feePerUnit;
    uint128 shortPayoutPerUnit;
    uint32 mintFeePpm;
    uint128 mintFeesHeld;
}

/// @notice The Clearinghouse surface this tool touches. Everything above the line is CALLED (all `view`); the two
///         setters below it are only ever ENCODED, so `abi.encodeCall` type-checks the calldata the owner sends.
interface IClearinghouseV7 {
    function createPaused() external view returns (bool);
    function calendar() external view returns (address);
    function market(address underlying) external view returns (MarketConfigV7 memory);
    function series(uint256 longId) external view returns (SeriesV7 memory);
    function openInterest(address underlying, uint40 expiry) external view returns (uint256 units);
    function totalSupply(uint256 id) external view returns (uint256);
    function locked(uint256 longId) external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @dev NEVER called from this tool. `setCreatePaused` is GUARDIAN_ROLE, `setMarketConfig` DEFAULT_ADMIN_ROLE.
    function setCreatePaused(bool paused) external;
    function setMarketConfig(address underlying, MarketConfigV7 calldata cfg) external;
}

/// @notice The OrderBook surface this tool touches. It is READ ONLY, and deliberately so: see {FreezeV7} "WHAT THE
///         FREEZE DOES NOT TOUCH". `setTradingPaused` does not appear here at all, so this file cannot encode it.
interface IOrderBookV7 {
    function clearinghouse() external view returns (address);
    function tradingPaused() external view returns (bool);
    function lastOrderId() external view returns (uint256);
}

/// @notice The expiry grid, for the run-off report's cross-check and for printing an expiry in New York local time.
interface IExpiryCalendarV7 {
    function nextExpiry(uint40 afterTs, bool weekly) external view returns (uint40);
    function newYorkOffset(uint40 ts) external pure returns (int32 secondsEastOfUtc);
}

/// @notice Freezes the LIVE v7 contract set ahead of the v8 redeploy (C8-12) and reports the run-off: what a v7 user
///         can still do, and when the last v7 position expires. Read-only by default and read-only in every mode: it
///         has no broadcast path and no key input at all, exactly as `script/v2/RaisePoolCardinality.s.sol`.
///
///           forge script script/v2/FreezeV7.s.sol --rpc-url $RH_RPC                        # status + run-off + plan
///           V7_PLAN=0 forge script script/v2/FreezeV7.s.sol --rpc-url $RH_RPC              # status + run-off only
///
/// @dev WHAT THE FREEZE DOES. Two calls, both instant (v7 has no timelock; an AccessManager with delays arrives with
///      v8). They stop NEW RISK and nothing else:
///        - `setCreatePaused(true)`, GUARDIAN_ROLE. `Clearinghouse.createSeries` reverts `CreatePaused`, so no new
///          series id can be opened in any market. Nothing else reads the flag.
///        - `setMarketConfig(underlying, cfg with enabled = false)`, DEFAULT_ADMIN_ROLE, once per live market (NVDA
///          today). `createSeries` reverts `MarketDisabled` and, the point of it, `mint` reverts `MarketDisabled`
///          too: no unit can be written into a series that ALREADY exists. `setCreatePaused` alone does not stop
///          that, which is why both calls are needed and why {freezeSet} refuses to leave an enabled market out.
///          The config is read from the chain and ONLY `enabled` is flipped; `mintPaused` is guardian-owned and the
///          Clearinghouse keeps its stored value whatever this call carries. {_checkFreezeOnly} proves both.
///
///      A USER IS NEVER TRAPPED BY THE FREEZE. `close`, `redeem`, `redeemBatch`, `withdraw`, `deposit`, `settle`,
///      `sweepFees`, `setOperator` and `setPayoutInKind` read neither `enabled`, `mintPaused` nor `createPaused` —
///      they are not pausable in v7 at all. On the book, `cancel`, `prune` and `claimOwed` are never pausable, and
///      `AutoRoller.stop`, `cancelStale` and the close-out half of `roll` are documented to run on a disabled market.
///      So after the freeze every holder can still unwind, take collateral home and pull escrow back, and the cranker
///      still settles and redeems each expiry as it comes. `test/v2/fork/FreezeV7Fork.t.sol` proves it on a fork of
///      the live set, with the exact bytes this tool plans.
///
///      WHAT THE FREEZE DOES NOT TOUCH, on purpose:
///        - `OrderBook.setTradingPaused`. Pausing the book would stop `place`, `replace` and `take`, which would take
///          away the ONE way a holder has of selling a long before expiry. Stopping resale stops no new risk (a
///          resale moves an existing long; it mints nothing), so it is not part of the freeze. This file cannot even
///          encode the call. If the owner ever does want the book stopped, that is a separate, deliberate decision.
///        - `setMintPaused`. Redundant once the market is disabled: `mint` checks `enabled` first. It stays available
///          as a guardian-side belt if the admin key is ever the thing in doubt.
///        - roles, the fee recipient, the payout adapter, the calendar, the oracle, the fee parameters, and any user
///          balance. The freeze moves no funds.
///
///      THE RUN-OFF DATE IS COMPUTED, NOT ASSUMED. Every `SeriesCreated` log of the Clearinghouse is read from
///      `V7_FROM_BLOCK` (the deploy block) to the current block with `vm.eth_getLogs`, in `V7_LOG_CHUNK`-block
///      chunks; each series is then read back from the chain for its expiry, its settled flag and its live long
///      supply. The report gives the last expiry over every series that exists, the last expiry that still carries
///      open interest (the one that answers "when does my position expire"), and the ceiling `now + MAX_TENOR`,
///      which no series created before the freeze can pass. A second, independent walk over the expiry GRID
///      (`ExpiryCalendar.nextExpiry`) reads `openInterest` at every session close in the window and reports any
///      expiry carrying units that the log scan did not account for, so a truncated scan is loud rather than
///      optimistic. Admin-whitelisted SPECIAL expiries are off the grid and cannot be enumerated on chain: name them
///      in `V7_EXTRA_EXPIRIES` to have them checked too (none exist on the live set as of 2026-09-19).
///
///      BROADCASTING STAYS AN OWNER ACTION. {status}, {plan}, {runOff}, {postCheck} and {freezeSet} are `view`,
///      {runWith} adds only the plan files, no entry point takes a key, and the two freeze calls are only ever
///      ABI-encoded. A run produces two things the owner reads and then executes deliberately: a `cast send` line per
///      call on the console, and a Safe{Wallet} Transaction Builder batch per ROLE (the guardian sends one call, the
///      admin the others). Both are inert files until a person sends them
///      (`FreezeV7Test.test_cannotBroadcast_notEvenWithEveryMarketSelected`).
///
///      IDEMPOTENT. A Clearinghouse already create-paused gets no pause call ("already paused"), a market already
///      disabled no config call ("already disabled"); a re-run after the owner has executed plans nothing and runs
///      {postCheck} instead.
///
///      ENVIRONMENT (all optional)
///        V7_CLEARINGHOUSE      default {CLEARINGHOUSE}; V7_ORDER_BOOK default {ORDER_BOOK}
///        V7_MARKETS            comma-separated underlyings to disable. Default: every market the
///                              `MarketRegistered` logs name. A named set that leaves an enabled market out is
///                              REFUSED (see above).
///        V7_GUARDIAN           default {GUARDIAN}; must hold GUARDIAN_ROLE. V7_ADMIN default {ADMIN};
///                              must hold DEFAULT_ADMIN_ROLE. Both are checked on chain before anything is planned.
///        V7_FROM_BLOCK         log scan start, default {DEPLOY_BLOCK}. V7_LOG_CHUNK blocks per call, default
///                              {DEFAULT_LOG_CHUNK}. V7_MAX_SERIES buffer size, default {DEFAULT_MAX_SERIES}.
///        V7_REGISTERED_MARKETS, V7_SERIES  the registered markets and the series ids, given instead of read from
///                              the logs. For a node that caps or refuses `eth_getLogs`; the dates are then only as
///                              complete as the lists. The live NVDA pin independently protects market completeness;
///                              the grid cross-check covers series only inside the markets the run names.
///        V7_GRID_FROM          grid cross-check start, default {DEPLOY_TS}; must lie in [DEPLOY_TS, now] (refused
///                              outside it). The walk covers at most MAX_GRID_STEPS closes from it and the report says
///                              WARNING ... TRUNCATED when that is fewer than the window. V7_EXTRA_EXPIRIES: off-grid.
///        V7_PLAN               `false` / `0` to skip writing the plan files (status and run-off only).
///        V7_GUARDIAN_PLAN_OUT  default {DEFAULT_GUARDIAN_PLAN_OUT}; V7_ADMIN_PLAN_OUT {DEFAULT_ADMIN_PLAN_OUT}
///        V7_EXPECT_CHAIN_ID    default {CHAIN_ID_4663}; the pinned addresses are Robinhood Chain addresses.
///      `runWith(Inputs)` is the same procedure with explicit inputs; the tests drive it that way because
///      `vm.setEnv` writes the process environment every parallel test thread shares.
contract FreezeV7 is Script {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Robinhood Chain: the chain the pinned addresses belong to.
    uint256 public constant CHAIN_ID_4663 = 4663;

    /// @notice The live v7 Clearinghouse (`ops/markets/tier1.json` `v2.contracts`, interface version 7).
    address public constant CLEARINGHOUSE = 0x22dEf851cD1a3B04Ad7d232bE786d76E6944d424;
    /// @notice The live v7 OrderBook. Read only: the freeze never pauses it.
    address public constant ORDER_BOOK = 0x9fcAe743C3fA0aEC7DB9b1d01e86464b85759942;
    /// @notice The live NVDA Stock Token: the only market v7 ever registered.
    address public constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    /// @notice `ops/markets/tier1.json` `shared.guardian`: holds GUARDIAN_ROLE on the live Clearinghouse.
    address public constant GUARDIAN = 0x29741A8d283a253E8Ce10aDfd04C6507438b6F39;
    /// @notice `ops/markets/tier1.json` `shared.admin`: holds DEFAULT_ADMIN_ROLE on the live Clearinghouse.
    address public constant ADMIN = 0xEb82c3D0F89d47453F94f0C2b2a2752e27a19d9b;

    /// @notice Block the v7 set was deployed in, and that block's timestamp (2026-09-18 00:01:26 UTC). No series can
    ///         exist before it, and `createSeries` requires `expiry > now`, so every v7 expiry is after this instant.
    uint256 public constant DEPLOY_BLOCK = 65_780_341;
    uint40 public constant DEPLOY_TS = 1_789_689_686;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);

    /// @notice v7 `V2Constants.MAX_TENOR`: `createSeries` refuses `expiry > now + MAX_TENOR`. Pinned here, like the
    ///         tuples above, so a v8 change to the constant cannot move what this tool claims about the v7 run-off.
    uint40 public constant MAX_TENOR = 45 days;

    /// @notice `SeriesCreated(uint256,address,bool,uint128,uint40,address,uint16,uint32)`: the v7 topic0.
    bytes32 public constant SERIES_CREATED_TOPIC =
        keccak256("SeriesCreated(uint256,address,bool,uint128,uint40,address,uint16,uint32)");
    /// @notice `MarketRegistered(address,(bool,bool,uint64,uint16,address,uint32))`: the v7 topic0.
    bytes32 public constant MARKET_REGISTERED_TOPIC =
        keccak256("MarketRegistered(address,(bool,bool,uint64,uint16,address,uint32))");

    /// @notice The only two selectors a freeze plan may ever hold ({_checkFreezeOnly}), as deployed v7 answers them.
    bytes4 public constant SET_CREATE_PAUSED = IClearinghouseV7.setCreatePaused.selector;
    bytes4 public constant SET_MARKET_CONFIG = IClearinghouseV7.setMarketConfig.selector;

    uint256 public constant DEFAULT_LOG_CHUNK = 500_000;
    uint256 public constant DEFAULT_MAX_SERIES = 2048;
    /// @notice Session closes the grid cross-check walks at most. 96 covers a whole `MAX_TENOR` window and more.
    uint256 public constant MAX_GRID_STEPS = 96;

    string public constant DEFAULT_GUARDIAN_PLAN_OUT = "broadcast/freeze-v7-guardian-safe-batch.json";
    string public constant DEFAULT_ADMIN_PLAN_OUT = "broadcast/freeze-v7-admin-safe-batch.json";

    /// @dev "no such entry" from {_indexOf}.
    uint256 private constant NOT_FOUND = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address clearinghouse;
        address orderBook;
        /// @dev The markets the freeze disables. Every registered market that is still enabled must be in here.
        address[] markets;
        /// @dev Named in the guardian batch; must hold GUARDIAN_ROLE.
        address guardian;
        /// @dev Named in the admin batch; must hold DEFAULT_ADMIN_ROLE.
        address admin;
        /// @dev The registered set, for a node that cannot serve `MarketRegistered` logs. Empty = read the logs.
        address[] registeredMarkets;
        /// @dev The series to report on, for a node that cannot serve `SeriesCreated` logs. Empty = read the logs.
        uint256[] knownSeries;
        uint256 fromBlock;
        uint256 logChunk;
        uint256 maxSeries;
        /// @dev Grid cross-check start; expiries before it are not walked.
        uint40 gridFrom;
        /// @dev Off-grid (admin-whitelisted) expiries to check for open interest as well.
        uint40[] extraExpiries;
        /// @dev False leaves the plan files unwritten; the report and the checks are unchanged.
        bool writePlan;
        string guardianPlanOut;
        string adminPlanOut;
        uint256 expectChainId;
    }

    /// @notice One call the owner sends. `role` is the batch it belongs to, and so which key signs it.
    struct Call {
        address to;
        bytes data;
        string what;
        bool guardianRole;
    }

    /// @notice The freeze switches as the chain reports them now.
    struct Status {
        bool createPaused;
        /// @dev Reported, never set. The freeze leaves the book trading so holders can still sell a long.
        bool tradingPaused;
        address calendar;
        uint256 lastOrderId;
        MarketStatus[] markets;
    }

    struct MarketStatus {
        address underlying;
        bool registered;
        bool enabled;
        bool mintPaused;
        MarketConfigV7 cfg;
    }

    /// @notice One v7 series the `SeriesCreated` scan found, read back from the chain.
    struct SeriesRow {
        uint256 longId;
        address underlying;
        bool isPut;
        uint128 strike;
        uint40 expiry;
        bool settled;
        /// @dev Live long supply, 0.01-share units. Equal to the units still in holders' hands.
        uint256 longSupply;
        /// @dev Collateral the series still holds, collateral-asset base units.
        uint256 lockedAmount;
    }

    /// @notice When the v7 run-off ends, and how much is still open.
    struct RunOff {
        uint256 seriesCount;
        /// @dev Series with live long supply: the positions the freeze leaves open.
        uint256 openSeriesCount;
        /// @dev Series whose expiry has passed and that nobody has settled yet: the cranker's remaining work.
        uint256 unsettledPastCount;
        /// @dev Live long units summed over every series, 0.01-share units.
        uint256 openUnits;
        /// @dev Largest expiry over every series that EXISTS. Settlement work can run to here.
        uint40 lastExpiry;
        /// @dev Largest expiry over every series that still carries units. This is when the last POSITION expires.
        uint40 lastOpenExpiry;
        /// @dev `now + MAX_TENOR`: no series created before the freeze can expire later than this.
        uint40 tenorCeiling;
        /// @dev A grid expiry carrying open interest that the log scan did not account for; 0 when there is none.
        uint40 unaccountedExpiry;
        /// @dev True when the grid walk spent all MAX_GRID_STEPS closes from `gridFrom` WITHOUT reaching the tenor
        ///      ceiling: the cross-check then covered only the first 96 closes and says nothing about the rest. False
        ///      when the walk ended because it passed `now + MAX_TENOR` (or the calendar ran out), or because it found
        ///      an unaccounted expiry first (T-OP-055). The report prints a WARNING on true; `unaccountedExpiry == 0`
        ///      alone is not "every expiry was checked".
        bool gridTruncated;
    }

    /*//////////////////////////////////////////////////////////////
                                  ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @return planned calls the owner still has to send (0 = the set is already frozen)
    /// @return lastExpiry the largest expiry over every v7 series that exists, unix seconds
    function run() external returns (uint256 planned, uint40 lastExpiry) {
        (, RunOff memory off, Call[] memory calls) = runWith(_inputsFromEnv());
        return (calls.length, off.lastExpiry);
    }

    /// @notice Reports the freeze switches and the run-off, and writes the plan the owner executes.
    /// @dev The only non-`view` thing it does is write the two plan files. It sends nothing, on any path.
    function runWith(Inputs memory in_) public returns (Status memory state, RunOff memory off, Call[] memory calls) {
        address[] memory set = freezeSet(in_);
        state = _statusOf(in_, set);
        SeriesRow[] memory rows = _discoverSeries(in_, set);
        off = _runOffOf(in_, set, rows);
        calls = _plan(in_, set, state);

        _reportStatus(in_, state);
        _reportRunOff(in_, off, rows);

        if (calls.length == 0) {
            console2.log("");
            console2.log("ALREADY FROZEN: creation is paused and every named market is disabled. Nothing to send.");
            uint256 failures = postCheck(in_, set);
            require(failures == 0, "post-check failed: the v7 set is not frozen");
            console2.log(string.concat("post-check PASSED: ", vm.toString(set.length + 2), " checks"));
            return (state, off, calls);
        }
        if (in_.writePlan) {
            _writePlan(in_.guardianPlanOut, in_.guardian, calls, true);
            _writePlan(in_.adminPlanOut, in_.admin, calls, false);
        }
        _printPlan(in_, calls);
    }

    /// @notice The freeze switches and every named market's row, read-only.
    function status(Inputs memory in_) external view returns (Status memory) {
        return _statusOf(in_, freezeSet(in_));
    }

    /// @notice What the owner would have to send, and nothing else.
    /// @dev `view`: planning cannot write state, cannot send and cannot even write the plan files. A Clearinghouse
    ///      already create-paused produces no pause call; a market already disabled produces no config call.
    function plan(Inputs memory in_) external view returns (Call[] memory) {
        address[] memory set = freezeSet(in_);
        return _plan(in_, set, _statusOf(in_, set));
    }

    /// @notice The v7 run-off: every series that exists, and when the last one expires.
    function runOff(Inputs memory in_) external view returns (RunOff memory off, SeriesRow[] memory rows) {
        address[] memory set = freezeSet(in_);
        rows = _discoverSeries(in_, set);
        off = _runOffOf(in_, set, rows);
    }

    /// @notice Reads the frozen state back. Returns how many checks failed; prints one ok/FAIL line per check.
    /// @dev The last check is the one people forget: the book must STILL be trading, because a paused book would
    ///      take away the only way a holder has of selling a long before expiry. A freeze that paused it is a
    ///      failure here, not a success.
    function postCheck(Inputs memory in_, address[] memory set) public view returns (uint256 failures) {
        IClearinghouseV7 ch = IClearinghouseV7(in_.clearinghouse);
        console2.log("post-check");
        failures += _check(ch.createPaused(), "createPaused() == true");
        for (uint256 i; i < set.length; ++i) {
            failures += _check(
                !ch.market(set[i]).enabled, string.concat("market(", vm.toString(set[i]), ").enabled == false")
            );
        }
        failures += _check(
            !IOrderBookV7(in_.orderBook).tradingPaused(),
            "OrderBook.tradingPaused() == false (holders can still sell a long)"
        );
    }

    /// @notice The markets this run freezes. Every refusal is here, before a single series is read.
    /// @dev The important one is the last: `setCreatePaused` stops NEW series ids, it does NOT stop `mint` on a
    ///      series that already exists. So a registered market left enabled keeps taking new risk however many
    ///      other switches are flipped, and this tool will not build a plan that leaves one behind.
    function freezeSet(Inputs memory in_) public view returns (address[] memory set) {
        require(
            block.chainid == in_.expectChainId,
            string.concat(
                "chain id ",
                vm.toString(block.chainid),
                " is not the expected ",
                vm.toString(in_.expectChainId),
                " (V7_EXPECT_CHAIN_ID): the pinned v7 addresses are Robinhood Chain addresses"
            )
        );
        require(in_.clearinghouse.code.length != 0, string.concat("no code at ", vm.toString(in_.clearinghouse)));
        require(in_.orderBook.code.length != 0, string.concat("no code at ", vm.toString(in_.orderBook)));
        address wired = IOrderBookV7(in_.orderBook).clearinghouse();
        require(
            wired == in_.clearinghouse,
            string.concat(
                "the OrderBook at ",
                vm.toString(in_.orderBook),
                " points at ",
                vm.toString(wired),
                ", not at the Clearinghouse being frozen (",
                vm.toString(in_.clearinghouse),
                ")"
            )
        );
        require(in_.markets.length != 0, "no markets: nothing to disable");
        require(in_.guardian != address(0), "V7_GUARDIAN is the zero address");
        require(in_.admin != address(0), "V7_ADMIN is the zero address");

        IClearinghouseV7 ch = IClearinghouseV7(in_.clearinghouse);
        require(
            ch.hasRole(GUARDIAN_ROLE, in_.guardian),
            string.concat(
                "V7_GUARDIAN ",
                vm.toString(in_.guardian),
                " does not hold GUARDIAN_ROLE on the Clearinghouse at ",
                vm.toString(in_.clearinghouse),
                ": its setCreatePaused(true) would revert. Re-read ops/markets/tier1.json shared.guardian."
            )
        );
        require(
            ch.hasRole(DEFAULT_ADMIN_ROLE, in_.admin),
            string.concat(
                "V7_ADMIN ",
                vm.toString(in_.admin),
                " does not hold DEFAULT_ADMIN_ROLE on the Clearinghouse at ",
                vm.toString(in_.clearinghouse),
                ": its setMarketConfig would revert. Re-read ops/markets/tier1.json shared.admin."
            )
        );

        for (uint256 i; i < in_.markets.length; ++i) {
            address m = in_.markets[i];
            require(m != address(0), "V7_MARKETS holds the zero address");
            for (uint256 j; j < i; ++j) {
                require(in_.markets[j] != m, string.concat("market listed twice: ", vm.toString(m)));
            }
            require(
                ch.market(m).strikeTick != 0,
                string.concat(vm.toString(m), " is not a registered market on this Clearinghouse")
            );
        }
        _requireNoEnabledMarketLeftOut(in_);
        set = in_.markets;
    }

    /*//////////////////////////////////////////////////////////////
                                THE PLAN
    //////////////////////////////////////////////////////////////*/

    function _plan(Inputs memory in_, address[] memory set, Status memory state)
        private
        view
        returns (Call[] memory calls)
    {
        Call[] memory buf = new Call[](set.length + 1);
        uint256 n;
        if (!state.createPaused) {
            buf[n++] = Call({
                to: in_.clearinghouse,
                data: abi.encodeCall(IClearinghouseV7.setCreatePaused, (true)),
                what: string.concat("setCreatePaused(true) on ", vm.toString(in_.clearinghouse)),
                guardianRole: true
            });
        }
        for (uint256 i; i < set.length; ++i) {
            MarketConfigV7 memory cfg = state.markets[i].cfg;
            if (!cfg.enabled) continue;
            cfg.enabled = false;
            buf[n++] = Call({
                to: in_.clearinghouse,
                data: abi.encodeCall(IClearinghouseV7.setMarketConfig, (set[i], cfg)),
                what: string.concat(
                    "setMarketConfig(", vm.toString(set[i]), ", enabled = false) on ", vm.toString(in_.clearinghouse)
                ),
                guardianRole: false
            });
        }
        calls = new Call[](n);
        for (uint256 i; i < n; ++i) {
            calls[i] = buf[i];
        }
        _checkFreezeOnly(in_, set, calls);
    }

    /// @dev The tool's teeth. Every planned call must be one of exactly two things sent to the Clearinghouse, and a
    ///      `setMarketConfig` must differ from what the chain holds in `enabled` ALONE. A future edit that tried to
    ///      slip a strikeTick, oracle, fee or a third call into "the freeze" stops here, before a file is written.
    function _checkFreezeOnly(Inputs memory in_, address[] memory set, Call[] memory calls) private view {
        IClearinghouseV7 ch = IClearinghouseV7(in_.clearinghouse);
        for (uint256 i; i < calls.length; ++i) {
            require(calls[i].to == in_.clearinghouse, "a freeze call may only go to the Clearinghouse");
            bytes4 sel = bytes4(calls[i].data);
            if (sel == SET_CREATE_PAUSED) {
                (bool paused) = abi.decode(_tail(calls[i].data), (bool));
                require(paused, "setCreatePaused(false) is not a freeze");
                continue;
            }
            require(sel == SET_MARKET_CONFIG, "a freeze plan holds setCreatePaused and setMarketConfig only");
            (address underlying, MarketConfigV7 memory cfg) =
                abi.decode(_tail(calls[i].data), (address, MarketConfigV7));
            require(_indexOf(set, underlying) != NOT_FOUND, "setMarketConfig for a market outside the freeze set");
            require(!cfg.enabled, "a freeze sets enabled = false");
            MarketConfigV7 memory live = ch.market(underlying);
            require(live.strikeTick == cfg.strikeTick, "the freeze must not move strikeTick");
            require(live.exerciseFeeBps == cfg.exerciseFeeBps, "the freeze must not move exerciseFeeBps");
            require(live.oracle == cfg.oracle, "the freeze must not move the oracle");
            require(live.mintFeePpm == cfg.mintFeePpm, "the freeze must not move mintFeePpm");
        }
    }

    /// @dev Every registered market that is still enabled has to be in the freeze set. The live NVDA market is read
    ///      first from a compiled pin, independently of both operator-controlled arrays. The discovered or supplied
    ///      registered set is then checked too. Without the pin, `V7_REGISTERED_MARKETS` and its defaulted
    ///      `V7_MARKETS` compare the same list to itself and a short override passes.
    function _requireNoEnabledMarketLeftOut(Inputs memory in_) private view {
        IClearinghouseV7 ch = IClearinghouseV7(in_.clearinghouse);

        MarketConfigV7 memory pinnedNvda = ch.market(NVDA);
        _requireEnabledMarketListed(in_.markets, NVDA, pinnedNvda.enabled);

        address[] memory registered = _registeredMarkets(in_);
        for (uint256 i; i < registered.length; ++i) {
            address m = registered[i];
            _requireEnabledMarketListed(in_.markets, m, ch.market(m).enabled);
        }
    }

    function _requireEnabledMarketListed(address[] memory set, address market_, bool enabled) private pure {
        if (!enabled) return;
        require(
            _indexOf(set, market_) != NOT_FOUND,
            string.concat(
                "market ",
                vm.toString(market_),
                " is registered and still enabled but is not in V7_MARKETS. setCreatePaused does not stop mint"
                " on series that already exist, so leaving it enabled leaves new risk open. Add it."
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                                THE READS
    //////////////////////////////////////////////////////////////*/

    function _statusOf(Inputs memory in_, address[] memory set) private view returns (Status memory state) {
        IClearinghouseV7 ch = IClearinghouseV7(in_.clearinghouse);
        state.createPaused = ch.createPaused();
        state.tradingPaused = IOrderBookV7(in_.orderBook).tradingPaused();
        state.lastOrderId = IOrderBookV7(in_.orderBook).lastOrderId();
        state.calendar = ch.calendar();
        state.markets = new MarketStatus[](set.length);
        for (uint256 i; i < set.length; ++i) {
            MarketConfigV7 memory cfg = ch.market(set[i]);
            state.markets[i] = MarketStatus({
                underlying: set[i],
                registered: cfg.strikeTick != 0,
                enabled: cfg.enabled,
                mintPaused: cfg.mintPaused,
                cfg: cfg
            });
        }
    }

    /// @dev Every `SeriesCreated` of the Clearinghouse, in `in_.logChunk`-block chunks so a node with a range cap
    ///      still answers, then each series read back from the chain. The log gives the id; the CHAIN gives the
    ///      settled flag and the live supply, because a log cannot know what happened after it.
    function _discoverSeries(Inputs memory in_, address[] memory set) private view returns (SeriesRow[] memory rows) {
        IClearinghouseV7 ch = IClearinghouseV7(in_.clearinghouse);
        if (in_.knownSeries.length != 0) return _readKnownSeries(ch, set, in_.knownSeries);

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = SERIES_CREATED_TOPIC;
        VmSafe.EthGetLogs[] memory logs = _logs(in_, topics);

        SeriesRow[] memory buf = new SeriesRow[](in_.maxSeries);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 3) continue;
            address underlying = address(uint160(uint256(logs[i].topics[2])));
            if (_indexOf(set, underlying) == NOT_FOUND) continue;
            uint256 longId = uint256(logs[i].topics[1]);
            if (_seen(buf, n, longId)) continue;
            require(
                n < in_.maxSeries,
                string.concat(
                    "more than ",
                    vm.toString(in_.maxSeries),
                    " series: raise V7_MAX_SERIES and re-run (nothing" " was written)"
                )
            );
            buf[n++] = _readSeries(ch, longId);
        }
        rows = new SeriesRow[](n);
        for (uint256 i; i < n; ++i) {
            rows[i] = buf[i];
        }
    }

    /// @dev The ids the caller named, read back the same way the log scan reads them. An id the Clearinghouse does
    ///      not know, or one belonging to a market outside the freeze set, is a mistake in the list and is refused:
    ///      a run-off date computed from a list that quietly dropped entries is worse than no date at all.
    function _readKnownSeries(IClearinghouseV7 ch, address[] memory set, uint256[] memory ids)
        private
        view
        returns (SeriesRow[] memory rows)
    {
        rows = new SeriesRow[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < i; ++j) {
                require(ids[j] != ids[i], string.concat("V7_SERIES lists an id twice: ", vm.toString(ids[i])));
            }
            rows[i] = _readSeries(ch, ids[i]);
            require(
                rows[i].underlying != address(0),
                string.concat("V7_SERIES names an id no series exists for: ", vm.toString(ids[i]))
            );
            require(
                _indexOf(set, rows[i].underlying) != NOT_FOUND,
                string.concat("V7_SERIES names a series outside the freeze set: ", vm.toString(ids[i]))
            );
        }
    }

    function _readSeries(IClearinghouseV7 ch, uint256 longId) private view returns (SeriesRow memory row) {
        SeriesV7 memory s = ch.series(longId);
        row = SeriesRow({
            longId: longId,
            underlying: s.underlying,
            isPut: s.isPut,
            strike: s.strike,
            expiry: s.expiry,
            settled: s.settled,
            longSupply: ch.totalSupply(longId),
            lockedAmount: ch.locked(longId)
        });
    }

    function _runOffOf(Inputs memory in_, address[] memory set, SeriesRow[] memory rows)
        private
        view
        returns (RunOff memory off)
    {
        off.seriesCount = rows.length;
        // casting to 'uint40' is safe because block.timestamp + 45 days is a 2026 instant, far below uint40 max
        // forge-lint: disable-next-line(unsafe-typecast)
        off.tenorCeiling = uint40(block.timestamp + MAX_TENOR);
        for (uint256 i; i < rows.length; ++i) {
            SeriesRow memory r = rows[i];
            if (r.expiry > off.lastExpiry) off.lastExpiry = r.expiry;
            if (r.expiry <= block.timestamp && !r.settled) ++off.unsettledPastCount;
            if (r.longSupply == 0) continue;
            ++off.openSeriesCount;
            off.openUnits += r.longSupply;
            if (r.expiry > off.lastOpenExpiry) off.lastOpenExpiry = r.expiry;
        }
        (off.unaccountedExpiry, off.gridTruncated) = _unaccountedExpiry(in_, set, rows);
    }

    /// @dev The cross-check. Walks the session-close grid over `[gridFrom, now + MAX_TENOR]` and every off-grid
    ///      expiry the owner named, and returns the first expiry that reports open interest without a discovered
    ///      series behind it. That can only mean the log scan is short, which is exactly what must not pass quietly.
    ///
    ///      T-OP-055. The walk is bounded by MAX_GRID_STEPS, and before this row nothing recorded WHY it stopped:
    ///      "passed the ceiling" and "ran out of steps" both fell out of the loop into `return 0`, so a `gridFrom`
    ///      far enough back (96 session closes is about four and a half months) made the check cover less than it
    ///      claimed with no trace. `truncated` is that trace: true only when the loop used every step and the last
    ///      close it looked at was still under the ceiling. A calendar that stops answering ends the walk too, and
    ///      that is a completed walk (there is nothing further to check), not a truncated one.
    /// @return hit The first unaccounted expiry, or 0.
    /// @return truncated Whether the grid walk exhausted MAX_GRID_STEPS before reaching the ceiling.
    function _unaccountedExpiry(Inputs memory in_, address[] memory set, SeriesRow[] memory rows)
        private
        view
        returns (uint40 hit, bool truncated)
    {
        IExpiryCalendarV7 cal = IExpiryCalendarV7(IClearinghouseV7(in_.clearinghouse).calendar());
        uint40 ceiling = _ceiling();
        uint40 at = in_.gridFrom;
        bool reachedEnd;
        for (uint256 step; step < MAX_GRID_STEPS; ++step) {
            uint40 next;
            try cal.nextExpiry(at, false) returns (uint40 e) {
                next = e;
            } catch {
                reachedEnd = true;
                break;
            }
            if (next > ceiling) {
                reachedEnd = true;
                break;
            }
            hit = _expiryUnaccounted(in_, set, rows, next);
            if (hit != 0) return (hit, false);
            at = next;
        }
        truncated = !reachedEnd;
        for (uint256 i; i < in_.extraExpiries.length; ++i) {
            hit = _expiryUnaccounted(in_, set, rows, in_.extraExpiries[i]);
            if (hit != 0) return (hit, truncated);
        }
        return (0, truncated);
    }

    function _expiryUnaccounted(Inputs memory in_, address[] memory set, SeriesRow[] memory rows, uint40 expiry)
        private
        view
        returns (uint40)
    {
        IClearinghouseV7 ch = IClearinghouseV7(in_.clearinghouse);
        for (uint256 i; i < set.length; ++i) {
            if (ch.openInterest(set[i], expiry) == 0) continue;
            bool accounted;
            for (uint256 j; j < rows.length; ++j) {
                if (rows[j].expiry == expiry && rows[j].underlying == set[i] && rows[j].longSupply != 0) {
                    accounted = true;
                    break;
                }
            }
            if (!accounted) return expiry;
        }
        return 0;
    }

    /// @dev `vm.eth_getLogs` over `[in_.fromBlock, block.number]` in `in_.logChunk` chunks, concatenated. `view`:
    ///      the cheatcode is a `VmSafe` read, so every entry point built on it stays `view` too.
    function _logs(Inputs memory in_, bytes32[] memory topics) private view returns (VmSafe.EthGetLogs[] memory out) {
        uint256 toBlock = block.number;
        require(in_.fromBlock <= toBlock, "V7_FROM_BLOCK is ahead of the current block");
        require(in_.logChunk != 0, "V7_LOG_CHUNK is 0");
        uint256 total;
        VmSafe.EthGetLogs[][] memory parts = new VmSafe.EthGetLogs[][](_chunkCount(in_, toBlock));
        uint256 p;
        for (uint256 from = in_.fromBlock; from <= toBlock; from += in_.logChunk) {
            uint256 to = from + in_.logChunk - 1;
            if (to > toBlock) to = toBlock;
            parts[p] = vm.eth_getLogs(from, to, in_.clearinghouse, topics);
            total += parts[p].length;
            ++p;
        }
        out = new VmSafe.EthGetLogs[](total);
        uint256 k;
        for (uint256 i; i < p; ++i) {
            for (uint256 j; j < parts[i].length; ++j) {
                out[k++] = parts[i][j];
            }
        }
    }

    function _chunkCount(Inputs memory in_, uint256 toBlock) private pure returns (uint256) {
        return (toBlock - in_.fromBlock) / in_.logChunk + 1;
    }

    /*//////////////////////////////////////////////////////////////
                               THE REPORT
    //////////////////////////////////////////////////////////////*/

    function _reportStatus(Inputs memory in_, Status memory state) private view {
        console2.log("v7 set on chain", block.chainid, "at block", block.number);
        console2.log(string.concat("  Clearinghouse ", vm.toString(in_.clearinghouse)));
        console2.log(string.concat("  OrderBook     ", vm.toString(in_.orderBook)));
        console2.log(string.concat("  calendar      ", vm.toString(state.calendar)));
        console2.log(string.concat("  guardian      ", vm.toString(in_.guardian), " (GUARDIAN_ROLE: ok)"));
        console2.log(string.concat("  admin         ", vm.toString(in_.admin), " (DEFAULT_ADMIN_ROLE: ok)"));
        console2.log(string.concat("  createPaused  ", state.createPaused ? "true  (frozen)" : "false (open)"));
        console2.log(
            string.concat(
                "  tradingPaused ",
                state.tradingPaused ? "true  <- NOT the freeze: a paused book traps sellers" : "false (as it must be)",
                ", last order id ",
                vm.toString(state.lastOrderId)
            )
        );
        for (uint256 i; i < state.markets.length; ++i) {
            MarketStatus memory m = state.markets[i];
            console2.log(
                string.concat(
                    "  market ",
                    vm.toString(m.underlying),
                    m.enabled ? "  enabled" : "  DISABLED",
                    m.mintPaused ? ", mintPaused" : "",
                    ", strikeTick ",
                    vm.toString(uint256(m.cfg.strikeTick)),
                    ", exerciseFee ",
                    vm.toString(uint256(m.cfg.exerciseFeeBps)),
                    " bps, rent ",
                    vm.toString(uint256(m.cfg.mintFeePpm)),
                    " ppm"
                )
            );
        }
    }

    function _reportRunOff(Inputs memory in_, RunOff memory off, SeriesRow[] memory rows) private view {
        console2.log("");
        console2.log(string.concat("run-off at ", _utc(block.timestamp), ", ", vm.toString(rows.length), " series"));
        for (uint256 i; i < rows.length; ++i) {
            _reportSeries(in_, rows[i]);
        }
        console2.log(
            string.concat(
                "  open: ",
                vm.toString(off.openSeriesCount),
                " series holding ",
                vm.toString(off.openUnits),
                " long units; ",
                vm.toString(off.unsettledPastCount),
                " expired series still to settle"
            )
        );
        console2.log("");
        console2.log(string.concat("  LAST EXPIRY (any series):        ", _stamp(in_, off.lastExpiry)));
        console2.log(string.concat("  LAST EXPIRY still holding units: ", _stamp(in_, off.lastOpenExpiry)));
        console2.log(string.concat("  ceiling, now + MAX_TENOR:        ", _stamp(in_, off.tenorCeiling)));
        if (off.unaccountedExpiry != 0) {
            console2.log(
                string.concat(
                    "  WARNING: ",
                    _stamp(in_, off.unaccountedExpiry),
                    " reports open interest with no series behind it. The SeriesCreated scan is SHORT: widen"
                    " V7_FROM_BLOCK / V7_LOG_CHUNK before trusting the dates above."
                )
            );
        } else if (off.gridTruncated) {
            console2.log(
                string.concat(
                    "  WARNING: grid cross-check TRUNCATED: ",
                    vm.toString(MAX_GRID_STEPS),
                    " session closes walked from V7_GRID_FROM (",
                    _stamp(in_, in_.gridFrom),
                    ") without reaching the ceiling. Expiries past the walk were NOT cross-checked: raise V7_GRID_FROM"
                    " toward the last expiry the scan discovered and re-run before trusting the dates above."
                )
            );
        } else {
            console2.log("  grid cross-check: every expiry carrying open interest has a discovered series.");
        }
    }

    function _reportSeries(Inputs memory in_, SeriesRow memory r) private view {
        console2.log(
            string.concat(
                "  ",
                r.longSupply == 0 ? "  " : "* ",
                r.isPut ? "put  " : "call ",
                _usd(r.strike),
                "  ",
                _stamp(in_, r.expiry),
                r.settled ? "  settled" : (r.expiry <= block.timestamp ? "  EXPIRED, not settled" : "  live"),
                ", ",
                vm.toString(r.longSupply),
                " units, locked ",
                vm.toString(r.lockedAmount)
            )
        );
    }

    /// @dev What the owner does with the plan. Deliberately not a one-liner that runs the whole freeze.
    function _printPlan(Inputs memory in_, Call[] memory calls) private pure {
        console2.log("");
        console2.log("PLAN: ", calls.length, "call(s). NOTHING WAS SENT; this tool has no way to send it.");
        for (uint256 i; i < calls.length; ++i) {
            console2.log(string.concat("  ", calls[i].guardianRole ? "guardian " : "admin    ", calls[i].what));
            console2.logBytes(calls[i].data);
            console2.log(
                string.concat(
                    "      cast send -i ",
                    vm.toString(calls[i].to),
                    " ",
                    vm.toString(calls[i].data),
                    " --rpc-url $RH_RPC   # from ",
                    vm.toString(calls[i].guardianRole ? in_.guardian : in_.admin)
                )
            );
        }
        if (in_.writePlan) {
            console2.log("");
            console2.log("The same calls as Safe{Wallet} Transaction Builder batches:");
            console2.log(string.concat("  guardian  ", in_.guardianPlanOut));
            console2.log(string.concat("  admin     ", in_.adminPlanOut));
        }
        console2.log("");
        console2.log("ORDER: send the guardian's setCreatePaused(true) FIRST, the market disables after it. Then");
        console2.log("re-run this tool: it must plan nothing and print the post-check. docs/V7-RUNOFF.md is the");
        console2.log("runbook; it also says what a v7 user can still do afterwards, which is everything but");
        console2.log("opening new risk.");
    }

    /*//////////////////////////////////////////////////////////////
                              THE PLAN FILES
    //////////////////////////////////////////////////////////////*/

    /// @dev Safe{Wallet} Transaction Builder batch, version 1.0, exactly as `script/v2/FreezeV1.s.sol` writes it: no
    ///      `checksum` (the app warns, which is the honest state of a generated file, and why the runbook decodes
    ///      every call), zero-value calls, `createdFromSafeAddress` the role holder named in the inputs. One file per
    ///      ROLE, because the guardian's call and the admin's calls are signed by different keys.
    function _writePlan(string memory path, address signer, Call[] memory calls, bool guardianRole) private {
        string memory txs = "";
        uint256 n;
        for (uint256 i; i < calls.length; ++i) {
            if (calls[i].guardianRole != guardianRole) continue;
            txs = string.concat(
                txs,
                n == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
            ++n;
        }
        if (n == 0) return;
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Stonkhouse v7 freeze: ',
            guardianRole ? "setCreatePaused(true)" : "setMarketConfig(enabled = false)",
            '","description":"',
            vm.toString(n),
            " call(s). New risk only: close, redeem, withdraw and cancel keep working. Generated read-only by",
            ' script/v2/FreezeV7.s.sol; the owner sends them.","createdFromSafeAddress":"',
            vm.toString(signer),
            '"},"transactions":[',
            txs,
            "]}"
        );
        vm.createDir("broadcast", true);
        vm.writeFile(path, json);
        console2.log(string.concat(guardianRole ? "guardian" : "admin", " plan written: "), path);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _inputsFromEnv() private view returns (Inputs memory in_) {
        in_.clearinghouse = vm.envOr("V7_CLEARINGHOUSE", CLEARINGHOUSE);
        in_.orderBook = vm.envOr("V7_ORDER_BOOK", ORDER_BOOK);
        in_.guardian = vm.envOr("V7_GUARDIAN", GUARDIAN);
        in_.admin = vm.envOr("V7_ADMIN", ADMIN);
        in_.fromBlock = vm.envOr("V7_FROM_BLOCK", DEPLOY_BLOCK);
        in_.logChunk = vm.envOr("V7_LOG_CHUNK", DEFAULT_LOG_CHUNK);
        in_.maxSeries = vm.envOr("V7_MAX_SERIES", DEFAULT_MAX_SERIES);
        // T-OP-055. Bounded to [DEPLOY_TS, now]: no v7 expiry exists before the deploy, so an earlier start only
        // spends grid steps on empty closes (and, past MAX_GRID_STEPS of them, silently truncates the walk); a future
        // start would skip every close between now and it. Refused, not clamped: a clamp would hide the mistake.
        // The `Inputs` struct itself is not bounded here -- the in-process fixtures legitimately start before the
        // live deploy -- so this guards the operator's variable, which is the only way a bad value reaches a run.
        in_.gridFrom = gridFromInBounds(vm.envOr("V7_GRID_FROM", uint256(DEPLOY_TS)));
        in_.writePlan = vm.envOr("V7_PLAN", true);
        in_.guardianPlanOut = vm.envOr("V7_GUARDIAN_PLAN_OUT", DEFAULT_GUARDIAN_PLAN_OUT);
        in_.adminPlanOut = vm.envOr("V7_ADMIN_PLAN_OUT", DEFAULT_ADMIN_PLAN_OUT);
        in_.expectChainId = vm.envOr("V7_EXPECT_CHAIN_ID", CHAIN_ID_4663);

        uint256[] memory extra = vm.envOr("V7_EXTRA_EXPIRIES", ",", new uint256[](0));
        in_.extraExpiries = new uint40[](extra.length);
        for (uint256 i; i < extra.length; ++i) {
            in_.extraExpiries[i] = _uint40(extra[i], "V7_EXTRA_EXPIRIES");
        }
        in_.registeredMarkets = vm.envOr("V7_REGISTERED_MARKETS", ",", new address[](0));
        in_.knownSeries = vm.envOr("V7_SERIES", ",", new uint256[](0));
        in_.markets = vm.envOr("V7_MARKETS", ",", _registeredMarkets(in_));
    }

    /// @dev Every underlying the `MarketRegistered` logs name. The default freeze set, so the owner never has to
    ///      know how many markets v7 ended up with; {freezeSet} still refuses a hand-written set that drops one.
    function _registeredMarkets(Inputs memory in_) private view returns (address[] memory out) {
        if (in_.registeredMarkets.length != 0) return in_.registeredMarkets;
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = MARKET_REGISTERED_TOPIC;
        VmSafe.EthGetLogs[] memory logs = _logs(in_, topics);
        address[] memory buf = new address[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2) continue;
            address m = address(uint160(uint256(logs[i].topics[1])));
            if (_indexOf(buf, m) != NOT_FOUND) continue;
            buf[n++] = m;
        }
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = buf[i];
        }
    }

    /// @notice The V7_GRID_FROM bound (T-OP-055): `gridFrom` must lie in [DEPLOY_TS, block.timestamp], inclusive.
    ///         Reverts naming the variable and the bound otherwise; returns the value as uint40.
    /// @dev Public so the refusal can be tested without the process-global environment.
    function gridFromInBounds(uint256 gridFrom) public view returns (uint40) {
        require(
            gridFrom >= DEPLOY_TS,
            string.concat(
                "V7_GRID_FROM ",
                vm.toString(gridFrom),
                " is before DEPLOY_TS ",
                vm.toString(uint256(DEPLOY_TS)),
                ": no v7 expiry exists before the deploy; the grid walk must start in [DEPLOY_TS, now]"
            )
        );
        require(
            gridFrom <= block.timestamp,
            string.concat(
                "V7_GRID_FROM ",
                vm.toString(gridFrom),
                " is in the future (now ",
                vm.toString(block.timestamp),
                "): the grid walk would skip every close before it; it must start in [DEPLOY_TS, now]"
            )
        );
        return _uint40(gridFrom, "V7_GRID_FROM");
    }

    function _ceiling() private view returns (uint40) {
        // casting to 'uint40' is safe because block.timestamp + 45 days is a 2026 instant, far below uint40 max
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(block.timestamp + MAX_TENOR);
    }

    function _uint40(uint256 v, string memory what) private pure returns (uint40) {
        require(v <= type(uint40).max, string.concat(what, " is above uint40: it cannot be a v7 expiry"));
        // casting to 'uint40' is safe because the value is checked to fit first
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(v);
    }

    /// @dev `data` without its 4-byte selector, so `abi.decode` can read the arguments back.
    function _tail(bytes memory data) private pure returns (bytes memory out) {
        require(data.length >= 4, "call data shorter than a selector");
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    function _seen(SeriesRow[] memory buf, uint256 n, uint256 longId) private pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (buf[i].longId == longId) return true;
        }
        return false;
    }

    function _indexOf(address[] memory set, address a) private pure returns (uint256) {
        for (uint256 i; i < set.length; ++i) {
            if (set[i] == a) return i;
        }
        return NOT_FOUND;
    }

    function _check(bool ok, string memory what) private pure returns (uint256 failed) {
        console2.log(string.concat(ok ? "  ok    " : "  FAIL  ", what));
        return ok ? 0 : 1;
    }

    /// @dev An expiry as "<unix> (YYYY-MM-DD HH:MM:SSZ = HH:MM New York)". The New York clock comes from the live
    ///      calendar's own `newYorkOffset`, never from a local guess about daylight saving.
    function _stamp(Inputs memory in_, uint40 ts) private view returns (string memory) {
        if (ts == 0) return "none";
        string memory local = "";
        try IExpiryCalendarV7(IClearinghouseV7(in_.clearinghouse).calendar()).newYorkOffset(ts) returns (int32 off) {
            local = string.concat(
                " = ", _civil(uint256(int256(uint256(ts)) + int256(off))), off == -4 hours ? " EDT" : " EST"
            );
        } catch {}
        return string.concat(vm.toString(uint256(ts)), " (", _utc(ts), local, ")");
    }

    /// @dev A unix second as "YYYY-MM-DD HH:MM:SSZ": {_civil} with the UTC marker.
    function _utc(uint256 ts) private pure returns (string memory) {
        return string.concat(_civil(ts), "Z");
    }

    /// @dev A count of seconds as "YYYY-MM-DD HH:MM:SS", with no zone marker, so {_stamp} can render the same
    ///      instant shifted into New York local time. Howard Hinnant's civil_from_days, unsigned: every timestamp
    ///      this tool prints is after 1970.
    function _civil(uint256 ts) private pure returns (string memory) {
        uint256 z = ts / 1 days + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        uint256 y = yoe + era * 400 + (m <= 2 ? 1 : 0);
        uint256 sod = ts % 1 days;
        return string.concat(
            vm.toString(y),
            "-",
            _pad(m),
            "-",
            _pad(d),
            " ",
            _pad(sod / 1 hours),
            ":",
            _pad((sod % 1 hours) / 1 minutes),
            ":",
            _pad(sod % 1 minutes)
        );
    }

    /// @dev USDG base units (6 dp) as "$<whole>.<2 dp>", the way a strike is quoted.
    function _usd(uint256 amount6) private pure returns (string memory) {
        return string.concat("$", vm.toString(amount6 / 1e6), ".", _pad((amount6 % 1e6) / 1e4));
    }

    function _pad(uint256 n) private pure returns (string memory) {
        return n < 10 ? string.concat("0", vm.toString(n)) : vm.toString(n);
    }
}
