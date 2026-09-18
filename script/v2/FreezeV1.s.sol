// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AccountFactory} from "../../src/solo/AccountFactory.sol";
import {WriterAccount} from "../../src/solo/Account.sol";

/// @notice Freezes the v1 solo markets (ADR-10): on every AccountFactory passed in, the guardian halts writes
///         and the admin sets the deposit cap to zero; then the result is read back. docs/V1-RUNOFF.md is the
///         runbook around it, script/v2/freeze-v1.sh the registry-driven wrapper.
/// @dev WHAT THE TWO CALLS DO, read from src/solo/ (which v2 never edits):
///        - `setWritesHalted(true)`, GUARDIAN_ROLE. `WriterAccount.list()` and `WriterAccount.authorizeOrder` both
///          read `factory.writesHalted()` and revert `WritesAreHalted`, so no new lot is listed AND every lot
///          already validated on Seaport stops filling in the same block. Nothing else reads the flag: `settle`,
///          `withdraw`, `claimUsdg`, `requestWrite`, and a buyer exercising an option already sold on Valorem all
///          keep working.
///        - `setDepositCap(0)`, DEFAULT_ADMIN_ROLE. `deposit` reverts `DepositCapExceeded` when held + amount >
///          cap, so at zero every deposit of any size is refused. The halt alone would not do this, and the cap
///          alone would not stop an owner from calling `list()` on collateral already deposited.
///      The halts are built and sent first: they are what stops sales, the caps only stop new money.
///
///      MODES, per role, chosen by which key is in the environment (as ConfigureSolo.s.sol):
///        - GUARDIAN_PK set: the halts are broadcast from that key. ADMIN_PK set: the caps are. A key must hold
///          its role on every factory that still needs its call, or the run reverts before the first broadcast.
///        - a key not set: that role's calls go into its Safe{Wallet} Transaction Builder batch only.
///      Both batch files are written whenever they hold calls, key or not, so what a key sends and what a Safe
///      would sign are the same bytes. Nothing reaches a chain without `forge script ... --broadcast`.
///
///      IDEMPOTENT. A factory already halted gets no halt call ("already halted"), a cap already 0 no cap call
///      ("already 0"). A re-run after a partial broadcast, or after the Safe executed a batch, sends only what is
///      still missing, and a run with nothing missing sends nothing.
///
///      POST-CHECK. Runs when no call is left waiting on a Safe, so a key-less re-run after the Safe executed is
///      the check. Per factory: `writesHalted()` is true, `depositCap()` is 0, and `deposit(1)` on a probe account
///      reverts with exactly `WriterAccount.DepositCapExceeded` (before the freeze the same probe fails on the
///      token allowance instead, so the check cannot pass by accident). The probe account belongs to
///      {PROBE_OWNER}, has no key, and is created under `vm.prank` in the simulation when it does not exist;
///      nothing about it is ever broadcast. Under `forge script --broadcast` the post-check reads the local
///      simulation, not the chain: re-run without keys afterwards (freeze-v1.sh --broadcast does).
///
///      ENVIRONMENT
///        V1_FACTORIES        required. Comma-separated AccountFactory addresses. freeze-v1.sh reads them from
///                            the registry with jq (`deployment.factory != null`); Solidity never parses it.
///        GUARDIAN_PK         optional. Broadcast the halts from this key.
///        ADMIN_PK            optional. Broadcast the caps from this key.
///        SAFE_GUARDIAN       optional. The Safe named in the guardian batch; when set it must hold GUARDIAN_ROLE.
///        SAFE_ADMIN          optional. Likewise for the admin batch and DEFAULT_ADMIN_ROLE.
///        GUARDIAN_BATCH_OUT  default broadcast/freeze-v1-guardian-safe-batch.json
///        ADMIN_BATCH_OUT     default broadcast/freeze-v1-admin-safe-batch.json
///
///      `runWith(Inputs)` is the same procedure with explicit inputs; the tests drive it that way because
///      `vm.setEnv` writes the process environment every parallel test thread shares.
contract FreezeV1 is Script {
    /// @dev Owner of the post-check's probe account: an address nobody holds a key for, only ever used under
    ///      `vm.prank`. Fixed so a re-run on a local node reuses the same account.
    address public constant PROBE_OWNER = address(uint160(uint256(keccak256("callhouse.v1-freeze.probe-owner"))));

    struct Call {
        address to;
        bytes data;
        string what;
    }

    struct Inputs {
        AccountFactory[] factories;
        uint256 guardianPk;
        uint256 adminPk;
        address safeGuardian;
        address safeAdmin;
        string guardianBatchOut;
        string adminBatchOut;
    }

    function run() external returns (uint256 executed, uint256 skipped, uint256 batched, bool postChecked) {
        return runWith(_inputsFromEnv());
    }

    /// @return executed    calls broadcast from GUARDIAN_PK / ADMIN_PK
    /// @return skipped     calls not built because the factory already holds the frozen state
    /// @return batched     calls left to a Safe batch (built, not executed)
    /// @return postChecked the post-check ran and every check passed (it reverts otherwise)
    function runWith(Inputs memory in_)
        public
        returns (uint256 executed, uint256 skipped, uint256 batched, bool postChecked)
    {
        _checkFactories(in_.factories);
        (Call[] memory halts, uint256 skippedHalts) = _haltCalls(in_.factories);
        (Call[] memory caps, uint256 skippedCaps) = _capCalls(in_.factories);
        skipped = skippedHalts + skippedCaps;

        // Every refusal happens here, before the first broadcast: a key (or a named Safe) without its role on
        // any factory that still needs the call stops the whole run with nothing sent.
        if (in_.guardianPk != 0) _requireRole(halts, true, vm.addr(in_.guardianPk), "GUARDIAN_PK");
        else if (in_.safeGuardian != address(0)) _requireRole(halts, true, in_.safeGuardian, "SAFE_GUARDIAN");
        if (in_.adminPk != 0) _requireRole(caps, false, vm.addr(in_.adminPk), "ADMIN_PK");
        else if (in_.safeAdmin != address(0)) _requireRole(caps, false, in_.safeAdmin, "SAFE_ADMIN");

        if (halts.length != 0) {
            _writeSafeBatch(in_.guardianBatchOut, in_.safeGuardian, halts, "guardian");
        }
        if (caps.length != 0) _writeSafeBatch(in_.adminBatchOut, in_.safeAdmin, caps, "admin");
        if (halts.length == 0 && caps.length == 0) {
            console2.log("nothing to do: every factory is already halted with a zero deposit cap");
        }

        if (in_.guardianPk != 0) {
            _execute(in_.guardianPk, halts, "guardian");
            executed += halts.length;
        } else {
            batched += halts.length;
        }
        if (in_.adminPk != 0) {
            _execute(in_.adminPk, caps, "admin");
            executed += caps.length;
        } else {
            batched += caps.length;
        }

        if (batched != 0) {
            console2.log("");
            console2.log("PENDING:", batched, "call(s) left to Safe batches; nothing of theirs was broadcast.");
            console2.log("Import each batch into Safe{Wallet} Transaction Builder, decode every call");
            console2.log("(docs/V1-RUNOFF.md), sign, execute, then re-run this script without keys: it skips what");
            console2.log("landed and runs the post-check.");
            return (executed, skipped, batched, false);
        }

        _runOffReport(in_.factories);
        uint256 failures = postCheck(in_.factories);
        require(failures == 0, "post-check failed: a factory is not frozen");
        console2.log(
            string.concat(
                "post-check PASSED: ",
                vm.toString(in_.factories.length * 3),
                " checks on ",
                vm.toString(in_.factories.length),
                " factories"
            )
        );
        postChecked = true;
    }

    /// @notice Reads the frozen state back. Returns how many checks failed; prints one ok/FAIL line per check.
    /// @dev Not `view`: the deposit probe creates its account (under `vm.prank`) when it has none. Public so the
    ///      tests can show it fails on a factory that is not frozen.
    function postCheck(AccountFactory[] memory factories) public returns (uint256 failures) {
        console2.log("post-check");
        for (uint256 i; i < factories.length; i++) {
            AccountFactory f = factories[i];
            string memory at = string.concat(" (", vm.toString(address(f)), ")");
            failures += _check(f.writesHalted(), string.concat("writesHalted() == true", at));
            failures += _check(f.depositCap() == 0, string.concat("depositCap() == 0", at));
            failures += _check(
                _depositProbeHitsTheCap(f),
                string.concat("deposit(1) on a probe account reverts DepositCapExceeded", at)
            );
        }
    }

    function _inputsFromEnv() internal view returns (Inputs memory in_) {
        address[] memory addrs = vm.envAddress("V1_FACTORIES", ",");
        in_.factories = new AccountFactory[](addrs.length);
        for (uint256 i; i < addrs.length; i++) {
            in_.factories[i] = AccountFactory(addrs[i]);
        }
        in_.guardianPk = vm.envOr("GUARDIAN_PK", uint256(0));
        in_.adminPk = vm.envOr("ADMIN_PK", uint256(0));
        in_.safeGuardian = vm.envOr("SAFE_GUARDIAN", address(0));
        in_.safeAdmin = vm.envOr("SAFE_ADMIN", address(0));
        in_.guardianBatchOut = vm.envOr("GUARDIAN_BATCH_OUT", string("broadcast/freeze-v1-guardian-safe-batch.json"));
        in_.adminBatchOut = vm.envOr("ADMIN_BATCH_OUT", string("broadcast/freeze-v1-admin-safe-batch.json"));
    }

    /// @dev Each address must be a distinct AccountFactory: code, an `implementation()` whose `factory()` points
    ///      back. A typo or a v2 address in V1_FACTORIES fails here with its address, not as an opaque revert.
    function _checkFactories(AccountFactory[] memory factories) internal view {
        require(factories.length != 0, "V1_FACTORIES is empty");
        for (uint256 i; i < factories.length; i++) {
            address f = address(factories[i]);
            require(f.code.length != 0, string.concat("no code at ", vm.toString(f)));
            for (uint256 j; j < i; j++) {
                require(address(factories[j]) != f, string.concat("factory listed twice: ", vm.toString(f)));
            }
            bool isFactory;
            try factories[i].implementation() returns (WriterAccount impl) {
                isFactory = address(impl).code.length != 0 && address(impl.factory()) == f;
            } catch {}
            require(isFactory, string.concat("not an AccountFactory: ", vm.toString(f)));
        }
    }

    function _haltCalls(AccountFactory[] memory factories)
        internal
        view
        returns (Call[] memory calls, uint256 skipped)
    {
        Call[] memory buf = new Call[](factories.length);
        uint256 n;
        for (uint256 i; i < factories.length; i++) {
            AccountFactory f = factories[i];
            if (f.writesHalted()) {
                console2.log(
                    string.concat("  skip  setWritesHalted(true) on ", vm.toString(address(f)), ": already halted")
                );
                skipped++;
                continue;
            }
            buf[n++] = Call({
                to: address(f),
                data: abi.encodeCall(f.setWritesHalted, (true)),
                what: string.concat("setWritesHalted(true) on ", vm.toString(address(f)))
            });
        }
        calls = _trim(buf, n);
    }

    function _capCalls(AccountFactory[] memory factories) internal view returns (Call[] memory calls, uint256 skipped) {
        Call[] memory buf = new Call[](factories.length);
        uint256 n;
        for (uint256 i; i < factories.length; i++) {
            AccountFactory f = factories[i];
            if (f.depositCap() == 0) {
                console2.log(string.concat("  skip  setDepositCap(0) on ", vm.toString(address(f)), ": already 0"));
                skipped++;
                continue;
            }
            buf[n++] = Call({
                to: address(f),
                data: abi.encodeCall(f.setDepositCap, (0)),
                what: string.concat(
                    "setDepositCap(0) on ", vm.toString(address(f)), ", was ", vm.toString(f.depositCap())
                )
            });
        }
        calls = _trim(buf, n);
    }

    function _trim(Call[] memory buf, uint256 n) internal pure returns (Call[] memory calls) {
        calls = new Call[](n);
        for (uint256 i; i < n; i++) {
            calls[i] = buf[i];
        }
    }

    function _requireRole(Call[] memory calls, bool guardian, address who, string memory label) internal view {
        for (uint256 i; i < calls.length; i++) {
            AccountFactory f = AccountFactory(calls[i].to);
            bytes32 role = guardian ? f.GUARDIAN_ROLE() : f.DEFAULT_ADMIN_ROLE();
            require(
                f.hasRole(role, who),
                string.concat(
                    label,
                    " ",
                    vm.toString(who),
                    guardian ? " does not hold GUARDIAN_ROLE on " : " does not hold DEFAULT_ADMIN_ROLE on ",
                    vm.toString(address(f))
                )
            );
        }
    }

    /// @dev Safe{Wallet} Transaction Builder batch format (version 1.0), exactly as ConfigureSolo.s.sol writes it:
    ///      no `checksum` (the app warns, which is the honest state for a generated file, and why the runbook
    ///      decodes every call), zero-value calls, `createdFromSafeAddress` the named Safe or the zero address.
    function _writeSafeBatch(string memory path, address safe, Call[] memory calls, string memory role) internal {
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
            console2.log(string.concat("call ", vm.toString(i), " (", role, " batch): ", calls[i].what));
            console2.logBytes(calls[i].data);
        }
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Callhouse v1 freeze: ',
            role,
            keccak256(bytes(role)) == keccak256("guardian") ? " setWritesHalted(true)" : " setDepositCap(0)",
            '","description":"',
            vm.toString(calls.length),
            ' call(s), one per v1 AccountFactory not yet frozen","createdFromSafeAddress":"',
            vm.toString(safe),
            '"},"transactions":[',
            txs,
            "]}"
        );
        vm.createDir("broadcast", true);
        vm.writeFile(path, json);
        console2.log("safe batch written:", path);
    }

    function _execute(uint256 pk, Call[] memory calls, string memory role) internal {
        if (calls.length == 0) return;
        vm.startBroadcast(pk);
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = calls[i].to.call(calls[i].data);
            require(ok, string.concat(role, " call reverted: ", calls[i].what));
        }
        vm.stopBroadcast();
        console2.log(string.concat(role, " key executed"), calls.length, "call(s) from", vm.addr(pk));
    }

    /// @dev Information for the run-off, not a check: what is still listed and when the last of it can settle.
    ///      `settle()` opens at each account's own `listedExpiryTs` (the week's base expiry + the account index).
    function _runOffReport(AccountFactory[] memory factories) internal view {
        console2.log("run-off state at block timestamp", block.timestamp);
        for (uint256 i; i < factories.length; i++) {
            AccountFactory f = factories[i];
            (uint32 weekId,, uint40 exerciseTs, uint40 baseExpiryTs,) = f.week();
            uint256 live = f.liveCount();
            uint256 lastExpiry;
            for (uint256 k; k < live; k++) {
                uint40 e = WriterAccount(payable(f.liveAt(k))).listedExpiryTs();
                if (e > lastExpiry) lastExpiry = e;
            }
            console2.log("  factory     ", address(f));
            console2.log("    accounts  ", f.nextIndex());
            console2.log("    live      ", live);
            console2.log("    pending   ", f.pendingCount());
            console2.log("    week id   ", weekId);
            console2.log("    week exerciseTs / baseExpiryTs", exerciseTs, baseExpiryTs);
            if (live == 0) console2.log("    nothing listed: no settle() left to crank");
            else console2.log("    last live listedExpiryTs (every live account can settle from here)", lastExpiry);
        }
    }

    function _depositProbeHitsTheCap(AccountFactory f) internal returns (bool) {
        WriterAccount account = f.accountOf(PROBE_OWNER);
        if (address(account) == address(0)) {
            vm.prank(PROBE_OWNER);
            account = f.createAccount();
        }
        vm.prank(PROBE_OWNER);
        (bool ok, bytes memory ret) = address(account).call(abi.encodeCall(WriterAccount.deposit, (1)));
        // casting to 'bytes4' is safe because the length is checked to be exactly 4 first: a bare custom error
        // forge-lint: disable-next-line(unsafe-typecast)
        return !ok && ret.length == 4 && bytes4(ret) == WriterAccount.DepositCapExceeded.selector;
    }

    function _check(bool ok, string memory what) internal pure returns (uint256 failed) {
        console2.log(string.concat(ok ? "  ok    " : "  FAIL  ", what));
        return ok ? 0 : 1;
    }
}
