// SPDX-License-Identifier: MIT
//
// T-OP-098. Holds script/v2/day-zero-batch.mjs to the chain's own arithmetic and to the rehearsal's record.
//
//   CALLHOUSE_DIR=<a callhouse checkout on v8> node --test script/v2/day-zero-batch.test.mjs
//   DAY_ZERO_ABIS=<dir with ops/abis/v2/*.json>  node --test script/v2/day-zero-batch.test.mjs
//
// THE LOAD-BEARING PIN. docs/V8-LISTING-REHEARSAL.md run 3 (2026-09-22) scheduled NVDA's five admin calls from the
// impersonated Admin Safe through RegisterMarkets.s.sol on a fork and recorded the operation ids the manager
// returned. `hashOperation` is keccak256(abi.encode(caller, target, data)), so an opId equal to the recorded one
// proves the Safe address, the target, the selector, every argument and every mirrored constant (26 h, 2000 bps,
// 300 s) are byte-identical to what forge sent -- computed here with no forge, no node and no network. The five
// run-3 NVDA opIds are typed below FROM THAT DOC as the expected values; the sixteen run-3 addresses and the
// deployBlock likewise. They are FORK-ONLY values (a new run creates new ones) and appear in no registry.
//
// Everything else is refusals ("no operations" and "refused" never look alike), the tx-builder file shape and its
// checksum, the manifest cross-check (every call under the lane roles.v8.json maps it to), and the encoder against
// vectors `cast` produced in the same session (commands quoted next to each).

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  Abis,
  EXIT,
  REPO,
  RefusalError,
  Roles,
  SIGNABLE_STAGES,
  STAGES,
  abiEncode,
  assertFingerprintOnChain,
  batchChecksum,
  checkReceipt,
  checksumAddress,
  contractDefaults,
  contractKeysFromLib,
  encodeCall,
  hexToBytes,
  houseVaultSet,
  keccak256,
  fingerprintAddrs,
  keccakUtf8,
  parseArgs,
  plan,
  readAddresses,
  readReceipt,
  registryPathOf,
  render,
  vaultLabel,
  run,
  selectorOf,
  serializeForChecksum,
  signatureOf,
  v4PoolId,
} from "./day-zero-batch.mjs";

/* ------------------------------------------------------------------------------------------------ */
/*  fixtures                                                                                          */
/* ------------------------------------------------------------------------------------------------ */

const FIXTURE = join(REPO, "script", "v2", "fixtures", "registry-v8.json");
const ROLES = join(REPO, "script", "v2", "roles.v8.json");

function abiDir() {
  const c = [];
  if (process.env.DAY_ZERO_ABIS) c.push(process.env.DAY_ZERO_ABIS);
  if (process.env.CALLHOUSE_DIR) c.push(join(process.env.CALLHOUSE_DIR, "ops", "abis", "v2"));
  c.push(join(REPO, "..", "callhouse", "ops", "abis", "v2"), join(REPO, "..", "..", "callhouse", "ops", "abis", "v2"));
  const hit = c.find((d) => existsSync(join(d, "AccessManager.json")));
  // A missing ABI directory is a FAILURE, not a skip: a suite that skips its subject is the false green this repo hunts.
  assert.ok(hit, `no exported v2 ABIs found (tried ${c.join(", ")}); set CALLHOUSE_DIR to a callhouse checkout on v8 or DAY_ZERO_ABIS`);
  return hit;
}

// docs/V8-LISTING-REHEARSAL.md, "The 16 addresses, run 3 (deployBlock 69324879, fork-only)". Stand-ins for a
// written-back registry; NOT deployment truth.
const RUN3 = Object.freeze({
  deployBlock: 69324879,
  adminSafe: "0x6f8A7B77b72511cD8939596b1659bA28C28f101B", // the REAL Admin Safe run 3 impersonated (tier1.json shared.safes.admin)
  contracts: {
    accessManager: "0xA4f9885550548c6a45b9D18C57B114c06f3c39B8",
    clearinghouse: "0x67832b9Fc47eb3CdBF7275b95a29740EC58193D2",
    orderBook: "0x832092FDF1D32A3A1b196270590fB0E25DF129FF",
    settlementOracle: "0x63275D081C4A77AE69f76c4952F9747a5559a519",
    expiryCalendar: "0x449C286Ab90639fd9F6604F4f15Ec86bce2b8A61",
    keeperRewards: "0x5A61c51C6745b3F509f4a1BF54BFD04e04aF430a",
    autoRoller: "0xe3e4631D734e4b3F900AfcC396440641Ed0df339",
    payoutAdapter: "0x8729c0238b265BaCF6fE397E8309897BB5c40473",
    makerVault: "0x0Ff833129533546D96A5847C22b57AACccD00FD5",
    makerRegistry: "0xDf795df2e0ad240a82d773DA01a812B96345F9C5",
    rewardsDistributor: "0x26320DE63415e5AAf2BA617D97C39444eDb6F741",
  },
  sources: {
    chainlink: "0x5E0399B4C3c4C31036DcA08d53c0c5b5c29C113e",
    univ3: "0x512a0E8bAeb6Ac3D52A11780c92517627005b0b1",
    dataStreams: "0x5aA185fbEFc205072FaecC6B9D564383e761f8C2",
  },
  flywheel: { feeSplitter: "0x886a2A3ABF5B79AA5dFF1C73016BD07CFc817e04", buybackExecutor: "0x2ac430E52F47420A00984E11Ef0DDba80652419a" },
  // "Scheduled operation ids, run 3" -- NVDA's five, in RegisterMarkets.plan() order.
  nvdaOpIds: {
    "setFeed(address,address,uint32,uint16)": "0x210bda810a0d9d0df42c86a11e7e3a98d19e9a9b0a29a8fe8d1889e90847238b",
    "setPool(address,address,uint128,uint32)": "0xa59c99cf0d9dc8f0eb1aaa62ab6833fe5b759b885d0a6ddd891a9e514938194d",
    "setMarket(address,address[],uint16,uint32,uint32)": "0xe6742a7cdbd4d63ca938de48a125ab48df3531ef7b9d65663ec953baf141b5ed",
    "setRouteV4(address,uint24,int24)": "0xfbed524c9621cfe8ee03776c1093875a7bee4a5f79118b16e693c90469fd1cdf",
    "registerMarket(address,uint64,bool)": "0x1c35aa2ebfb944b5a78e04e258087470002fa2014e423a8e08248e27728782c9",
  },
  // run 3's SPCX registerMarket used tier1's strikeTick 1000000; the fixture's SPCX row says 2500000 and is
  // single-source, so THIS id must NOT come out of the fixture -- the negative control for the pin above.
  spcxRegisterOpIdFromTier1: "0xd61c5c5bc0a70b3926a9f825438cf6e9af82af269c1643e86b99417ae8983e53",
});

/** The fixture with run 3's addresses written back -- the shape DeployV2Batch.sh leaves behind. */
function writtenBack(mutate = () => {}) {
  const reg = JSON.parse(readFileSync(FIXTURE, "utf8"));
  Object.assign(reg.v2.contracts, RUN3.contracts);
  Object.assign(reg.v2.contracts.sources, RUN3.sources);
  Object.assign(reg.v2.flywheel, RUN3.flywheel);
  reg.v2.deployBlock = RUN3.deployBlock;
  reg.shared.safes.admin = RUN3.adminSafe;
  mutate(reg);
  return reg;
}

const ctx = (() => {
  let cached;
  return () => {
    if (!cached) {
      cached = {
        roles: new Roles(JSON.parse(readFileSync(ROLES, "utf8"))),
        abis: new Abis(abiDir()),
        defaults: contractDefaults(join(REPO, "src")),
      };
    }
    return cached;
  };
})();

const planFor = (reg, extra = {}) => plan({ registry: reg, markets: reg.launchSet.markets, protocolAccounts: ["makerVault", "feeSplitter"], ...ctx(), ...extra });
const refuses = (fn, re) => assert.throws(fn, (e) => e instanceof RefusalError && re.test(e.message), `expected a RefusalError matching ${re}`);

/* ------------------------------------------------------------------------------------------------ */
/*  keccak, selectors, ABI encoding -- against cast (1.3.5) output captured in the T-OP-098 session    */
/* ------------------------------------------------------------------------------------------------ */

describe("keccak-256 and selectors", () => {
  test("published vectors", () => {
    assert.equal(keccakUtf8(""), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
    assert.equal(keccakUtf8("abc"), "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"); // cast keccak abc
  });
  test("selectors the batch depends on (cast sig)", () => {
    assert.equal(selectorOf("transfer(address,uint256)"), "0xa9059cbb");
    assert.equal(selectorOf("setLimits((uint128,uint128,uint16,uint16,uint128))"), "0x60e6f8bf"); // roles.v8.json notes.targetSignatures pin
    assert.equal(selectorOf("schedule(address,bytes,uint48)"), "0xf801a698");
    assert.equal(selectorOf("setTargetFunctionRole(address,bytes4[],uint64)"), "0x08d6122d");
  });
  test("canonical signature expands tuples the way cast and the manifest write them", () => {
    const { abis } = ctx();
    const fn = abis.load("HouseVaultFactory").find((e) => e.type === "function" && e.name === "createVault");
    assert.equal(signatureOf(fn), "createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)");
  });
});

describe("ABI encoder", () => {
  test("dynamic array + static tail == cast calldata", () => {
    // cast calldata "setTargetFunctionRole(address,bytes4[],uint64)" 0x449C…8A61 "[0x60e6f8bf,0xa9059cbb]" 3
    const fn = { name: "setTargetFunctionRole", inputs: [{ name: "target", type: "address" }, { name: "selectors", type: "bytes4[]" }, { name: "roleId", type: "uint64" }] };
    assert.equal(
      encodeCall(fn, ["0x449C286Ab90639fd9F6604F4f15Ec86bce2b8A61", ["0x60e6f8bf", "0xa9059cbb"], 3n]),
      "0x08d6122d000000000000000000000000449c286ab90639fd9f6604f4f15ec86bce2b8a6100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000260e6f8bf00000000000000000000000000000000000000000000000000000000a9059cbb00000000000000000000000000000000000000000000000000000000",
    );
  });
  test("static tuple + two strings == cast calldata", () => {
    // cast calldata "createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)" 0xd060…9EEC "(10000,250000000000,100,1000,0,2500000000)" "Stonkhouse House NVDA" "hNVDA"
    const fn = {
      name: "createVault",
      inputs: [
        { name: "underlying", type: "address" },
        { name: "limits", type: "tuple", components: ["uint64", "uint128", "uint16", "uint16", "uint32", "uint128"].map((t, i) => ({ name: `f${i}`, type: t })) },
        { name: "name", type: "string" },
        { name: "symbol", type: "string" },
      ],
    };
    const got = encodeCall(fn, ["0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", [10000n, 250000000000n, 100n, 1000n, 0n, 2500000000n], "Stonkhouse House NVDA", "hNVDA"]);
    assert.equal(
      got,
      "0xe7c88a2a000000000000000000000000d0601ce157db5bdc3162bbac2a2c8af5320d9eec00000000000000000000000000000000000000000000000000000000000027100000000000000000000000000000000000000000000000000000003a35294400000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009502f90000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000001553746f6e6b686f75736520486f757365204e56444100000000000000000000000000000000000000000000000000000000000000000000000000000000000005684e564441000000000000000000000000000000000000000000000000000000",
    );
  });
  test("abi.encode(address,address,bytes) == cast abi-encode (the hashOperation preimage shape)", () => {
    assert.equal(
      abiEncode([{ type: "address" }, { type: "address" }, { type: "bytes" }], ["0x6f8A7B77b72511cD8939596b1659bA28C28f101B", "0x449C286Ab90639fd9F6604F4f15Ec86bce2b8A61", "0x08c379a0"]),
      "0x0000000000000000000000006f8a7b77b72511cd8939596b1659ba28c28f101b000000000000000000000000449c286ab90639fd9f6604f4f15ec86bce2b8a610000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000408c379a000000000000000000000000000000000000000000000000000000000",
    );
  });
  test("refuses a value that does not fit its type or an address that is not one", () => {
    const fn = { name: "f", inputs: [{ name: "x", type: "uint16" }] };
    refuses(() => encodeCall(fn, [70000n]), /does not fit uint16/);
    refuses(() => encodeCall({ name: "g", inputs: [{ name: "a", type: "address" }] }, ["0x1234"]), /is not an address/);
  });
  test("EIP-55", () => {
    assert.equal(checksumAddress("0x6f8a7b77b72511cd8939596b1659ba28c28f101b"), "0x6f8A7B77b72511cD8939596b1659bA28C28f101B");
  });
});

/* ------------------------------------------------------------------------------------------------ */
/*  mirrored constants and the v4 pool id                                                             */
/* ------------------------------------------------------------------------------------------------ */

describe("mirrors", () => {
  test("contract defaults are read from src/, not typed: 26 h, 2000 bps, 300 s", () => {
    const d = contractDefaults(join(REPO, "src"));
    assert.equal(d.maxStale, 93600n);
    assert.equal(d.maxRoundJumpBps, 2000n);
    assert.equal(d.twapWindow, 300n);
  });
  test("v4 pool id rebuilds to the registry's pins for both launch markets (fee, tickSpacing, hookless, sorted currencies)", () => {
    const reg = JSON.parse(readFileSync(FIXTURE, "utf8"));
    const nvda = reg.markets.find((m) => m.ticker === "NVDA");
    assert.equal(v4PoolId(nvda.asset, reg.shared.usdg, BigInt(nvda.v2.payoutRoute.fee), BigInt(nvda.v2.payoutRoute.tickSpacing)), nvda.v2.payoutRoute.poolId);
    // SPCX's pin lives in callhouse tier1.json (fee 10000, tickSpacing 200); quoted from docs/V8-LISTING-REHEARSAL.md run 2A.
    assert.equal(v4PoolId("0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa", reg.shared.usdg, 10000n, 200n), "0xcb6ffbcc84359535c2cc0a5688c0a76520ea6e0a4820fddd3ac8d7880e576370");
    // positive control: a different fee is a different pool
    assert.notEqual(v4PoolId(nvda.asset, reg.shared.usdg, 500n, 4n), nvda.v2.payoutRoute.poolId);
  });
});

/* ------------------------------------------------------------------------------------------------ */
/*  refusals                                                                                          */
/* ------------------------------------------------------------------------------------------------ */

describe("refusals", () => {
  test("a registry with a null core address does not describe a broadcast", () => {
    refuses(() => readAddresses(writtenBack((r) => { r.v2.contracts.orderBook = null; })), /v2\.contracts\.orderBook is null/);
    refuses(() => readAddresses(writtenBack((r) => { r.v2.contracts.sources.univ3 = null; })), /sources\.univ3 is null/);
    refuses(() => readAddresses(writtenBack((r) => { r.v2.flywheel.feeSplitter = null; })), /flywheel\.feeSplitter is null/);
    refuses(() => readAddresses(JSON.parse(readFileSync(FIXTURE, "utf8"))), /accessManager is null/); // the fixture as shipped: nothing deployed
  });
  test("a null deployBlock is refused even with every address present", () => {
    refuses(() => readAddresses(writtenBack((r) => { r.v2.deployBlock = null; })), /deployBlock is null/);
    refuses(() => readAddresses(writtenBack((r) => { r.v2.deployBlock = 0; })), /deployBlock is 0/);
  });
  test("a null Admin Safe is refused: nobody could sign", () => {
    refuses(() => readAddresses(writtenBack((r) => { r.shared.safes.admin = null; })), /shared\.safes\.admin is null/);
  });
  test("an external key that is neither null nor an address is refused, a null one is simply absent", () => {
    refuses(() => readAddresses(writtenBack((r) => { r.v2.contracts.houseVault = "0xnope"; })), /houseVault is "0xnope"/);
    assert.deepEqual(readAddresses(writtenBack((r) => { r.v2.contracts.houseVault = null; })).externals, {});
  });
  test("a launch market that is missing, or has a null feed / asset / strikeTick, is refused by name", () => {
    refuses(() => planFor(writtenBack(), { markets: ["ZZZZ"] }), /ZZZZ is not in markets\[\]/);
    refuses(() => planFor(writtenBack((r) => { r.markets.find((m) => m.ticker === "NVDA").feed = null; })), /NVDA: feed null/);
    refuses(() => planFor(writtenBack((r) => { r.markets.find((m) => m.ticker === "NVDA").v2.strikeTick = null; })), /NVDA\.v2\.strikeTick/);
  });
  test("a v4 route whose (fee, tickSpacing) does not rebuild to the pinned pool id is refused -- the silent-misroute guard", () => {
    refuses(() => planFor(writtenBack((r) => { r.markets.find((m) => m.ticker === "NVDA").v2.payoutRoute.fee = 500; })), /rebuilds to pool id 0x[0-9a-f]{64}, the registry pins 0xdf5c0bcd/);
  });
  test("a pool without a liquidity floor is refused (UniV3TwapSource.setPool refuses floor 0, T-OP-062)", () => {
    refuses(() => planFor(writtenBack((r) => { r.markets.find((m) => m.ticker === "NVDA").v2.univ3MinLiquidity = null; })), /NVDA: a pool without v2\.univ3MinLiquidity/);
  });
  test("a call the manifest does not map, or maps to another lane, is refused (AC-3)", () => {
    const rolesJson = JSON.parse(readFileSync(ROLES, "utf8"));
    const missing = JSON.parse(JSON.stringify(rolesJson));
    delete missing.targets.Clearinghouse["registerMarket(address,uint64,bool)"];
    refuses(() => planFor(writtenBack(), { roles: new Roles(missing) }), /does not map Clearinghouse\.registerMarket\(address,uint64,bool\)/);
    const moved = JSON.parse(JSON.stringify(rolesJson));
    moved.targets.Clearinghouse["registerMarket(address,uint64,bool)"] = "CONFIG_ADMIN";
    refuses(() => planFor(writtenBack(), { roles: new Roles(moved) }), /registerMarket\(address,uint64,bool\) is CONFIG_ADMIN in roles\.v8\.json but the list stage signs under LISTING/);
  });
  test("--create-vault needs a factory and no vault; the CLI refuses an unknown flag and a missing --registry", () => {
    refuses(() => planFor(writtenBack(), { createVault: "NVDA" }), /houseVaultFactory is null/);
    refuses(() => planFor(writtenBack((r) => { r.v2.contracts.houseVaultFactory = RUN3.flywheel.buybackExecutor; r.v2.contracts.houseVault = RUN3.contracts.makerVault; }), { createVault: "NVDA" }), /already records a vault for NVDA \(v2\.contracts\.houseVault/);
    refuses(() => parseArgs(["--bogus"]), /unknown flag --bogus/);
    refuses(() => parseArgs(["--registry"]), /--registry needs a value/);
    assert.equal(EXIT.REFUSED, 2);
  });
});

/* ------------------------------------------------------------------------------------------------ */
/*  the plan                                                                                          */
/* ------------------------------------------------------------------------------------------------ */

describe("plan", () => {
  test("NVDA's five operation ids equal the ids RegisterMarkets scheduled from the Safe in rehearsal run 3", () => {
    const p = planFor(writtenBack());
    const nvda = "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC";
    const ops = p.ops.filter((o) => o.args[0] === nvda && o.signature in RUN3.nvdaOpIds);
    assert.equal(ops.length, 5, "five NVDA calls: setFeed, setPool, setMarket, setRouteV4, registerMarket");
    for (const op of ops) assert.equal(op.opId, RUN3.nvdaOpIds[op.signature], `${op.label}: opId differs from the run-3 record`);
    // in RegisterMarkets.plan() order
    assert.deepEqual(ops.map((o) => o.signature), Object.keys(RUN3.nvdaOpIds));
  });
  test("the pin is not vacuous: the fixture's SPCX (strikeTick 2500000, single-source) does NOT reproduce run 3's tier1 SPCX id", () => {
    const p = planFor(writtenBack());
    const spcxRegister = p.ops.find((o) => o.signature === "registerMarket(address,uint64,bool)" && o.args[0] === "0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa");
    assert.ok(spcxRegister);
    assert.notEqual(spcxRegister.opId, RUN3.spcxRegisterOpIdFromTier1);
  });
  test("a Chainlink-only market gets no setPool, one source, and the SINGLE-SOURCE warning; a routed one gets the route", () => {
    const p = planFor(writtenBack());
    const spcx = p.ops.filter((o) => o.args[0] === "0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa");
    assert.deepEqual(spcx.map((o) => o.signature), [
      "setFeed(address,address,uint32,uint16)",
      "setMarket(address,address[],uint16,uint32,uint32)",
      "registerMarket(address,uint64,bool)",
      "setMarketListing(address,bool,uint64)",
    ]);
    const setMarket = spcx[1];
    assert.deepEqual(setMarket.args[1], [RUN3.sources.chainlink]);
    assert.equal(setMarket.args[3], 3600n, "v2.overrides.uncorroboratedDelayS wins over v2.defaults");
    assert.match(setMarket.note, /SINGLE-SOURCE/);
    const nvdaRoute = p.ops.find((o) => o.signature === "setRouteV4(address,uint24,int24)");
    assert.deepEqual(nvdaRoute.args, ["0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", 375n, 4n]);
  });
  test("every operation sits under the lane roles.v8.json maps it to, with that lane's delay and role id", () => {
    const p = planFor(writtenBack((r) => { r.v2.contracts.houseVault = RUN3.contracts.makerRegistry; r.v2.contracts.earnVault = RUN3.contracts.autoRoller; }));
    const { roles } = ctx();
    // 5 NVDA + 3 SPCX (fixture: unrouted, single-source) + 2 go-live + map(HouseVault roles + EarnVault roles) + 2 arm
    assert.equal(p.ops.length, 10 + roles.groupsFor("HouseVault").size + roles.groupsFor("EarnVault").size + 2);
    for (const op of p.ops) {
      const lane = op.target.contract === "AccessManager" ? "ADMIN" : roles.laneOf(op.target.contract, op.signature);
      assert.equal(op.lane, lane, op.label);
      assert.equal(op.delayS, roles.delayS(lane), op.label);
      assert.equal(op.roleId, roles.id(lane), op.label);
      assert.equal(STAGES.find((s) => s.id === op.stage).lane, lane, `${op.label}: stage lane`);
      assert.equal(op.data.slice(0, 10), selectorOf(op.signature));
    }
  });
  test("launch markets with rent 0 need no setMarketFees; a market rent puts one call in MARKET_FEE_MANAGER (72 h)", () => {
    assert.equal(planFor(writtenBack()).ops.filter((o) => o.stage === "fees").length, 0);
    const p = planFor(writtenBack((r) => { r.markets.find((m) => m.ticker === "NVDA").v2.mintFeePpm = 10; }));
    const fees = p.ops.filter((o) => o.stage === "fees");
    assert.equal(fees.length, 1);
    assert.equal(fees[0].lane, "MARKET_FEE_MANAGER");
    assert.equal(fees[0].delayS, 259200);
    assert.deepEqual(fees[0].args, ["0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", 25n, 10n]);
  });
  test("externals present: one setTargetFunctionRole per (target, role) with the manifest's selectors, ADMIN lane", () => {
    const vault = RUN3.contracts.makerRegistry; // any address with the right shape; fork-only stand-in
    const p = planFor(writtenBack((r) => { r.v2.contracts.houseVault = vault; }));
    const { roles } = ctx();
    const map = p.ops.filter((o) => o.stage === "map");
    const groups = roles.groupsFor("HouseVault");
    assert.equal(map.length, groups.size);
    for (const op of map) {
      assert.equal(op.lane, "ADMIN");
      assert.equal(op.delayS, 172800);
      assert.equal(op.args[0], vault);
      const role = Object.entries(roles.json.roles).find(([, id]) => id === op.args[2])[0];
      assert.deepEqual(op.args[1], groups.get(role).map((s) => s.selector), role);
      assert.equal(op.cancelBy, "the Safe only (ADMIN has no guardian)");
    }
    // the mapping carries setOracle -> CONFIG_ADMIN (T-OP-058), the reason the row names it
    const cfg = map.find((o) => o.args[2] === roles.id("CONFIG_ADMIN"));
    assert.ok(cfg.args[1].includes(selectorOf("setOracle(address)")));
    assert.ok(cfg.args[1].includes(selectorOf("setProtocolAccount(address,bool)")));
  });
  test("arming: setProtocolAccount(x, true) per protocol account, after MAP; the vault itself and an unknown key are refused", () => {
    const vault = RUN3.contracts.makerRegistry;
    const p = planFor(writtenBack((r) => { r.v2.contracts.houseVault = vault; }), { protocolAccounts: ["makerVault", "feeSplitter"] });
    const arm = p.ops.filter((o) => o.stage === "arm");
    assert.deepEqual(arm.map((o) => o.args), [[RUN3.contracts.makerVault, true], [RUN3.flywheel.feeSplitter, true]]);
    assert.equal(arm[0].lane, "CONFIG_ADMIN");
    assert.match(arm[0].note, /ARMS take/);
    assert.deepEqual(STAGES.find((s) => s.id === "arm").after, ["map"]);
    refuses(() => planFor(writtenBack((r) => { r.v2.contracts.houseVault = vault; }), { protocolAccounts: ["nothing"] }), /names nothing, which the registry does not record/);
    refuses(() => planFor(writtenBack((r) => { r.v2.contracts.houseVault = vault; }), { protocolAccounts: ["houseVault"] }), /names a vault itself \(houseVault = houseVault\)/);
    // no vault, no arming -- and no refusal: the stage is simply absent
    assert.equal(planFor(writtenBack()).ops.filter((o) => o.stage === "arm").length, 0);
  });
  test("createVault: LISTING, in its own stage after MAP, limits from v2.vault, name/symbol from the ticker", () => {
    const factory = RUN3.contracts.makerRegistry;
    const p = planFor(writtenBack((r) => { r.v2.contracts.houseVaultFactory = factory; }), { createVault: "SPCX" });
    const cv = p.ops.filter((o) => o.stage === "vault");
    assert.equal(cv.length, 1);
    assert.equal(cv[0].lane, "LISTING");
    assert.equal(cv[0].target.address, factory);
    assert.deepEqual(cv[0].args, ["0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa", [10000n, 250000000000n, 100n, 1000n, 0n, 2500000000n], "Stonkhouse House SPCX", "hSPCX"]);
    assert.deepEqual(STAGES.find((s) => s.id === "vault").after, ["map"]);
    // the factory's own mapping is in MAP (one role: LISTING)
    const map = p.ops.filter((o) => o.stage === "map");
    assert.equal(map.length, 1);
    assert.equal(map[0].args[2], ctx().roles.id("LISTING"));
  });
  test("--skip-mapping drops a target's MAP calls (it was supplied to DeployV8 before the renounce)", () => {
    const p = planFor(writtenBack((r) => { r.v2.contracts.houseVaultFactory = RUN3.contracts.makerRegistry; }), { skipMapping: ["houseVaultFactory"] });
    assert.equal(p.ops.filter((o) => o.stage === "map").length, 0);
  });
});

/* ------------------------------------------------------------------------------------------------ */
/*  the house vault SET (T-OP-172): two at launch, per-ticker in the registry, pairwise protocol accounts */
/* ------------------------------------------------------------------------------------------------ */

describe("house vault set (T-OP-172)", () => {
  // Two fork-only stand-ins with the right shape; NVDA's is ALSO recorded under v2.contracts.houseVault (option A).
  const NVDA_VAULT = RUN3.contracts.makerRegistry;
  const SPCX_VAULT = RUN3.contracts.autoRoller;
  const twoVaults = (mutate = () => {}) => writtenBack((r) => {
    r.v2.contracts.houseVault = NVDA_VAULT;
    r.markets.find((m) => m.ticker === "NVDA").v2.houseVault = NVDA_VAULT;
    r.markets.find((m) => m.ticker === "SPCX").v2.houseVault = SPCX_VAULT;
    mutate(r);
  });

  test("the set is derived from the registry: dedup(contracts.houseVault, markets[].v2.houseVault) in launchSet order, tickers named", () => {
    const { vaults, skippedVaults } = houseVaultSet(twoVaults(), NVDA_VAULT);
    assert.deepEqual(vaults, [{ ticker: "NVDA", address: NVDA_VAULT }, { ticker: "SPCX", address: SPCX_VAULT }]);
    assert.deepEqual(skippedVaults, []);
    // order is launchSet's, not markets[]'s: reverse the launch set and the vaults follow it
    const rev = twoVaults((r) => { r.launchSet.markets = ["SPCX", "NVDA"]; });
    assert.deepEqual(houseVaultSet(rev, NVDA_VAULT).vaults.map((v) => v.ticker), ["SPCX", "NVDA"]);
    // the old shape (contracts.houseVault only, no per-ticker twin) is one unnamed vault
    assert.deepEqual(houseVaultSet(writtenBack((r) => { r.v2.contracts.houseVault = NVDA_VAULT; }), NVDA_VAULT).vaults, [{ ticker: null, address: NVDA_VAULT }]);
    assert.equal(vaultLabel({ ticker: null, address: NVDA_VAULT }), "houseVault");
    assert.equal(vaultLabel({ ticker: "NVDA", address: NVDA_VAULT }), "houseVault[NVDA]");
    // a per-ticker value that is not an address is refused, not skipped
    refuses(() => houseVaultSet(twoVaults((r) => { r.markets.find((m) => m.ticker === "SPCX").v2.houseVault = "0xnope"; }), NVDA_VAULT), /markets\[SPCX\]\.v2\.houseVault is "0xnope"/);
  });

  test("two vaults: both mapped (ticker in every label), both armed, and each is a protocol account of the other (n*(n-1) = 2)", () => {
    const p = planFor(twoVaults());
    const { roles } = ctx();
    const groups = roles.groupsFor("HouseVault");
    const map = p.ops.filter((o) => o.stage === "map");
    assert.equal(map.length, 2 * groups.size, "one map group per vault");
    for (const [ticker, addr] of [["NVDA", NVDA_VAULT], ["SPCX", SPCX_VAULT]]) {
      const mine = map.filter((o) => o.args[0] === addr);
      assert.equal(mine.length, groups.size, `${ticker}: every role group`);
      for (const op of mine) {
        assert.match(op.label, new RegExp(`houseVault\\[${ticker}\\]`), op.label);
        assert.equal(op.target.ticker, ticker);
      }
    }
    const arm = p.ops.filter((o) => o.stage === "arm");
    // per vault: makerVault, feeSplitter, then the OTHER vault
    assert.deepEqual(arm.map((o) => [o.target.address, o.args[0]]), [
      [NVDA_VAULT, RUN3.contracts.makerVault], [NVDA_VAULT, RUN3.flywheel.feeSplitter], [NVDA_VAULT, SPCX_VAULT],
      [SPCX_VAULT, RUN3.contracts.makerVault], [SPCX_VAULT, RUN3.flywheel.feeSplitter], [SPCX_VAULT, NVDA_VAULT],
    ]);
    const pairwise = arm.filter((o) => [NVDA_VAULT, SPCX_VAULT].includes(o.args[0]));
    assert.equal(pairwise.length, 2, "n*(n-1) for n = 2");
    assert.equal(pairwise[0].label, "houseVault[NVDA].setProtocolAccount(houseVault[SPCX], blocked=true)");
    assert.equal(pairwise[1].label, "houseVault[SPCX].setProtocolAccount(houseVault[NVDA], blocked=true)");
    for (const op of pairwise) assert.match(op.note, /each vault a protocol account of the other/);
    // the first blocked=true call per vault is the one that arms take, and it is not the pairwise one
    assert.match(arm[0].note, /ARMS take/); assert.match(arm[3].note, /ARMS take/);
    assert.doesNotMatch(pairwise[0].note, /ARMS take/);
    for (const op of arm) assert.equal(op.lane, "CONFIG_ADMIN");
    assert.deepEqual(p.vaults.map((v) => v.ticker), ["NVDA", "SPCX"]);
    assert.match(p.notes.join("\n"), /2 house vaults \(houseVault\[NVDA\], houseVault\[SPCX\]\): 2 pairwise/);
  });

  test("opIds reproduce offline (the 098 method): keccak256(abi.encode(safe, target, data)) for every vault op", () => {
    const p = planFor(twoVaults());
    const vaultOps = p.ops.filter((o) => o.stage === "arm" || (o.stage === "map" && [NVDA_VAULT, SPCX_VAULT].includes(o.args[0])));
    assert.ok(vaultOps.length >= 8);
    const seen = new Set();
    for (const op of vaultOps) {
      const again = keccak256(hexToBytes(abiEncode(
        [{ type: "address" }, { type: "address" }, { type: "bytes" }],
        [p.safe, op.target.address, op.data],
      )));
      assert.equal(op.opId, again, op.label);
      assert.ok(!seen.has(op.opId), `${op.label}: opId collides with another op`);
      seen.add(op.opId);
    }
    // the two pairwise calls encode the other vault, and nothing else, in their data
    const pair = vaultOps.filter((o) => o.signature === "setProtocolAccount(address,bool)" && [NVDA_VAULT, SPCX_VAULT].includes(o.args[0]));
    assert.equal(pair[0].data, encodeCall(ctx().abis.fn("HouseVault", "setProtocolAccount(address,bool)"), [SPCX_VAULT, true]));
    assert.equal(pair[1].data, encodeCall(ctx().abis.fn("HouseVault", "setProtocolAccount(address,bool)"), [NVDA_VAULT, true]));
  });

  test("one null per-ticker vault: skipped BY NAME -- one vault mapped and armed, no pairwise call, and the batch says so", () => {
    const p = planFor(twoVaults((r) => { r.markets.find((m) => m.ticker === "SPCX").v2.houseVault = null; }));
    assert.deepEqual(p.vaults, [{ ticker: "NVDA", address: NVDA_VAULT }]);
    assert.deepEqual(p.skippedVaults, ["SPCX"]);
    assert.equal(p.ops.filter((o) => o.stage === "map" && o.args[0] === NVDA_VAULT).length, ctx().roles.groupsFor("HouseVault").size);
    const arm = p.ops.filter((o) => o.stage === "arm");
    assert.deepEqual(arm.map((o) => o.args[0]), [RUN3.contracts.makerVault, RUN3.flywheel.feeSplitter], "no pairwise call with one vault");
    assert.match(p.notes.join("\n"), /houseVault\[SPCX\]: markets\[SPCX\]\.v2\.houseVault is null -- not mapped, not armed/);
    const files = render(p, { abis: ctx().abis, createdAt: 1790052000000, out: null });
    assert.match(files["PLAN.md"], /House vaults \(1\): `houseVault\[NVDA\]`/);
    assert.match(files["PLAN.md"], /NOTE: houseVault\[SPCX\]: markets\[SPCX\]\.v2\.houseVault is null/);
    assert.deepEqual(files["plan.json"].houseVaults, [{ ticker: "NVDA", address: NVDA_VAULT }]);
    assert.deepEqual(files["plan.json"].skippedVaults, ["SPCX"]);
    // an absent key is the same as null (the pre-T-OP-156 registry shape)
    const absent = planFor(twoVaults((r) => { delete r.markets.find((m) => m.ticker === "SPCX").v2.houseVault; }));
    assert.deepEqual(absent.skippedVaults, ["SPCX"]);
  });

  test("--create-vault: another market's vault is not a reason to refuse; the same market's is", () => {
    const factory = RUN3.contracts.makerVault;
    // NVDA has a vault (option A: contracts.houseVault + per-ticker), SPCX does not: creating SPCX's is allowed
    const p = planFor(twoVaults((r) => { r.v2.contracts.houseVaultFactory = factory; r.markets.find((m) => m.ticker === "SPCX").v2.houseVault = null; }), { createVault: "SPCX" });
    const cv = p.ops.filter((o) => o.stage === "vault");
    assert.equal(cv.length, 1);
    assert.equal(cv[0].target.ticker, "SPCX");
    assert.match(cv[0].note, /record its address \(VaultCreated\) under markets\[SPCX\]\.v2\.houseVault/);
    // ...and NVDA's, which exists, is refused by name
    refuses(() => planFor(twoVaults((r) => { r.v2.contracts.houseVaultFactory = factory; }), { createVault: "NVDA" }), /already records a vault for NVDA \(markets\[NVDA\]\.v2\.houseVault = /);
    // the old shape: an unlabelled contracts.houseVault counts as the FIRST launch market's (NVDA)
    refuses(() => planFor(writtenBack((r) => { r.v2.contracts.houseVaultFactory = factory; r.v2.contracts.houseVault = NVDA_VAULT; }), { createVault: "NVDA" }), /already records a vault for NVDA \(v2\.contracts\.houseVault = /);
    const old = planFor(writtenBack((r) => { r.v2.contracts.houseVaultFactory = factory; r.v2.contracts.houseVault = NVDA_VAULT; }), { createVault: "SPCX" });
    assert.equal(old.ops.filter((o) => o.stage === "vault").length, 1, "SPCX's vault can be created beside the old-shape NVDA vault");
  });

  test("--protocol-accounts naming any vault of the set is refused; nothing hard-codes two (three vaults -> six pairwise calls)", () => {
    refuses(() => planFor(twoVaults(), { protocolAccounts: ["houseVault"] }), /names a vault itself \(houseVault = houseVault\[NVDA\]\)/);
    const three = twoVaults((r) => {
      r.launchSet.markets = ["NVDA", "SPCX", "SPY"];
      r.markets.find((m) => m.ticker === "SPY").v2.houseVault = RUN3.contracts.keeperRewards;
    });
    const p = planFor(three, { markets: ["NVDA", "SPCX"] });
    const vaults = [NVDA_VAULT, SPCX_VAULT, RUN3.contracts.keeperRewards];
    const pairwise = p.ops.filter((o) => o.stage === "arm" && vaults.includes(o.args[0]));
    assert.equal(pairwise.length, 6, "n*(n-1) for n = 3");
    assert.equal(p.ops.filter((o) => o.stage === "map" && vaults.includes(o.args[0])).length, 3 * ctx().roles.groupsFor("HouseVault").size);
  });
});

/* ------------------------------------------------------------------------------------------------ */
/*  Safe Transaction Builder files                                                                    */
/* ------------------------------------------------------------------------------------------------ */

describe("tx-builder output", () => {
  const files = () => render(planFor(writtenBack()), { abis: ctx().abis, createdAt: 1790052000000, out: null });

  test("one schedule + one execute file per non-empty stage, numbered in stage order, plus plan.json and PLAN.md", () => {
    const f = files();
    assert.deepEqual(Object.keys(f).sort(), [
      "01-config-execute.json", "01-config-schedule.json", "02-list-execute.json", "02-list-schedule.json",
      "03-golive-execute.json", "03-golive-schedule.json", "PLAN.md", "plan.json",
    ]);
    assert.equal(f["plan.json"].operations.length, 10, "5 NVDA + 3 SPCX (fixture SPCX: no pool, no route) + 2 go-live");
  });
  test("schedule file: every tx is AccessManager.schedule(target, data, 0) from the Safe, carrying the op's calldata", () => {
    const f = files();
    const sched = f["01-config-schedule.json"];
    const ops = f["plan.json"].operations.filter((o) => o.stage === "config");
    assert.equal(sched.version, "1.0");
    assert.equal(sched.chainId, "4663");
    assert.equal(sched.meta.createdFromSafeAddress, RUN3.adminSafe);
    assert.equal(sched.transactions.length, ops.length);
    sched.transactions.forEach((tx, i) => {
      assert.equal(tx.to, RUN3.contracts.accessManager);
      assert.equal(tx.value, "0");
      assert.equal(tx.data.slice(0, 10), "0xf801a698");
      assert.equal(tx.contractMethod.name, "schedule");
      assert.equal(tx.contractInputsValues.target, ops[i].target.address);
      assert.equal(tx.contractInputsValues.data, ops[i].data);
      assert.equal(tx.contractInputsValues.when, "0");
      // the calldata's `data` argument IS the op's calldata (dynamic bytes at offset 0x60, length then bytes)
      assert.ok(tx.data.includes(ops[i].data.slice(2)), "schedule calldata embeds the target calldata");
    });
  });
  test("execute file: every tx is the TARGET called directly with the op's calldata (never manager.execute)", () => {
    const f = files();
    const exec = f["02-list-execute.json"];
    const ops = f["plan.json"].operations.filter((o) => o.stage === "list");
    assert.equal(exec.transactions.length, 2);
    exec.transactions.forEach((tx, i) => {
      assert.equal(tx.to, ops[i].target.address);
      assert.equal(tx.data, ops[i].data);
      assert.equal(tx.contractMethod.name, "registerMarket");
      assert.deepEqual(Object.keys(tx.contractInputsValues), ["underlying", "strikeTick", "enabled"]);
      assert.equal(tx.contractInputsValues.enabled, "false");
    });
  });
  test("checksum follows the tx-builder's serializer (sorted keys, meta.name nulled, checksum absent) and moves when a tx moves", () => {
    const f = files();
    const b = f["03-golive-schedule.json"];
    // independent re-derivation of the reference algorithm on this batch
    const strip = { ...b, meta: { ...b.meta, name: null } };
    delete strip.meta.checksum;
    assert.equal(b.meta.checksum, keccakUtf8(serializeForChecksum(strip)));
    assert.equal(batchChecksum(b), b.meta.checksum);
    // positive control: a changed `to` changes the checksum; a changed meta.name does not (the app nulls it)
    const moved = JSON.parse(JSON.stringify(b));
    moved.transactions[0].to = RUN3.contracts.orderBook;
    assert.notEqual(batchChecksum(moved), b.meta.checksum);
    const renamed = JSON.parse(JSON.stringify(b));
    renamed.meta.name = "something else";
    assert.equal(batchChecksum(renamed), b.meta.checksum);
    // serializer vector: sorted keys, undefined -> null
    assert.equal(serializeForChecksum({ b: 1, a: [true, null], c: { z: "x" } }), '{["a","b","c"][true,null],1,{["z"]"x",},}');
  });
  test("PLAN.md names the stage gates and the run-3 opIds; plan.json carries decimal strings, never BigInt", () => {
    const f = files();
    assert.match(f["PLAN.md"], /## 03 golive .*\n\nLane \*\*LISTING\*\*.*schedule only after the execute of \*\*config, list\*\*/);
    assert.match(f["PLAN.md"], new RegExp(RUN3.nvdaOpIds["registerMarket(address,uint64,bool)"]));
    assert.doesNotThrow(() => JSON.stringify(f["plan.json"]));
    assert.equal(f["plan.json"].defaults.maxStale, "93600");
  });
});

/* ------------------------------------------------------------------------------------------------ */
/*  the verify receipt (T-OP-163): the batch is never built for a deployment VerifyV8 did not pass    */
/* ------------------------------------------------------------------------------------------------ */

// A stub forge in place of BroadcastV8.assertFingerprint. It records what it was HANDED (env, argv), so the tests
// assert the generator drives the driver's own script with the driver's own inputs, and it answers the way the real
// one does: MATCHES on the expected fingerprint, EXPECTED/ACTUAL + revert on any other.
function stubForge(chainFingerprint) {
  const calls = [];
  const exec = (cmd, args, opts) => {
    calls.push({ cmd, args, env: opts.env, cwd: opts.cwd });
    const want = String(opts.env.V8_EXPECT_FINGERPRINT).toLowerCase();
    if (chainFingerprint === "silent") return { status: 0, stdout: "", stderr: "" };
    if (want === chainFingerprint) return { status: 0, stdout: `BROADCASTV8 FINGERPRINT MATCHES ${chainFingerprint}\n`, stderr: "" };
    return { status: 1, stdout: `BROADCASTV8 EXPECTED ${want}\nBROADCASTV8 ACTUAL   ${chainFingerprint}\n`, stderr: "Error: script failed: BroadcastV8: the deployment changed since it was verified\n" };
  };
  return { exec, calls };
}

const FP_A = "0x" + "a1".repeat(32);
const FP_B = "0x" + "b2".repeat(32);

// Writes the written-back fixture to a temp file and a receipt beside it, the way broadcast-v8.sh leaves them:
// registrySha256 = sha256 of the exact bytes, chainId = the registry's, fingerprint = what VerifyV8 passed against.
function receiptFixture({ fingerprint = FP_A, mutateRegistry = () => {}, mutateReceipt = () => {} } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "day-zero-receipt-"));
  const reg = writtenBack(mutateRegistry);
  const registryPath = join(dir, "tier1.json");
  writeFileSync(registryPath, JSON.stringify(reg, null, 2) + "\n");
  const receipt = { fingerprint, chainId: String(reg.shared.chainId), registrySha256: createHash("sha256").update(readFileSync(registryPath)).digest("hex"), verifiedAt: "2026-09-22T05:18:00Z" };
  mutateReceipt(receipt);
  const receiptPath = join(dir, "verify-passed.json");
  writeFileSync(receiptPath, JSON.stringify(receipt, null, 2) + "\n");
  return { dir, reg, registryPath, receiptPath, receipt };
}

describe("verify receipt (T-OP-163)", () => {
  test("CONTRACT_KEYS is LIFTED from lib/registry-env.sh, sixteen keys in the driver's deploy order, never typed here", () => {
    const keys = contractKeysFromLib();
    assert.equal(keys.length, 16);
    assert.equal(keys[0], "accessManager");
    assert.equal(keys[keys.length - 1], "flywheel.buybackExecutor");
    // the same line the driver's own parity check reads: one ^CONTRACT_KEYS= line, and it is what we lifted
    const lib = readFileSync(join(REPO, "script", "v2", "lib", "registry-env.sh"), "utf8");
    assert.equal(lib.split("\n").filter((l) => l.startsWith('CONTRACT_KEYS="')).length, 1);
    assert.equal(keys.join(" "), lib.match(/^CONTRACT_KEYS="(.*)"$/m)[1]);
    refuses(() => contractKeysFromLib(join(REPO, "script", "v2", "roles.v8.json")), /expected exactly one \^CONTRACT_KEYS= line/);
  });

  test("the address list is in CONTRACT_KEYS order, flywheel.* read beside v2.contracts, and a null slot refuses by name", () => {
    assert.equal(registryPathOf("flywheel.feeSplitter"), "v2.flywheel.feeSplitter");
    assert.equal(registryPathOf("sources.univ3"), "v2.contracts.sources.univ3");
    assert.equal(registryPathOf("clearinghouse"), "v2.contracts.clearinghouse");
    const keys = contractKeysFromLib();
    const addrs = fingerprintAddrs(writtenBack(), keys);
    assert.equal(addrs.length, 16);
    assert.equal(addrs[0], RUN3.contracts.accessManager);
    assert.equal(addrs[1], RUN3.flywheel.feeSplitter);
    assert.equal(addrs[15], RUN3.flywheel.buybackExecutor);
    refuses(() => fingerprintAddrs(writtenBack((r) => { r.v2.flywheel.buybackExecutor = null; }), keys), /15 of 16 CONTRACT_KEYS addresses .*missing: flywheel\.buybackExecutor/);
    refuses(() => fingerprintAddrs(JSON.parse(readFileSync(FIXTURE, "utf8")), keys), /0 of 16 CONTRACT_KEYS addresses/);
  });

  test("a MATCHING receipt passes: same registry bytes, same chain, and the driver's script answers MATCHES over the sixteen addresses", () => {
    const f = receiptFixture();
    const forge = stubForge(FP_A);
    const got = checkReceipt({ receiptPath: f.receiptPath, registryPath: f.registryPath, registry: f.reg, rpc: "http://127.0.0.1:8599", exec: forge.exec });
    assert.equal(got.fingerprint, FP_A);
    assert.equal(got.chainId, f.reg.shared.chainId);
    assert.equal(got.registrySha256, f.receipt.registrySha256);
    assert.equal(got.addresses, 16);
    // what forge was HANDED: the driver's script, its --sig, the rpc, and the env names broadcast-v8.sh uses
    assert.equal(forge.calls.length, 1);
    const c = forge.calls[0];
    assert.equal(c.cmd, "forge");
    assert.deepEqual(c.args.slice(0, 4), ["script", "script/v2/BroadcastV8.s.sol:BroadcastV8", "--sig", "assertFingerprint()"]);
    assert.ok(c.args.includes("--rpc-url") && c.args.includes("http://127.0.0.1:8599") && c.args.includes("--no-storage-caching") && c.args.includes("--non-interactive"));
    assert.equal(c.env.V8_EXPECT_FINGERPRINT, FP_A);
    assert.equal(c.env.V8_MIN_CONTRACTS, "16");
    assert.equal(c.env.V8_FINGERPRINT_ADDRS, fingerprintAddrs(f.reg, contractKeysFromLib()).join(","));
    assert.equal(c.cwd, REPO);
  });

  test("a receipt for a DIFFERENT registry is refused naming both sha256s -- before forge is ever asked", () => {
    const f = receiptFixture({ mutateRegistry: (r) => { r.v2.deployBlock = RUN3.deployBlock + 1; } });
    // the receipt was made for THIS file; now hand a registry with other bytes
    const other = receiptFixture();
    const forge = stubForge(FP_A);
    refuses(() => checkReceipt({ receiptPath: f.receiptPath, registryPath: other.registryPath, registry: other.reg, rpc: "http://x", exec: forge.exec }),
      new RegExp(`verified registry sha256 ${f.receipt.registrySha256}, but --registry .* is ${other.receipt.registrySha256}`));
    assert.equal(forge.calls.length, 0);
  });

  test("a receipt whose chain is not the registry's is refused; a receipt with a missing field or no file is refused", () => {
    const f = receiptFixture({ mutateReceipt: (r) => { r.chainId = "1"; } });
    refuses(() => checkReceipt({ receiptPath: f.receiptPath, registryPath: f.registryPath, registry: f.reg, rpc: "http://x", exec: stubForge(FP_A).exec }), /verified chain 1, and --registry says shared\.chainId 4663/);
    const g = receiptFixture({ mutateReceipt: (r) => { delete r.fingerprint; } });
    refuses(() => readReceipt(g.receiptPath), /has no fingerprint field/);
    refuses(() => readReceipt(join(g.dir, "absent.json")), /no verify receipt at/);
    const h = receiptFixture({ fingerprint: "0xbeef" });
    refuses(() => readReceipt(h.receiptPath), /is not a 32-byte hex value/);
  });

  test("a fingerprint the chain no longer matches is refused naming BOTH fingerprints (BroadcastV8's EXPECTED/ACTUAL)", () => {
    const f = receiptFixture({ fingerprint: FP_A });
    const forge = stubForge(FP_B); // the chain now fingerprints B
    refuses(() => checkReceipt({ receiptPath: f.receiptPath, registryPath: f.registryPath, registry: f.reg, rpc: "http://x", exec: forge.exec }),
      new RegExp(`receipt fingerprint ${FP_A}, chain fingerprint now ${FP_B}`));
  });

  test("a forge that exits 0 and prints nothing is NOT a match (the driver's second condition), and no --rpc is a refusal", () => {
    const f = receiptFixture();
    refuses(() => assertFingerprintOnChain({ fingerprint: FP_A, addrs: fingerprintAddrs(f.reg, contractKeysFromLib()), rpc: "http://x", exec: stubForge("silent").exec }), /did not print MATCHES/);
    refuses(() => checkReceipt({ receiptPath: f.receiptPath, registryPath: f.registryPath, registry: f.reg, rpc: null, exec: stubForge(FP_A).exec }), /--verify-receipt needs --rpc/);
  });

  test("CLI: a signable run (--out) WITHOUT the receipt refuses naming every signable stage; nothing is written", () => {
    const f = receiptFixture();
    const out = join(f.dir, "batch");
    const argv = ["--registry", f.registryPath, "--abis", abiDir(), "--out", out];
    refuses(() => run(argv, { exec: stubForge(FP_A).exec }), /--out writes signable batches \(stages map, config, list, fees, golive, vault, arm/);
    assert.ok(!existsSync(out));
    assert.deepEqual([...SIGNABLE_STAGES], STAGES.map((s) => s.id));
  });

  test("CLI: a PLANNING run (no --out) works without the receipt and says it is a preview; with a receipt it records the fingerprint", () => {
    const f = receiptFixture();
    const argv = ["--registry", f.registryPath, "--abis", abiDir()];
    const chunks = [];
    const orig = process.stdout.write;
    process.stdout.write = (c) => { chunks.push(String(c)); return true; };
    try {
      assert.equal(run(argv, { exec: stubForge(FP_A).exec }), EXIT.OK);
      const preview = chunks.join("");
      assert.match(preview, /PREVIEW: built WITHOUT a VerifyV8 receipt/);
      assert.match(preview, /\(PREVIEW, nothing written\)/);
      chunks.length = 0;
      assert.equal(run([...argv, "--verify-receipt", f.receiptPath, "--rpc", "http://127.0.0.1:8599"], { exec: stubForge(FP_A).exec }), EXIT.OK);
      assert.match(chunks.join(""), new RegExp(`VerifyV8 receipt: fingerprint \`${FP_A}\``));
    } finally {
      process.stdout.write = orig;
    }
  });

  test("CLI: a signable run WITH a matching receipt writes the batches and plan.json names the verified deployment; a mismatch writes nothing", () => {
    const f = receiptFixture();
    const out = join(f.dir, "batch");
    const orig = process.stdout.write;
    process.stdout.write = () => true;
    try {
      assert.equal(run(["--registry", f.registryPath, "--abis", abiDir(), "--out", out, "--verify-receipt", f.receiptPath, "--rpc", "http://127.0.0.1:8599"], { exec: stubForge(FP_A).exec }), EXIT.OK);
    } finally {
      process.stdout.write = orig;
    }
    const planJson = JSON.parse(readFileSync(join(out, "plan.json"), "utf8"));
    assert.equal(planJson.generatedFrom.verifyReceipt.fingerprint, FP_A);
    assert.equal(planJson.generatedFrom.verifyReceipt.registrySha256, f.receipt.registrySha256);
    assert.equal(planJson.generatedFrom.verifyReceipt.chainId, 4663);
    assert.match(readFileSync(join(out, "PLAN.md"), "utf8"), /VerifyV8 receipt: fingerprint/);
    const out2 = join(f.dir, "batch-mismatch");
    refuses(() => run(["--registry", f.registryPath, "--abis", abiDir(), "--out", out2, "--verify-receipt", f.receiptPath, "--rpc", "http://127.0.0.1:8599"], { exec: stubForge(FP_B).exec }), /chain fingerprint now/);
    assert.ok(!existsSync(out2));
  });

  test("the flags parse and there is no --skip-receipt", () => {
    const o = parseArgs(["--registry", "r.json", "--verify-receipt", "v.json", "--rpc", "http://x"]);
    assert.equal(o.verifyReceipt, "v.json");
    assert.equal(o.rpc, "http://x");
    refuses(() => parseArgs(["--skip-receipt"]), /unknown flag --skip-receipt/);
  });
});
