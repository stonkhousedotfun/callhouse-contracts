// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Vault} from "../../src/Vault.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {VerifyVault} from "../../script/Verify.s.sol";

/// @dev Runs Verify.s.sol's bytecode section against the test fixture's own deployment.
contract VerifyBytecodeHarness is VerifyVault {
    function bytecode(Vault vault, address sol, address vl) external returns (uint256, uint256) {
        _bytecode(vault, sol, vl);
        return (failures, passes);
    }
}

/// @notice Proves the shared fixture wires up and one clean cycle runs end to end.
contract SmokeTest is BaseTest {
    function test_fixtureWiring() public view {
        assertEq(vault.name(), "Callhouse NVDA");
        assertEq(vault.symbol(), "cNVDA");
        assertEq(vault.decimals(), 18);
        assertEq(address(vault.asset()), address(nvda));
        assertEq(address(vault.usdg()), address(usdg));
        assertEq(address(vault.clear()), address(clear));
        assertEq(vault.seaportZone(), address(vault), "the vault is its own Seaport zone");
        assertEq(vault.spotUsdg(), SPOT_USDG);
        assertEq(_phase(), 0);
        assertEq(vault.cycleNumber(), 0, "the vault numbers its own cycles, from zero");
    }

    function test_strikeLadderMatchesLiveMarket() public view {
        assertEq(optionIds.length, 5, "five rungs created on the clearinghouse");
        assertEq(clear.option(optionIds[0]).exerciseAmount, 226_000_000);
        assertEq(clear.option(optionIds[4]).exerciseAmount, 246_000_000);
        for (uint256 i; i < 5; i++) {
            assertEq(uint8(clear.tokenType(optionIds[i])), uint8(IValoremClear.TokenType.Option));
            assertEq(clear.option(optionIds[i]).exerciseTimestamp, exerciseTs);
            assertEq(clear.option(optionIds[i]).expiryTimestamp, expiryTs);
        }
    }

    function test_depositMintsOneSharePerToken() public {
        uint256 shares = _deposit(alice, 10e18);
        assertEq(shares, 10e18, "first deposit is 1:1");
        assertEq(vault.totalAssets(), 10e18);
        assertEq(vault.balanceOf(alice), 10e18);
    }

    /// @dev The whole product in one test: deposit, arm, list, fill (which writes), expire OTM,
    ///      close, claim the premium, then withdraw the collateral.
    function test_oneCleanCycle() public {
        _deposit(alice, 20e18);

        uint256 gross = _fullCycleOtm(10, _okUnitPrice());
        assertEq(gross, 19_000_000, "$1.90 x 10 contracts, ONE consideration item, all of it the vault's");

        // The protocol fee is 5% of the premium the vault harvested:
        // 19_000_000 * 500 / 10_000 = 950_000. An OTM week has no strike proceeds.
        assertEq(usdg.balanceOf(feeSafe), 950_000, "5% of the 19 USDG of premium");

        // The remainder is claimable by the depositor, not folded into the share price.
        assertEq(vault.claimableUsdg(alice), 18_050_000, "95% of 19 USDG");
        assertEq(vault.totalAssets(), 20e18, "collateral came back whole, OTM");

        vm.prank(alice);
        vault.claimUsdg();
        assertEq(usdg.balanceOf(alice), 18_050_000);

        // Back to Idle, so redemption is instant again.
        assertEq(_phase(), 0);
        assertTrue(vault.canRedeemInstantly());
        assertEq(vault.cycleNumber(), 1, "one cycle run");

        vm.prank(alice);
        vault.redeem(20e18, alice, alice);
        assertEq(nvda.balanceOf(alice), 30e18, "all collateral back");
    }

    /// @dev Regression: Verify.s.sol hard-coded 5 Vault link sites, so once the fixes added library
    ///      call sites a byte-perfect deployment FAILED the post-deploy gate. The expected count now
    ///      comes from the artifact, and the fixture's deployment (libraries read back from the
    ///      link sites themselves) passes every bytecode check.
    function test_verifyScript_acceptsAByteForByteDeployment() public {
        bytes memory code = address(vault).code;
        string memory json = vm.readFile("out/Vault.sol/Vault.json");
        uint256 vlOff =
            vm.parseJsonUint(json, ".deployedBytecode.linkReferences['src/lib/ValoremLib.sol'].ValoremLib[0].start");
        uint256 solOff = vm.parseJsonUint(
            json, ".deployedBytecode.linkReferences['src/lib/SeaportOrderLib.sol'].SeaportOrderLib[0].start"
        );
        address vl = address(bytes20(_slice20(code, vlOff)));
        address sol = address(bytes20(_slice20(code, solOff)));

        VerifyBytecodeHarness h = new VerifyBytecodeHarness();
        (uint256 failures, uint256 passes) = h.bytecode(vault, sol, vl);
        assertEq(failures, 0, "a correct deployment passes the bytecode section");
        assertEq(passes, 6, "link sites, vault runtime, and two checks per library");

        // Teeth: swapped library addresses still fail.
        (failures,) = new VerifyBytecodeHarness().bytecode(vault, vl, sol);
        assertGt(failures, 0, "swapped libraries fail");
    }

    /// @dev script/DeployClear.s.sol deploys from script/artifacts/; the tests deploy the real Clear
    ///      from test/fixtures/. The two must be the same bytes, or the script would deploy something
    ///      the suite never ran against.
    function test_deployClearArtifactIsTheTestFixture() public view {
        bytes memory a = bytes(vm.readFile("script/artifacts/ValoremOptionsClearinghouse.json"));
        bytes memory b = bytes(vm.readFile("test/fixtures/valorem/ValoremOptionsClearinghouse.json"));
        assertEq(keccak256(a), keccak256(b), "script artifact differs from the test fixture");
    }

    function _slice20(bytes memory b, uint256 off) internal pure returns (bytes20 w) {
        assembly {
            w := mload(add(add(b, 32), off))
        }
    }
}
