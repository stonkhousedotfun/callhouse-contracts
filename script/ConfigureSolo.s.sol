// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {PolicyParams} from "../src/Policy.sol";
import {AccountFactory} from "../src/solo/AccountFactory.sol";

/// @notice Grants the operating roles (and, if asked, the deposit cap or a policy) on a deployed
///         AccountFactory: the src/solo/ counterpart of `script/Configure.s.sol`.
/// @dev Two modes, chosen by whether ADMIN_PK is set:
///
///        1. KEY ADMIN (bootstrap, the launch plan for every Tier 1 market). The factory was deployed with
///           `ADMIN` = a key's address, so the calls are broadcast from that key:
///             FACTORY=0x... KEEPER=0x... GUARDIAN=0x... ADMIN_PK=... \
///               forge script script/ConfigureSolo.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching
///           Refuses if ADMIN_PK does not hold DEFAULT_ADMIN_ROLE.
///        2. SAFE BATCH. No key: writes a Safe{Wallet} Transaction Builder batch to SAFE_BATCH_OUT
///           (default `broadcast/configure-solo-safe-batch.json`) for the admin Safe to import, decode,
///           sign and execute. Nothing is broadcast.
///
///      The batch file is written in both modes, so the calls a key broadcasts and the calls a Safe would
///      sign are the same bytes (`script/rehearsal/ExecuteSafeBatch.s.sol` executes such a file on anvil).
///
///      IDEMPOTENT. A grant the address already holds is skipped and logged "already granted"; the cap is
///      set only when DEPOSIT_CAP is set AND differs from `depositCap()`; a policy only when SET_POLICY is
///      true and the parameters differ from `policy()`. Re-running after a partial broadcast, or running
///      the batch script twice, therefore sends nothing twice, and a routine configure run never changes
///      policy by accident.
///
///      ENVIRONMENT
///        FACTORY          required. The AccountFactory.
///        KEEPER, GUARDIAN required, distinct from each other and from the admin (the keeper is a hot key
///                         that must never hold an admin power; the guardian is the halt key).
///        ADMIN_PK         key-admin mode when set; otherwise the batch is written and nothing broadcast.
///        DEPOSIT_CAP      optional. `setDepositCap` when set and different from the current cap.
///        SET_POLICY       optional, default false. With MIN_OTM_BPS, MAX_OTM_BPS, MIN_PREMIUM_BPS,
///                         MAX_UTILIZATION_BPS, PROTOCOL_FEE_BPS, MAX_CONTRACTS_CAP (defaults are
///                         Policy.launchDefaults(), as in Configure.s.sol).
///        SAFE_ADMIN       optional, the Safe named in the batch file's `createdFromSafeAddress`.
///        SAFE_BATCH_OUT   optional, default broadcast/configure-solo-safe-batch.json.
///
///      `runWith(Inputs)` is the same procedure with explicit inputs; the unit test drives it that way
///      because `vm.setEnv` writes the process environment, which every test thread shares, and the
///      DeploySolo preflight test is already the one env-driven test in the suite.
contract ConfigureSolo is Script {
    struct Call {
        address to;
        bytes data;
        string what;
    }

    struct Inputs {
        AccountFactory factory;
        address keeper;
        address guardian;
        uint256 adminPk;
        bool capSet;
        uint256 depositCap;
        bool setPolicy;
        PolicyParams policy;
        address safeAdmin;
        string batchOut;
    }

    function run() external returns (uint256 executed, uint256 skipped) {
        return runWith(_inputsFromEnv());
    }

    /// @return executed calls broadcast from ADMIN_PK (0 in batch mode)
    /// @return skipped  calls not made because the chain already holds the wanted state
    function runWith(Inputs memory in_) public returns (uint256 executed, uint256 skipped) {
        require(address(in_.factory).code.length != 0, "FACTORY has no code");
        require(in_.keeper != address(0) && in_.guardian != address(0), "KEEPER and GUARDIAN must be set");
        require(in_.keeper != in_.guardian, "keeper and guardian must be different keys");
        address admin = in_.adminPk != 0 ? vm.addr(in_.adminPk) : in_.safeAdmin;
        require(in_.keeper != admin && in_.guardian != admin, "keeper and guardian must differ from the admin");

        Call[] memory calls;
        (calls, skipped) = _buildCalls(in_);
        if (calls.length != 0) _writeSafeBatch(in_, calls);
        else console2.log("nothing to do: every grant is held and every parameter already set");

        if (in_.adminPk != 0) {
            _executeAsKeyAdmin(in_.factory, in_.adminPk, calls);
            executed = calls.length;
            _postCheck(in_);
        } else {
            console2.log("");
            console2.log("NOTHING BROADCAST. Import the batch into Safe{Wallet} Transaction Builder on the admin");
            console2.log(
                "Safe, decode and compare every call (docs/DEPLOY.md), sign, execute. Then run VerifySolo.s.sol."
            );
        }
    }

    function _inputsFromEnv() internal view returns (Inputs memory in_) {
        in_.factory = AccountFactory(vm.envAddress("FACTORY"));
        in_.keeper = vm.envAddress("KEEPER");
        in_.guardian = vm.envAddress("GUARDIAN");
        in_.adminPk = vm.envOr("ADMIN_PK", uint256(0));
        // "set" means present and non-empty: an empty DEPOSIT_CAP= from a shell is not a request for a zero cap.
        in_.capSet = vm.envExists("DEPOSIT_CAP") && bytes(vm.envString("DEPOSIT_CAP")).length != 0;
        if (in_.capSet) in_.depositCap = vm.envUint("DEPOSIT_CAP");
        in_.setPolicy = vm.envOr("SET_POLICY", false);
        if (in_.setPolicy) {
            in_.policy = PolicyParams({
                minOtmBps: uint16(vm.envOr("MIN_OTM_BPS", uint256(300))),
                maxOtmBps: uint16(vm.envOr("MAX_OTM_BPS", uint256(1200))),
                minPremiumBps: uint16(vm.envOr("MIN_PREMIUM_BPS", uint256(40))),
                maxUtilizationBps: uint16(vm.envOr("MAX_UTILIZATION_BPS", uint256(9500))),
                protocolFeeBps: uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(500))),
                maxContractsCap: uint64(vm.envOr("MAX_CONTRACTS_CAP", uint256(50)))
            });
        }
        in_.safeAdmin = vm.envOr("SAFE_ADMIN", address(0));
        in_.batchOut = vm.envOr("SAFE_BATCH_OUT", string("broadcast/configure-solo-safe-batch.json"));
    }

    /// @dev Builds only the calls that change something. Reads the factory first so a re-run is a no-op.
    function _buildCalls(Inputs memory in_) internal view returns (Call[] memory calls, uint256 skipped) {
        AccountFactory f = in_.factory;
        Call[] memory buf = new Call[](4);
        uint256 n;

        console2.log("factory  ", address(f));
        console2.log("keeper   ", in_.keeper);
        console2.log("guardian ", in_.guardian);

        if (f.hasRole(f.KEEPER_ROLE(), in_.keeper)) {
            console2.log("  skip  grantRole(KEEPER_ROLE, keeper): already granted");
            skipped++;
        } else {
            buf[n++] = Call({
                to: address(f),
                data: abi.encodeCall(f.grantRole, (f.KEEPER_ROLE(), in_.keeper)),
                what: "grantRole(KEEPER_ROLE, keeper)"
            });
        }
        if (f.hasRole(f.GUARDIAN_ROLE(), in_.guardian)) {
            console2.log("  skip  grantRole(GUARDIAN_ROLE, guardian): already granted");
            skipped++;
        } else {
            buf[n++] = Call({
                to: address(f),
                data: abi.encodeCall(f.grantRole, (f.GUARDIAN_ROLE(), in_.guardian)),
                what: "grantRole(GUARDIAN_ROLE, guardian)"
            });
        }
        if (in_.capSet) {
            if (f.depositCap() == in_.depositCap) {
                console2.log("  skip  setDepositCap: already", in_.depositCap);
                skipped++;
            } else {
                buf[n++] = Call({
                    to: address(f),
                    data: abi.encodeCall(f.setDepositCap, (in_.depositCap)),
                    what: string.concat("setDepositCap(", vm.toString(in_.depositCap), ")")
                });
            }
        }
        // The constructor already installs Policy.launchDefaults(); set it again only if asked to and it
        // differs, so a routine configure run does not silently change policy.
        if (in_.setPolicy) {
            if (_samePolicy(f, in_.policy)) {
                console2.log("  skip  setPolicy: already set");
                skipped++;
            } else {
                buf[n++] =
                    Call({to: address(f), data: abi.encodeCall(f.setPolicy, (in_.policy)), what: "setPolicy(...)"});
            }
        }

        calls = new Call[](n);
        for (uint256 i; i < n; i++) {
            calls[i] = buf[i];
            console2.log(string.concat("call ", vm.toString(i), ": ", calls[i].what));
            console2.logBytes(calls[i].data);
        }
    }

    function _samePolicy(AccountFactory f, PolicyParams memory p) internal view returns (bool) {
        (uint16 minOtm, uint16 maxOtm, uint16 minPrem, uint16 maxUtil, uint16 feeBps, uint64 cap) = f.policy();
        return minOtm == p.minOtmBps && maxOtm == p.maxOtmBps && minPrem == p.minPremiumBps
            && maxUtil == p.maxUtilizationBps && feeBps == p.protocolFeeBps && cap == p.maxContractsCap;
    }

    /// @dev Safe{Wallet} Transaction Builder batch format (version 1.0). No `checksum` field: the app accepts
    ///      a batch without one and shows a warning, which is the honest state for a file a script
    ///      generated. Every call is a zero-value call to the factory.
    function _writeSafeBatch(Inputs memory in_, Call[] memory calls) internal {
        string memory txs = "";
        for (uint256 i; i < calls.length; i++) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Callhouse: configure solo factory roles","description":"grantRole KEEPER_ROLE and GUARDIAN_ROLE on AccountFactory ',
            vm.toString(address(in_.factory)),
            '","createdFromSafeAddress":"',
            vm.toString(in_.safeAdmin),
            '"},"transactions":[',
            txs,
            "]}"
        );
        vm.createDir("broadcast", true);
        vm.writeFile(in_.batchOut, json);
        console2.log("safe batch written:", in_.batchOut);
    }

    function _executeAsKeyAdmin(AccountFactory f, uint256 pk, Call[] memory calls) internal {
        address admin = vm.addr(pk);
        require(f.hasRole(f.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE");
        if (calls.length == 0) return;
        vm.startBroadcast(pk);
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = calls[i].to.call(calls[i].data);
            require(ok, string.concat("admin call reverted: ", calls[i].what));
        }
        vm.stopBroadcast();
        console2.log("key admin executed", calls.length, "calls from", admin);
    }

    /// @dev Reads the state back and prints it; reverts if a grant did not land. Under `forge script` this
    ///      sees the simulation, so VerifySolo.s.sol against the chain is still the post-broadcast gate.
    function _postCheck(Inputs memory in_) internal view {
        AccountFactory f = in_.factory;
        bool keeperOk = f.hasRole(f.KEEPER_ROLE(), in_.keeper);
        bool guardianOk = f.hasRole(f.GUARDIAN_ROLE(), in_.guardian);
        console2.log("post-check");
        console2.log("  keeper   holds KEEPER_ROLE  ", keeperOk);
        console2.log("  guardian holds GUARDIAN_ROLE", guardianOk);
        console2.log("  depositCap                 ", f.depositCap());
        require(keeperOk && guardianOk, "post-check: a role grant did not land");
        if (in_.capSet) require(f.depositCap() == in_.depositCap, "post-check: depositCap not applied");
    }
}
