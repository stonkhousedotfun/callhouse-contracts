// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {DeployV8} from "./DeployV8.s.sol";

/// @notice T-OP-153. Maps the selectors of the six externally deployed `roles.v8.json` targets (HouseVault,
///         HouseVaultFactory, Hedger, RewardsDistributorLender, EarnVault, StockVenueAdapter) at delay 0, from the
///         deployer's ADMIN, on a set that `DeployV8` left with its hand-back DEFERRED (`V2_DEFER_HANDBACK=true`).
/// @dev THE LAUNCH SEQUENCE THIS SCRIPT SITS IN (owner decisions 2026-09-22 05:35Z and 05:50Z / amendment #1: no
///      48 h Safe gap at launch, and the deferred window also covers market registration):
///        1. `DeployV8.s.sol` with V2_DEFER_HANDBACK=true  -- steps 1-7; the deployer keeps ADMIN and every
///                                                             `.targets` role at delay 0.
///        2. the externals' own deploy scripts (T-OP-116's driver) -- each address exported as its V2_* name.
///        3. THIS SCRIPT                                    -- `setTargetFunctionRole` for every SUPPLIED external.
///        4. `RegisterMarkets.s.sol` AS THE DEPLOYER        -- V2_ADMIN=<deployer>, ADMIN_PK its key, V2_SCHEDULE
///                                                             unset: LISTING and CONFIG_ADMIN at delay 0, so every
///                                                             call is direct (`_signerCanList`, `_requireImmediate`).
///                                                             `createVault` (T-OP-141) runs here by the same rule.
///        5. `HandBack.s.sol`                               -- the deferred steps 8 + 9: drops, then renounces ADMIN.
///        6. `VerifyV8.s.sol`                               -- unchanged; `_handover` FAILS until 5 has run.
///      ACCEPTED COST (coordinator stated, owner accepted): the deployer hot key holds ADMIN and the delay-0 working
///      roles for the minutes between 1 and 5, across several transactions. A driver that dies in between leaves it
///      holding them until 5 runs.
///
///      NO SECOND SELECTOR LOOP. The mapping is `DeployV8._mapTarget` -- the same planner step 3 of the deploy runs
///      for the sixteen it creates, reached here by inheritance. It reads the signatures from `roles.v8.json`,
///      hashes them, skips the ones the manager already holds, and refuses a target this script does not know.
///      A copy of that loop here would be the drift shape T-OP-022 was about.
///
///      WHAT IT REFUSES, and each is deliberate:
///        - the deployer does not hold ADMIN: this is a set that already had its hand-back (or was never deferred).
///          `setTargetFunctionRole` from a non-ADMIN reverts inside the manager anyway; refusing here names the cause
///          ("run before HandBack.s.sol") instead of `AccessManagerUnauthorizedAccount`.
///        - an incomplete core set (`_wholeSet`): every one of the sixteen must be given and have code.
///        - a supplied external that does not answer the interface its manifest name claims (T-426's probes).
///      WHAT IT SKIPS, BY NAME: an external whose V2_* variable is unset is announced and left alone -- it belongs in
///      `V2_SKIP_EXTERNALS` (T-OP-140) or is deployed later. Mapping at address(0) is impossible twice over: this
///      script skips a zero address before planning, and `DeployV8._mapTarget` skips it again.
///      V2_SKIP_EXTERNALS is read here with VerifyV8's spelling and VerifyV8's fail-closed rules (T-OP-140, T-OP-161):
///      a comma list of MANIFEST NAMES among the six; a name that is not one of the six REVERTS, a listed name whose
///      V2_* variable IS supplied REVERTS naming the variable (a skip of a supplied target is a look-away), a
///      duplicate REVERTS. An unsupplied external that is NOT listed is still skipped, with a WARN that VerifyV8
///      will FAIL on it -- the driver's list and the driver's environment disagree, and this is the earliest place
///      that says so. Unset means no skip list: every unsupplied external is a WARN.
///      Owner rulings 2026-09-22 05:45Z: the launch externals are HouseVaultFactory, the NVDA HouseVault (the
///      manifest's single `HouseVault` target, `V2_HOUSE_VAULT`) and EarnVault; Hedger, StockVenueAdapter and
///      RewardsDistributorLender are OUT for launch and are what this script skips by name.
///      TWO VAULTS (owner ruling: NVDA + SPCX; T-OP-196). Every launch ticker's vault, `V2_MARKET_<T>_HOUSE_VAULT`
///      (T-OP-161 exports it per ticker whose `markets[].v2.houseVault` is set, unset otherwise -- the same reader
///      VerifyV8 uses, `VerifyV8.s.sol:578-584`), is mapped HERE, inside the deployer's window, with the manifest's
///      `HouseVault` selector block through the same `_mapTarget` -- one planner, no second selector list. The
///      first launch ticker's vault IS `V2_HOUSE_VAULT` (registry option A) and is planned once: the manifest loop
///      already mapped it and the per-ticker pass finds nothing left. A ticker whose slot is unset is skipped BY
///      TICKER (VerifyV8 reports it NOT CHECKED by ticker); a vault with no code is refused; two tickers on one
///      address are refused (VerifyV8's one-vault-per-ticker rule, `_houseVault`). The earlier note that a second
///      vault "is mapped by the factory's own createVault batch" was wrong: run 4c's VerifyV8 failed on exactly the
///      second vault's 15 unmapped selectors, and the day-zero batch's map stage (T-OP-172) is the POST-launch path
///      for vaults the Safe creates later -- for the launch vaults it must find nothing to map (idempotent).
///
///      Driven by T-OP-116's driver with the registry's V2_* environment loaded (the six externals included):
///        forge script script/v2/MapExternals.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching \
///          --non-interactive
///      Idempotent: a second run plans nothing ("map externals: nothing to send") and exits 0.
contract MapExternals is DeployV8 {
    /// @dev Entry point: the same environment and signer rules as `DeployV8.run`, then {mapWith}.
    function run() external override returns (Contracts memory d) {
        Inputs memory in_ = inputsFromEnv();
        Signer memory deployer = _deployerFromEnv(in_);
        require(deployer.addr != address(0), "V2_DEPLOYER (or DEPLOYER_PK) is required: it is the ADMIN that maps");
        require(
            block.chainid == in_.expectChainId,
            string.concat("chain id ", vm.toString(block.chainid), ", expected ", vm.toString(in_.expectChainId))
        );
        d = in_.existing;
        (string[] memory tickers, address[] memory vaults) = marketVaultsFromEnv();
        (uint256 mapped, string[] memory supplied, string[] memory skipped) =
            mapWith(in_, deployer, skipListFromEnv(), tickers, vaults);
        console2.log("");
        console2.log(
            string.concat(
                "MAP EXTERNALS DONE: ",
                vm.toString(mapped),
                " setTargetFunctionRole call(s) sent for ",
                vm.toString(supplied.length),
                " supplied external(s); ",
                vm.toString(skipped.length),
                " not supplied and skipped by name"
            )
        );
    }

    /// @notice The launch tickers and their vault slots, read exactly as VerifyV8 reads them (`VerifyV8.s.sol:578-584`):
    ///         `V2_TICKERS` (the driver exports the registry's launch set) and, per ticker,
    ///         `V2_MARKET_<T>_HOUSE_VAULT` -- zero when the registry's `markets[].v2.houseVault` is null.
    function marketVaultsFromEnv() public view returns (string[] memory tickers, address[] memory vaults) {
        string memory raw = vm.envOr("V2_TICKERS", string(""));
        tickers = bytes(raw).length == 0 ? new string[](0) : vm.split(raw, ",");
        vaults = new address[](tickers.length);
        for (uint256 i; i < tickers.length; ++i) {
            vaults[i] = vm.envOr(_mk(tickers[i], "HOUSE_VAULT"), address(0));
        }
    }

    /// @notice The per-ticker outcome of the last {mapWith}: which tickers' vaults were planned (mapped or already
    ///         mapped) and which were skipped because their slot was unset. Storage so a test can read it back.
    string[] public vaultTickersMapped;
    string[] public vaultTickersSkipped;

    /// @notice `V2_SKIP_EXTERNALS` as VerifyV8 spells it: comma-separated manifest names, or empty when unset.
    function skipListFromEnv() public view returns (string[] memory) {
        string memory raw = vm.envOr("V2_SKIP_EXTERNALS", string(""));
        if (bytes(raw).length == 0) return new string[](0);
        return vm.split(raw, ",");
    }

    /// @notice Maps every SUPPLIED external through `DeployV8._mapTarget` and returns what it did.
    /// @param skip   the V2_SKIP_EXTERNALS list (manifest names); {run} passes {skipListFromEnv}.
    /// @return mapped   calls sent (already-mapped selectors are not re-sent).
    /// @return supplied the manifest names that had an address and were (re)planned.
    /// @return skipped  the manifest names whose V2_* variable was unset, announced and left unmapped.
    function mapWith(Inputs memory in_, Signer memory deployer, string[] memory skip)
        public
        returns (uint256 mapped, string[] memory supplied, string[] memory skipped)
    {
        return mapWith(in_, deployer, skip, new string[](0), new address[](0));
    }

    /// @notice {mapWith} plus the per-ticker House vaults (T-OP-196): `tickers[i]`'s vault `vaults[i]` (zero = the
    ///         registry slot is null) is mapped with the manifest's `HouseVault` block by the same planner.
    function mapWith(
        Inputs memory in_,
        Signer memory deployer,
        string[] memory skip,
        string[] memory tickers,
        address[] memory vaults
    ) public returns (uint256 mapped, string[] memory supplied, string[] memory skipped) {
        require(tickers.length == vaults.length, "MapExternals: one vault slot per ticker");
        Contracts memory c = in_.existing;
        require(c.accessManager != address(0), "MapExternals: V2_ACCESS_MANAGER is zero: this script maps onto a deployed set");
        _wholeSet(c);
        _requireDeployerHoldsAdmin(c, deployer.addr);
        _checkSkipList(c, skip);

        Plan memory p = Plan(rolesJson(), c.accessManager, new Call[](128), 0);
        string[] memory targets = targetNames(p.json);
        string[] memory sup = new string[](targets.length);
        string[] memory skp = new string[](targets.length);
        uint256 ns;
        uint256 nk;
        for (uint256 t; t < targets.length; ++t) {
            if (!_externallySupplied(targets[t])) continue;
            address target = _targetAddress(c, targets[t]);
            if (target == address(0)) {
                skp[nk++] = targets[t];
                if (_listed(skip, targets[t])) {
                    _skip(
                        string.concat(
                            targets[t], ": not supplied and listed in V2_SKIP_EXTERNALS; VerifyV8 will report it NOT CHECKED"
                        )
                    );
                } else {
                    _warn(
                        string.concat(
                            targets[t],
                            ": not supplied (",
                            _envNameFor(targets[t]),
                            " unset) and NOT in V2_SKIP_EXTERNALS; its selectors stay unmapped and VerifyV8 will FAIL on"
                            " them -- list it, or deploy it and re-run this script before HandBack.s.sol"
                        )
                    );
                }
                continue;
            }
            sup[ns++] = targets[t];
            // DeployV8 step 3, for this one target. The loop, the hashing and the already-mapped skip are all its.
            _mapTarget(p, targets[t], target);
        }
        _planMarketVaults(p, c, tickers, vaults);
        mapped = _send(deployer, _trim(p.buf, p.n), "map externals");

        // Post-check, per supplied external: planning it again must find nothing left to map.
        for (uint256 i; i < ns; ++i) {
            Plan memory again = Plan(p.json, c.accessManager, new Call[](128), 0);
            _mapTarget(again, sup[i], _targetAddress(c, sup[i]));
            require(
                again.n == 0,
                string.concat("post-check: ", sup[i], " still has ", vm.toString(again.n), " unmapped selector(s)")
            );
            _ok(string.concat(sup[i], ": every roles.v8.json selector mapped to its manifest role"));
        }
        // Post-check, per ticker vault: the same rule, and the sentence run 4c's VerifyV8 was missing.
        for (uint256 i; i < vaults.length; ++i) {
            if (vaults[i] == address(0)) continue;
            Plan memory again = Plan(p.json, c.accessManager, new Call[](128), 0);
            _mapTarget(again, "HouseVault", vaults[i]);
            require(
                again.n == 0,
                string.concat("post-check: houseVault ", tickers[i], " still has ", vm.toString(again.n), " unmapped selector(s)")
            );
            _ok(string.concat("houseVault ", tickers[i], " ", vm.toString(vaults[i]), ": every HouseVault selector mapped to its manifest role"));
        }
        supplied = _trimNames(sup, ns);
        skipped = _trimNames(skp, nk);
    }

    /// @dev T-OP-196. Plans the manifest `HouseVault` block onto every ticker's vault that is set, into the SAME plan
    ///      the manifest loop filled (one send, one post-check shape). Per ticker, in order:
    ///        - zero: skipped by ticker (the registry slot is null; VerifyV8 reports it NOT CHECKED by ticker);
    ///        - no code: refused (a slot that names nothing deployed is a write-back error, not a target);
    ///        - the same address as an earlier ticker: refused (one vault per ticker, VerifyV8's rule);
    ///        - T-426's probe (`underlying()`, `clearinghouse()`): a vault that does not answer is refused;
    ///        - `_mapTarget(p, "HouseVault", v)`: DeployV8 step 3's planner; already-mapped selectors plan nothing,
    ///          so the first launch ticker's vault (== `V2_HOUSE_VAULT`, mapped by the manifest loop) plans 0 and
    ///          is said so, and a re-run plans 0 for every vault.
    function _planMarketVaults(Plan memory p, Contracts memory c, string[] memory tickers, address[] memory vaults)
        internal
    {
        delete vaultTickersMapped;
        delete vaultTickersSkipped;
        for (uint256 i; i < tickers.length; ++i) {
            address v = vaults[i];
            if (v == address(0)) {
                vaultTickersSkipped.push(tickers[i]);
                _skip(
                    string.concat(
                        "houseVault ", tickers[i], ": unset, skipped (markets[].v2.houseVault is null; VerifyV8 reports it NOT CHECKED by ticker)"
                    )
                );
                continue;
            }
            require(
                v.code.length != 0,
                string.concat("houseVault ", tickers[i], " ", vm.toString(v), " has no code: markets[].v2.houseVault names nothing deployed")
            );
            for (uint256 j; j < i; ++j) {
                require(
                    vaults[j] != v,
                    string.concat("houseVault ", tickers[i], " ", vm.toString(v), " is also market ", tickers[j], "'s vault: one vault per ticker")
                );
            }
            _probe(v, string.concat("HouseVault(", tickers[i], ")"), "underlying()", "clearinghouse()");
            uint256 before = p.n;
            _mapTarget(p, "HouseVault", v);
            uint256 planned = p.n - before;
            vaultTickersMapped.push(tickers[i]);
            if (v == c.houseVault) {
                _ok(
                    string.concat(
                        "houseVault ", tickers[i], " ", vm.toString(v), ": is V2_HOUSE_VAULT (the manifest's HouseVault, registry option A), planned once: ",
                        vm.toString(planned), " selector(s) left to map"
                    )
                );
            } else {
                _ok(string.concat("houseVault ", tickers[i], " ", vm.toString(v), ": ", vm.toString(planned), " selector(s) mapped"));
            }
        }
    }

    /// @dev VerifyV8's three refusals on the skip list, applied here first so a driver whose list and environment
    ///      disagree is stopped before anything is mapped, not at the verify gate.
    function _checkSkipList(Contracts memory c, string[] memory skip) internal view {
        for (uint256 i; i < skip.length; ++i) {
            require(
                _externallySupplied(skip[i]),
                string.concat(
                    "V2_SKIP_EXTERNALS names '",
                    skip[i],
                    "', which is not one of the six externally supplied manifest targets (spell the roles.v8.json target"
                    " name, not the registry key)"
                )
            );
            require(
                _targetAddress(c, skip[i]) == address(0),
                string.concat(
                    "V2_SKIP_EXTERNALS names ", skip[i], " but ", _envNameFor(skip[i]), " is supplied: a skip of a supplied"
                    " target is a look-away; drop it from the list or unset the variable"
                )
            );
            for (uint256 j; j < i; ++j) {
                require(!_eq(skip[i], skip[j]), string.concat("V2_SKIP_EXTERNALS lists ", skip[i], " twice"));
            }
        }
        if (skip.length != 0) _ok(string.concat("V2_SKIP_EXTERNALS: ", vm.toString(skip.length), " external(s) deliberately not deployed"));
    }

    function _listed(string[] memory skip, string memory name) internal pure returns (bool) {
        for (uint256 i; i < skip.length; ++i) {
            if (_eq(skip[i], name)) return true;
        }
        return false;
    }

    /// @dev The precondition this script exists behind. After HandBack the deployer holds nothing, and
    ///      `setTargetFunctionRole` is ADMIN's alone.
    function _requireDeployerHoldsAdmin(Contracts memory c, address deployer) internal view {
        uint64 adminRole = roleIdOf(rolesJson(), "ADMIN");
        (bool isAdmin,) = AccessManager(c.accessManager).hasRole(adminRole, deployer);
        require(
            isAdmin,
            string.concat(
                "MapExternals: the deployer ",
                vm.toString(deployer),
                " does not hold ADMIN on ",
                vm.toString(c.accessManager),
                ": run before HandBack.s.sol. After the hand-back the externals can only be mapped by the Admin Safe"
                " through its delayed ADMIN lane."
            )
        );
        _ok("the deployer holds ADMIN: the deferred hand-back has not happened yet");
    }

    function _trimNames(string[] memory buf, uint256 n) internal pure returns (string[] memory out) {
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = buf[i];
        }
    }
}
