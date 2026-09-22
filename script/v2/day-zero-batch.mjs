#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// T-OP-098. THE DAY-ZERO ADMIN BATCH: every AccessManager operation the Admin Safe signs after the broadcast,
// as Safe Transaction Builder JSON the owner can import, read and sign -- not as a runbook sentence.
//
//   node script/v2/day-zero-batch.mjs --registry <written-back registry> --out <dir> \
//        --verify-receipt <run-dir>/verify-passed.json --rpc <url> [--abis <dir>] [flags]
//   (no --out = a PLAN.md preview, nothing signable, the receipt optional; see THE VERIFY RECEIPT below)
//
// WHY THIS FILE EXISTS. `DeployV8.s.sol` wires the sixteen core contracts while the deployer still holds
// every working role at delay 0, then renounces ADMIN as its LAST call (DeployV8.s.sol, "WHY THE ORDER IS
// WHAT IT IS", steps 1-9). From that block on, every admin call in the system goes through the 2-of-3 Admin
// Safe under the lane delays in script/v2/roles.v8.json, and the Safe cannot run `forge script`.
// `RegisterMarkets.s.sol` knows the exact calls a market needs (`plan()`, :856) and `HouseVaultFactory.sol`
// says what a new vault needs (its own `setTargetFunctionRole` batch, 48 h), but both are written for a
// signer forge controls -- on the fork that is an impersonated Safe, on the real chain it is nobody. So on
// broadcast day the owner would be handed a list of sentences. This generator turns the same sources into
// signable transactions and derives EVERY value from the written-back registry, the roles manifest, the
// exported ABIs and the contract constants in `src/`. It types no address, no selector and no delay.
//
// THE PATTERN EVERY DELAYED CALL FOLLOWS (06-QUIRKS §D.2, RegisterMarkets._executeScheduled):
//   1. the Safe calls `AccessManager.schedule(target, data, 0)`  -- opId = keccak256(abi.encode(safe, target, data))
//   2. the lane's delay elapses (`getSchedule(opId)` returns readyAt; it is the node's clock, nobody waits for it here)
//   3. the Safe calls the TARGET directly with `data`; `restricted` sees the Safe's delayed role and consumes the
//      schedule (`AccessManager._checkAuthorized` / `AccessManaged._checkCanCall`). NOT `manager.execute`, which
//      would make the manager the msg.sender the target sees.
//   A scheduled operation EXPIRES one week after readyAt (`AccessManager.expiration()`, §D.5): the execute batch
//   has a window, not a deadline-free future. A money-lane operation can be cancelled by GUARDIAN (roleGuardian in
//   roles.v8.json, §D.4); an ADMIN-lane operation (the role mappings) can be cancelled only by the Safe itself.
//
// WHAT IS ENUMERATED, in dependency order (the doc, docs/V8-DAY-ZERO-ADMIN-BATCH.md, is the human checklist):
//   MAP      ADMIN 48 h        `setTargetFunctionRole(target, selectors, role)` for every externally supplied target
//                              the registry records (houseVault, houseVaultFactory, hedger, earnVault,
//                              stockVenueAdapter, rewardsDistributorLender). DeployV8 maps only what it was GIVEN
//                              (`_mapTarget`: "SKIPPED AND ANNOUNCED"); a contract that arrived after the renounce
//                              has every `restricted` selector answering to ADMIN by default (06-QUIRKS §A.8).
//                              One call per (target, role), selectors grouped -- the shape HouseVaultFactory's
//                              NatSpec describes. THE HOUSE VAULTS ARE A SET (T-OP-172, owner ruling 2026-09-22
//                              05:45Z: two at launch): dedup(v2.contracts.houseVault, every non-null
//                              markets[].v2.houseVault) in launchSet order, each mapped in its own calls with the
//                              ticker in the label; a launch market whose v2.houseVault is null is skipped BY NAME.
//   CONFIG   CONFIG_ADMIN 24 h per launch market: chainlinkSource.setFeed, univ3Source.setPool (with a pool),
//                              settlementOracle.setMarket, payoutRouter.setRouteV3/V4 (with a route) -- exactly
//                              RegisterMarkets.plan(), arguments from the same registry fields, constants from
//                              the same contracts.
//   LIST     LISTING 1 h       clearinghouse.registerMarket(asset, strikeTick, DISABLED) per market, then
//                              clearinghouse.setMarketListing(asset, ENABLED, strikeTick) as a SEPARATE go-live
//                              batch (the rehearsal's two passes, T-OP-099).
//   VAULT    LISTING 1 h       houseVaultFactory.createVault(...) when --create-vault names a market that has no
//                              vault yet (another market's vault is not a reason to refuse); after MAP, because
//                              an unmapped factory answers to ADMIN and the schedule would take 48 h.
//   FEES     MARKET_FEE_MANAGER 72 h  clearinghouse.setMarketFees only for a market whose rent differs from the
//                              deploy-time default (RegisterMarkets._feeCall); the launch set's is 0, so none.
//   ARM      CONFIG_ADMIN 24 h houseVault.setProtocolAccount(account, true) PER VAULT for the protocol's own makers,
//                              which is what ARMS `take` (HouseVault.protocolAccountsConfirmed), PLUS EACH VAULT AS
//                              A PROTOCOL ACCOUNT OF EVERY OTHER (V8-DAILY-HOUSEVAULT-DESIGN.md §4 item 4: the
//                              two-vaults-per-market exposure closes in the take direction on chain only if each
//                              vault refuses to take against the other): n vaults -> n*(n-1) pairwise calls, two
//                              for the launch pair. Scheduled only after the MAP stage has executed, so the
//                              schedule is made under the right lane.
//
// THE VERIFY RECEIPT (T-OP-163, audit F1). broadcast-v8.sh makes registration unreachable unless VerifyV8 passed IN
// THAT RUN AGAINST THAT DEPLOYMENT: it writes <run-dir>/verify-passed.json {fingerprint, chainId, registrySha256,
// verifiedAt} and re-derives the fingerprint from the chain (BroadcastV8.assertFingerprint) before it registers. The
// batches THIS file writes are the path the owner actually signs after the broadcast, and until T-OP-163 nothing here
// asked whether VerifyV8 ever passed: `01-config-schedule.json` could be built for a deployment VerifyV8 failed on, or
// never reached its summary line on. So: `--verify-receipt <run-dir>/verify-passed.json` is REQUIRED for every run
// that writes signable calldata -- that is every `--out` run, whose stages are ALL signable (map, config, list, fees,
// golive, vault, arm: each emits schedule/execute Safe Transaction Builder JSON) -- and OPTIONAL for the one planning
// mode, a run without `--out` (PLAN.md to stdout, no batch file, no plan.json), where it is still checked when given.
// The receipt is the DRIVER'S artefact, consumed as it is written; there is no second format. Three checks, each a
// refusal by name: (1) receipt.registrySha256 == sha256 of the --registry file THIS batch is built from, byte for byte
// (the batch and the verify must read the same registry); (2) receipt.chainId == registry shared.chainId; (3)
// receipt.fingerprint == the fingerprint BroadcastV8.assertFingerprint() derives from the chain NOW over the sixteen
// addresses in CONTRACT_KEYS order -- run through the SAME forge script the driver runs (script/v2/BroadcastV8.s.sol,
// env V8_EXPECT_FINGERPRINT / V8_FINGERPRINT_ADDRS / V8_MIN_CONTRACTS, the order lifted from lib/registry-env.sh's one
// CONTRACT_KEYS line), never a JavaScript re-implementation of its keccak. That read needs `--rpc`: a fingerprint is a
// fact about the chain (chain id, addresses, CODE HASHES), not about a file, and a batch for a chain the generator
// cannot reach must not be signed. There is no --skip-receipt.
//
// THE SEQUENCE CHANGE OF 2026-09-22 (T-OP-153/161/162): the launch set is now REGISTERED INSIDE THE DEPLOYER'S
// WINDOW (RegisterMarkets signed by the deployer before HandBack), so on launch day the config/list/golive stages
// below find nothing to do for NVDA and SPCX; the batch is the POST-BROADCAST admin -- map, arm, protocol accounts,
// later listings and waves -- and the receipt gate is still the one thing that stops signing against an unverified
// deployment.
//
// WHAT IS DELIBERATELY NOT HERE. Funding, purchases, token transfers, anything that moves value: owner-gated and
// separate. Role grants: DeployV8 granted every holder in roles.v8.json before the renounce. Fee and limit
// parameters: DeployV8 set them from `v2.fees` / `v2.vault` (V2DeployBase's Params); a value the owner wants
// changed after launch is a new decision, not a day-zero step, and the doc says how to verify the deployed ones.
//
// REFUSALS (exit 2, nothing written). A null core address or a null `v2.deployBlock`: the registry does not
// describe a broadcast. A launch market missing from `markets[]`, or with a null asset/feed/strikeTick. A v4
// payout route whose (fee, tickSpacing) does not rebuild to the pinned poolId (the silent-misroute guard
// RegisterMarkets._requirePinnedPool applies; here it is done offline from the same key). A call whose
// (contract, signature) is not in roles.v8.json, or is there under a different lane than this batch uses. An
// unknown flag. "No operations" and "refused" never look alike.
//
// Node 22+ stdlib only: keccak-256 and the ABI encoder are implemented here (the contracts repo has no
// node_modules, and this file must run on the broadcast box from a fresh clone).

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

export const EXIT = Object.freeze({ OK: 0, REFUSED: 2 });

export class RefusalError extends Error {
  constructor(message) {
    super(message);
    this.name = "RefusalError";
  }
}

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO = resolve(HERE, "..", "..");

/* ------------------------------------------------------------------------------------------------ */
/*  keccak-256                                                                                        */
/* ------------------------------------------------------------------------------------------------ */

const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n, 0x000000000000808bn,
  0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n, 0x000000000000008an, 0x0000000000000088n,
  0x0000000080008009n, 0x000000008000000an, 0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n,
  0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const ROT = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];
const M64 = (1n << 64n) - 1n;
const rotl = (x, n) => n === 0 ? x : ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64;

function keccakF(s) {
  for (let round = 0; round < 24; round++) {
    const c = new Array(5);
    for (let x = 0; x < 5; x++) c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20];
    const d = new Array(5);
    for (let x = 0; x < 5; x++) d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
    for (let i = 0; i < 25; i++) s[i] ^= d[i % 5];
    const b = new Array(25);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROT[x][y]);
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) s[x + 5 * y] = b[x + 5 * y] ^ (~b[((x + 1) % 5) + 5 * y] & M64 & b[((x + 2) % 5) + 5 * y]);
    }
    s[0] ^= RC[round];
  }
}

/** keccak-256 of a byte array (Uint8Array or Buffer); returns 0x-prefixed hex. */
export function keccak256(bytes) {
  const rate = 136;
  const s = new Array(25).fill(0n);
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate);
  padded.set(bytes);
  padded[bytes.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      s[i] ^= lane;
    }
    keccakF(s);
  }
  let out = "0x";
  for (let i = 0; i < 4; i++) {
    let lane = s[i];
    for (let b = 0; b < 8; b++) {
      out += (lane & 0xffn).toString(16).padStart(2, "0");
      lane >>= 8n;
    }
  }
  return out;
}

export const keccakUtf8 = (str) => keccak256(new TextEncoder().encode(str));
export const selectorOf = (signature) => keccakUtf8(signature).slice(0, 10);

/* ------------------------------------------------------------------------------------------------ */
/*  hex / address helpers                                                                             */
/* ------------------------------------------------------------------------------------------------ */

export const isHex = (v) => typeof v === "string" && /^0x[0-9a-fA-F]*$/.test(v);
export const isAddress = (v) => typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v);
export const ZERO = "0x0000000000000000000000000000000000000000";

export function hexToBytes(hex) {
  if (!isHex(hex) || hex.length % 2 !== 0) throw new RefusalError(`not even-length hex: ${hex}`);
  const out = new Uint8Array((hex.length - 2) / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(2 + i * 2, 4 + i * 2), 16);
  return out;
}

export const concatHex = (...parts) => "0x" + parts.map((p) => p.slice(2)).join("");

/** EIP-55 checksum, for the Safe UI (it refuses a mixed-case address with a wrong checksum). */
export function checksumAddress(addr) {
  if (!isAddress(addr)) throw new RefusalError(`not an address: ${addr}`);
  const lower = addr.slice(2).toLowerCase();
  const hash = keccakUtf8(lower).slice(2);
  let out = "0x";
  for (let i = 0; i < 40; i++) out += parseInt(hash[i], 16) >= 8 ? lower[i].toUpperCase() : lower[i];
  return out;
}

/* ------------------------------------------------------------------------------------------------ */
/*  ABI encoder -- the subset the manifest's signatures need: static & dynamic, arrays, tuples        */
/* ------------------------------------------------------------------------------------------------ */

const pad32 = (hex) => hex.padStart(64, "0");
const toBig = (v, what) => {
  if (typeof v === "bigint") return v;
  if (typeof v === "number") {
    if (!Number.isSafeInteger(v)) throw new RefusalError(`${what}: ${v} is not a safe integer; pass a string`);
    return BigInt(v);
  }
  if (typeof v === "string" && /^-?\d+$/.test(v)) return BigInt(v);
  if (typeof v === "boolean") return v ? 1n : 0n;
  throw new RefusalError(`${what}: cannot read ${JSON.stringify(v)} as an integer`);
};

/** A type is dynamic if it is bytes, string, a dynamic array, or a tuple with a dynamic component. */
export function isDynamic(type, components) {
  if (type === "bytes" || type === "string") return true;
  const arr = type.match(/^(.*)\[(\d*)\]$/);
  if (arr) return arr[2] === "" || isDynamic(arr[1], components);
  if (type === "tuple") return (components || []).some((c) => isDynamic(c.type, c.components));
  return false;
}

function encodeStatic(type, value, what) {
  if (type === "address") {
    if (!isAddress(value)) throw new RefusalError(`${what}: ${JSON.stringify(value)} is not an address`);
    return pad32(value.slice(2).toLowerCase());
  }
  if (type === "bool") return pad32(value === true || value === "true" || value === 1n || value === 1 ? "1" : "0");
  let m = type.match(/^uint(\d+)$/);
  if (m) {
    const bits = BigInt(m[1]);
    const n = toBig(value, what);
    if (n < 0n || n >= 1n << bits) throw new RefusalError(`${what}: ${n} does not fit ${type}`);
    return pad32(n.toString(16));
  }
  m = type.match(/^int(\d+)$/);
  if (m) {
    const bits = BigInt(m[1]);
    const n = toBig(value, what);
    if (n < -(1n << (bits - 1n)) || n >= 1n << (bits - 1n)) throw new RefusalError(`${what}: ${n} does not fit ${type}`);
    return pad32(((n + (1n << 256n)) % (1n << 256n)).toString(16));
  }
  m = type.match(/^bytes(\d+)$/);
  if (m) {
    const len = Number(m[1]);
    if (!isHex(value) || value.length !== 2 + len * 2) throw new RefusalError(`${what}: ${JSON.stringify(value)} is not bytes${len}`);
    return value.slice(2).toLowerCase().padEnd(64, "0");
  }
  throw new RefusalError(`${what}: unsupported static type ${type}`);
}

/** Encodes one value of `type` (with tuple `components`) to its head-or-full hex WITHOUT 0x. */
export function encodeValue(type, value, components, what = type) {
  const arr = type.match(/^(.*)\[(\d*)\]$/);
  if (arr) {
    const inner = arr[1];
    if (!Array.isArray(value)) throw new RefusalError(`${what}: expected an array`);
    if (arr[2] !== "" && value.length !== Number(arr[2])) throw new RefusalError(`${what}: expected ${arr[2]} elements`);
    const body = encodeSequence(value.map(() => ({ type: inner, components })), value, what);
    return arr[2] === "" ? pad32(value.length.toString(16)) + body : body;
  }
  if (type === "tuple") {
    if (!Array.isArray(value) && typeof value !== "object") throw new RefusalError(`${what}: expected a tuple`);
    const vals = Array.isArray(value) ? value : components.map((c) => value[c.name]);
    return encodeSequence(components, vals, what);
  }
  if (type === "bytes" || type === "string") {
    const bytes = type === "bytes" ? hexToBytes(value) : new TextEncoder().encode(String(value));
    let hex = "";
    for (const b of bytes) hex += b.toString(16).padStart(2, "0");
    return pad32(bytes.length.toString(16)) + (hex.length ? hex.padEnd(Math.ceil(hex.length / 64) * 64, "0") : "");
  }
  return encodeStatic(type, value, what);
}

/** Head/tail encoding of a parameter list. */
export function encodeSequence(params, values, what = "args") {
  if (values.length !== params.length) throw new RefusalError(`${what}: ${values.length} values for ${params.length} parameters`);
  const heads = [];
  const tails = [];
  let headLen = 0;
  params.forEach((p, i) => {
    const enc = encodeValue(p.type, values[i], p.components, `${what}.${p.name || i}`);
    if (isDynamic(p.type, p.components)) {
      heads.push(null);
      tails.push(enc);
      headLen += 32;
    } else {
      heads.push(enc);
      tails.push("");
      headLen += enc.length / 2;
    }
  });
  let out = "";
  let offset = headLen;
  heads.forEach((h, i) => {
    if (h === null) {
      out += pad32(offset.toString(16));
      offset += tails[i].length / 2;
    } else out += h;
  });
  return out + tails.join("");
}

/** The canonical signature of an ABI function entry, tuples expanded the way `cast sig` and roles.v8.json write them. */
export function canonicalType(input) {
  const arr = input.type.match(/^tuple(\[.*\])?$/);
  if (arr) return `(${input.components.map(canonicalType).join(",")})${arr[1] || ""}`;
  return input.type;
}
export const signatureOf = (fn) => `${fn.name}(${fn.inputs.map(canonicalType).join(",")})`;

export function encodeCall(fn, values) {
  return selectorOf(signatureOf(fn)) + encodeSequence(fn.inputs, values, fn.name);
}

/** `abi.encode(...)` (no selector) -- for opIds and pool ids. */
export const abiEncode = (params, values) => "0x" + encodeSequence(params, values, "abi.encode");

/* ------------------------------------------------------------------------------------------------ */
/*  inputs: registry, roles manifest, ABIs, contract constants                                       */
/* ------------------------------------------------------------------------------------------------ */

export const readJson = (p) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch (e) {
    throw new RefusalError(`cannot read JSON at ${p}: ${e.message}`);
  }
};

/** Registry key -> contract (ABI / manifest) name, for the six externally supplied targets. Mirrors
 *  DeployV8._externallySupplied / registry-env.sh EXTERNAL_KEYS. */
export const EXTERNAL_TARGETS = Object.freeze({
  houseVault: "HouseVault",
  houseVaultFactory: "HouseVaultFactory",
  hedger: "Hedger",
  earnVault: "EarnVault",
  stockVenueAdapter: "StockVenueAdapter",
  rewardsDistributorLender: "RewardsDistributorLender",
});

/** The core keys DeployV8 records; every one must be non-null for the registry to describe a broadcast. */
export const CORE_KEYS = Object.freeze([
  "accessManager", "clearinghouse", "orderBook", "settlementOracle", "expiryCalendar", "keeperRewards",
  "autoRoller", "payoutAdapter", "makerVault", "makerRegistry", "rewardsDistributor",
]);
export const SOURCE_KEYS = Object.freeze(["chainlink", "univ3", "dataStreams"]);

/** Pulls the addresses this batch needs out of the written-back registry, refusing every null it depends on. */
export function readAddresses(reg) {
  const v2 = reg.v2 || {};
  const c = v2.contracts || {};
  const out = {};
  const need = (key, value) => {
    if (!isAddress(value)) throw new RefusalError(`registry ${key} is ${JSON.stringify(value ?? null)}: this file does not describe a broadcast (DeployV8 writes it back; --resume if the run died)`);
    out[key.split(".").pop()] = checksumAddress(value);
  };
  for (const k of CORE_KEYS) need(`v2.contracts.${k}`, c[k]);
  for (const k of SOURCE_KEYS) need(`v2.contracts.sources.${k}`, (c.sources || {})[k]);
  need("v2.flywheel.feeSplitter", (v2.flywheel || {}).feeSplitter);
  need("v2.flywheel.buybackExecutor", (v2.flywheel || {}).buybackExecutor);
  need("shared.safes.admin", ((reg.shared || {}).safes || {}).admin);
  need("shared.usdg", (reg.shared || {}).usdg);
  if (!Number.isInteger(v2.deployBlock) || v2.deployBlock <= 0) {
    throw new RefusalError(`registry v2.deployBlock is ${JSON.stringify(v2.deployBlock ?? null)}: no start block, so no broadcast to plan after`);
  }
  out.deployBlock = v2.deployBlock;
  out.chainId = (reg.shared || {}).chainId;
  if (!Number.isInteger(out.chainId)) throw new RefusalError("registry shared.chainId is not an integer");
  out.externals = {};
  for (const key of Object.keys(EXTERNAL_TARGETS)) {
    const v = c[key];
    if (v === undefined || v === null) continue;
    if (!isAddress(v)) throw new RefusalError(`registry v2.contracts.${key} is ${JSON.stringify(v)}: not an address and not null`);
    out.externals[key] = checksumAddress(v);
  }
  Object.assign(out, houseVaultSet(reg, out.externals.houseVault || null));
  return out;
}

/**
 * THE HOUSE VAULT SET (T-OP-172). The launch has two HouseVaults (owner ruling 2026-09-22 05:45Z): the registry
 * home is OPTION A -- `v2.contracts.houseVault` is NVDA's vault (VerifyV8's single manifest target, unchanged) and
 * `markets[].v2.houseVault` carries each ticker's own. This generator maps, arms and cross-registers EVERY vault
 * the registry records, so the set is derived from the registry and nothing else:
 *   vaults  = dedup(v2.contracts.houseVault, every non-null markets[].v2.houseVault), in launchSet order -- a
 *             per-ticker entry that equals contracts.houseVault is the same vault, named by its ticker once.
 *             `contracts.houseVault` with no per-ticker twin is labelled `houseVault` (the pre-T-OP-156 registry
 *             shape, one vault, ticker unknown to this file).
 *   skipped = the launch markets whose v2.houseVault is null or absent, BY NAME, so the batch says which vault it
 *             is not mapping rather than silently planning for one fewer.
 * Nothing here hard-codes two: n vaults produce n map groups, n arm groups and n*(n-1) pairwise accounts.
 */
export function houseVaultSet(reg, contractsVault) {
  const launch = ((reg.launchSet || {}).markets || []);
  const vaults = [];
  const seen = new Set();
  const add = (ticker, addr) => {
    if (seen.has(addr)) {
      const hit = vaults.find((v) => v.address === addr);
      if (hit.ticker === null) hit.ticker = ticker; // the contracts.houseVault twin gets its ticker
      return;
    }
    seen.add(addr);
    vaults.push({ ticker, address: addr });
  };
  if (contractsVault) add(null, contractsVault);
  const skippedVaults = [];
  for (const ticker of launch) {
    const m = (reg.markets || []).find((x) => x.ticker === ticker);
    if (!m) throw new RefusalError(`launchSet names ${ticker}, which is not in markets[]`);
    const v = (m.v2 || {}).houseVault;
    if (v === undefined || v === null) { skippedVaults.push(ticker); continue; }
    if (!isAddress(v)) throw new RefusalError(`registry markets[${ticker}].v2.houseVault is ${JSON.stringify(v)}: not an address and not null`);
    add(ticker, checksumAddress(v));
  }
  // launchSet order: contracts.houseVault keeps its place only if it is also some ticker's vault; otherwise it
  // stays first, unlabelled, as the one vault the old shape recorded.
  const order = (v) => (v.ticker === null ? -1 : launch.indexOf(v.ticker));
  vaults.sort((x, y) => order(x) - order(y));
  return { vaults, skippedVaults };
}

/** The label a vault carries in every op it appears in: `houseVault[NVDA]`, or bare `houseVault` when unnamed. */
export const vaultLabel = (v) => (v.ticker === null ? "houseVault" : `houseVault[${v.ticker}]`);

/** Reads `uint32 public constant NAME = <expr>;` from a Solidity file; `26 hours`, `300`, `2000` all resolve. */
export function solidityConstant(sourcePath, name) {
  const src = readFileSync(sourcePath, "utf8");
  const m = src.match(new RegExp(`constant\\s+${name}\\s*=\\s*([^;]+);`));
  if (!m) throw new RefusalError(`${sourcePath} declares no constant ${name}; the mirror this generator relies on has moved`);
  const expr = m[1].trim();
  const unit = expr.match(/^(\d+)\s*(seconds|minutes|hours|days|weeks)?$/);
  if (!unit) throw new RefusalError(`${sourcePath}: constant ${name} = ${expr} is not a literal this generator can mirror`);
  const mult = { undefined: 1n, seconds: 1n, minutes: 60n, hours: 3600n, days: 86400n, weeks: 604800n }[unit[2]];
  return BigInt(unit[1]) * mult;
}

/** The three source-level defaults RegisterMarkets reads from the deployed contracts (plan(), :885-900). */
export function contractDefaults(srcDir) {
  return {
    maxStale: solidityConstant(join(srcDir, "v2", "oracle", "ChainlinkFeedSource.sol"), "DEFAULT_MAX_STALE"),
    maxRoundJumpBps: solidityConstant(join(srcDir, "v2", "oracle", "ChainlinkFeedSource.sol"), "DEFAULT_MAX_ROUND_JUMP_BPS"),
    twapWindow: solidityConstant(join(srcDir, "v2", "oracle", "UniV3TwapSource.sol"), "DEFAULT_WINDOW"),
  };
}

export class Abis {
  constructor(dir) {
    if (!existsSync(join(dir, "AccessManager.json"))) {
      throw new RefusalError(`no exported ABIs at ${dir} (AccessManager.json missing). Pass --abis <callhouse>/ops/abis/v2 or set CALLHOUSE_DIR; script/v2/export-abis.sh publishes them`);
    }
    this.dir = dir;
    this.cache = new Map();
  }
  load(name) {
    if (!this.cache.has(name)) {
      const p = join(this.dir, `${name}.json`);
      if (!existsSync(p)) throw new RefusalError(`no exported ABI for ${name} at ${p}: abi-manifest.txt does not publish it, or the export is stale (T-OP-094)`);
      this.cache.set(name, readJson(p));
    }
    return this.cache.get(name);
  }
  /** The function entry for an exact canonical signature; a name alone is ambiguous once overloads exist. */
  fn(name, signature) {
    const hit = this.load(name).find((e) => e.type === "function" && signatureOf(e) === signature);
    if (!hit) throw new RefusalError(`${name}.json has no function ${signature}: the exported ABI and the manifest disagree, stop (T-OP-094 regenerates ops/abis)`);
    return hit;
  }
}

/* ------------------------------------------------------------------------------------------------ */
/*  the roles manifest: lanes, delays, and the (contract, signature) -> role table                    */
/* ------------------------------------------------------------------------------------------------ */

export class Roles {
  constructor(json) {
    if (json.interfaceVersion !== 8) throw new RefusalError(`roles manifest interfaceVersion ${json.interfaceVersion}, expected 8`);
    this.json = json;
  }
  id(role) {
    const v = this.json.roles[role];
    if (v === undefined) throw new RefusalError(`roles.v8.json has no role ${role}`);
    return v;
  }
  delayS(role) {
    const v = this.json.delaysS[role];
    if (v === undefined) throw new RefusalError(`roles.v8.json has no delay for ${role}`);
    return v;
  }
  guardianOf(role) {
    return this.json.roleGuardian[role] || null;
  }
  /** The lane roles.v8.json maps `contract.signature` to, or a refusal. The manager's OWN admin surface is not a
   *  manifest target: AccessManager._getAdminRestrictions (lib/openzeppelin-contracts, AccessManager.sol) routes
   *  setTargetFunctionRole to ADMIN_ROLE, and ADMIN's execution delay is the Safe's (roles.v8.json delaysS.ADMIN). */
  laneOf(contract, signature) {
    if (contract === "AccessManager") {
      if (signature === "setTargetFunctionRole(address,bytes4[],uint64)") return "ADMIN";
      throw new RefusalError(`this generator signs no AccessManager call but setTargetFunctionRole; ${signature} is not planned`);
    }
    const t = this.json.targets[contract];
    if (!t) throw new RefusalError(`roles.v8.json has no target ${contract}`);
    const lane = t[signature];
    if (!lane) throw new RefusalError(`roles.v8.json does not map ${contract}.${signature}: the batch would call an unmapped selector`);
    return lane;
  }
  /** selectors grouped by role for one target, in manifest order -- the setTargetFunctionRole batch a new target needs. */
  groupsFor(contract) {
    const t = this.json.targets[contract];
    if (!t) throw new RefusalError(`roles.v8.json has no target ${contract}`);
    const groups = new Map();
    for (const [sig, role] of Object.entries(t)) {
      if (!groups.has(role)) groups.set(role, []);
      groups.get(role).push({ signature: sig, selector: selectorOf(sig) });
    }
    return groups;
  }
}

/* ------------------------------------------------------------------------------------------------ */
/*  the plan                                                                                          */
/* ------------------------------------------------------------------------------------------------ */

/** Stage ids in execution order; `after` names the stage whose EXECUTE must have happened first. */
export const STAGES = Object.freeze([
  { id: "map", lane: "ADMIN", title: "role mapping for externally supplied targets" },
  { id: "config", lane: "CONFIG_ADMIN", title: "market sources, oracle config, payout routes" },
  { id: "list", lane: "LISTING", title: "register the launch markets DISABLED" },
  { id: "fees", lane: "MARKET_FEE_MANAGER", title: "per-market fees that differ from the deploy default" },
  { id: "golive", lane: "LISTING", title: "enable trading on the registered markets", after: ["config", "list"] },
  // A target that arrived after the renounce answers to ADMIN until MAP has executed; a schedule made before that
  // is accepted under ADMIN's 48 h, not the manifest lane's delay. So everything aimed at an external waits for MAP.
  { id: "vault", lane: "LISTING", title: "createVault on the HouseVaultFactory (when --create-vault names a market)", after: ["map"] },
  { id: "arm", lane: "CONFIG_ADMIN", title: "HouseVault protocol accounts (arms take)", after: ["map"] },
]);

const BPS = 10000n;

function marketRow(reg, ticker) {
  const m = (reg.markets || []).find((x) => x.ticker === ticker);
  if (!m) throw new RefusalError(`launch market ${ticker} is not in markets[]`);
  const v2 = m.v2 || {};
  if (!isAddress(m.asset)) throw new RefusalError(`${ticker}: asset ${JSON.stringify(m.asset ?? null)} is not an address`);
  if (!isAddress(m.feed)) throw new RefusalError(`${ticker}: feed ${JSON.stringify(m.feed ?? null)} is not an address`);
  const strikeTick = toBig(v2.strikeTick ?? null, `${ticker}.v2.strikeTick`);
  if (strikeTick <= 0n) throw new RefusalError(`${ticker}: v2.strikeTick must be positive`);
  const pool = v2.univ3Pool ?? null;
  if (pool !== null && !isAddress(pool)) throw new RefusalError(`${ticker}: v2.univ3Pool ${JSON.stringify(pool)} is neither null nor an address`);
  if (pool !== null && (v2.univ3MinLiquidity === undefined || v2.univ3MinLiquidity === null)) {
    throw new RefusalError(`${ticker}: a pool without v2.univ3MinLiquidity; UniV3TwapSource.setPool refuses a zero floor (T-OP-062)`);
  }
  const defaults = (reg.v2 || {}).defaults || {};
  const ov = v2.overrides || {};
  const pick = (k) => ov[k] ?? defaults[k];
  for (const k of ["maxDeviationBps", "uncorroboratedDelayS", "spotMaxAgeS"]) {
    if (pick(k) === undefined || pick(k) === null) throw new RefusalError(`${ticker}: neither v2.overrides.${k} nor v2.defaults.${k} is set`);
  }
  return {
    ticker,
    asset: checksumAddress(m.asset),
    feed: checksumAddress(m.feed),
    strikeTick,
    pool: pool === null ? null : checksumAddress(pool),
    minLiquidity: pool === null ? 0n : toBig(v2.univ3MinLiquidity, `${ticker}.v2.univ3MinLiquidity`),
    maxDeviationBps: toBig(pick("maxDeviationBps"), `${ticker}.maxDeviationBps`),
    uncorroboratedDelayS: toBig(pick("uncorroboratedDelayS"), `${ticker}.uncorroboratedDelayS`),
    spotMaxAgeS: toBig(pick("spotMaxAgeS"), `${ticker}.spotMaxAgeS`),
    payoutRoute: v2.payoutRoute ?? null,
    mintFeePpm: v2.mintFeePpm ?? null,
  };
}

/** Uniswap v4 PoolId = keccak256(abi.encode(PoolKey)); the key is hookless with the two currencies sorted. Mirrors
 *  RegisterMarkets._requirePinnedPool: a wrong fee or tickSpacing would not revert on chain, it would route every
 *  payout through a different pool. */
export function v4PoolId(asset, usdg, fee, tickSpacing) {
  const [c0, c1] = BigInt(asset) < BigInt(usdg) ? [asset, usdg] : [usdg, asset];
  return keccak256(hexToBytes(abiEncode(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [c0, c1, fee, tickSpacing, ZERO],
  )));
}

/**
 * Builds the operation list. Every op: { stage, lane, delayS, target:{key,address,contract}, signature, args,
 * data, label, opId, cancelBy }. `opId` is hashOperation(safe, target, data) -- deterministic, so the checklist
 * can name it before anything is scheduled.
 */
export function plan({ registry, roles, abis, defaults, markets, createVault = null, protocolAccounts, skipMapping = [] }) {
  const a = readAddresses(registry);
  const safe = a.admin;
  const ops = [];
  const mgr = abis.fn("AccessManager", "schedule(address,bytes,uint48)"); // proves the ABI is the v5 manager
  void mgr;

  const notes = [];
  const call = (stage, targetKey, targetAddress, contract, signature, args, label, note, ticker = null) => {
    const lane = roles.laneOf(contract, signature);
    const stageLane = STAGES.find((s) => s.id === stage).lane;
    if (lane !== stageLane) {
      throw new RefusalError(`${contract}.${signature} is ${lane} in roles.v8.json but the ${stage} stage signs under ${stageLane}`);
    }
    const fn = abis.fn(contract, signature);
    const data = encodeCall(fn, args);
    const opId = keccak256(hexToBytes(abiEncode(
      [{ type: "address" }, { type: "address" }, { type: "bytes" }],
      [safe, targetAddress, data],
    )));
    ops.push({
      stage, lane, delayS: roles.delayS(lane), roleId: roles.id(lane),
      target: { key: targetKey, address: targetAddress, contract, ticker: ticker ?? null },
      signature, fn, args, data, label, note: note || null, opId,
      cancelBy: roles.guardianOf(lane) ? `GUARDIAN (roleGuardian of ${lane}) or the Safe` : "the Safe only (ADMIN has no guardian)",
    });
  };

  // MAP: every externally supplied target the registry records, one call per (target, role). The house vaults
  // are a SET (T-OP-172): one group of calls per vault, the ticker in every label.
  for (const [key, contract] of Object.entries(EXTERNAL_TARGETS)) {
    if (skipMapping.includes(key)) continue;
    const targets = key === "houseVault"
      ? a.vaults.map((v) => ({ label: vaultLabel(v), addr: v.address, ticker: v.ticker }))
      : a.externals[key] ? [{ label: key, addr: a.externals[key], ticker: null }] : [];
    for (const t of targets) {
      for (const [role, sels] of roles.groupsFor(contract)) {
        call("map", "accessManager", a.accessManager, "AccessManager", "setTargetFunctionRole(address,bytes4[],uint64)",
          [t.addr, sels.map((s) => s.selector), roles.id(role)],
          `setTargetFunctionRole(${t.label} → ${role}, ${sels.length} selector${sels.length === 1 ? "" : "s"})`,
          sels.map((s) => `${s.selector} ${s.signature}`).join("; "), t.ticker);
      }
    }
  }
  for (const ticker of a.skippedVaults) {
    if (skipMapping.includes("houseVault")) continue;
    notes.push(`houseVault[${ticker}]: markets[${ticker}].v2.houseVault is null -- not mapped, not armed, not a protocol account of the others; record its address (VaultCreated) and re-run`);
  }

  // CONFIG + LIST + FEES + GOLIVE per launch market, in RegisterMarkets.plan() order.
  for (const ticker of markets) {
    const m = marketRow(registry, ticker);
    call("config", "sources.chainlink", a.chainlink, "ChainlinkFeedSource", "setFeed(address,address,uint32,uint16)",
      [m.asset, m.feed, defaults.maxStale, defaults.maxRoundJumpBps],
      `chainlinkSource.setFeed(${ticker}, feed, ${defaults.maxStale} s, ${defaults.maxRoundJumpBps} bps)`);
    const sources = [a.chainlink];
    if (m.pool) {
      call("config", "sources.univ3", a.univ3, "UniV3TwapSource", "setPool(address,address,uint128,uint32)",
        [m.asset, m.pool, m.minLiquidity, defaults.twapWindow],
        `univ3Source.setPool(${ticker}, pool, ${m.minLiquidity} L, ${defaults.twapWindow} s)`);
      sources.push(a.univ3);
    }
    call("config", "settlementOracle", a.settlementOracle, "SettlementOracle", "setMarket(address,address[],uint16,uint32,uint32)",
      [m.asset, sources, m.maxDeviationBps, m.uncorroboratedDelayS, m.spotMaxAgeS],
      `settlementOracle.setMarket(${ticker}, [${m.pool ? "chainlink, univ3" : "chainlink"}], ${m.maxDeviationBps} bps, ${m.uncorroboratedDelayS} s, ${m.spotMaxAgeS} s)`,
      m.pool ? null : "SINGLE-SOURCE: a window where the feed is not ok leaves adminResolve unbounded (AGENTS.md, owner decision 2026-09-21)");
    const r = m.payoutRoute;
    if (r && r.venue === "v3") {
      call("config", "payoutAdapter", a.payoutAdapter, "PayoutRouter", "setRouteV3(address,uint24)",
        [m.asset, toBig(r.fee, `${ticker}.payoutRoute.fee`)], `payoutRouter.setRouteV3(${ticker}, fee ${r.fee})`);
    } else if (r && r.venue === "v4") {
      const fee = toBig(r.fee, `${ticker}.payoutRoute.fee`);
      const ts = toBig(r.tickSpacing, `${ticker}.payoutRoute.tickSpacing`);
      const rebuilt = v4PoolId(m.asset, a.usdg, fee, ts);
      if (typeof r.poolId !== "string" || rebuilt.toLowerCase() !== r.poolId.toLowerCase()) {
        throw new RefusalError(`${ticker}: payoutRoute (fee ${fee}, tickSpacing ${ts}) rebuilds to pool id ${rebuilt}, the registry pins ${r.poolId}: setRouteV4 would route every payout through a different pool without reverting`);
      }
      call("config", "payoutAdapter", a.payoutAdapter, "PayoutRouter", "setRouteV4(address,uint24,int24)",
        [m.asset, fee, ts], `payoutRouter.setRouteV4(${ticker}, fee ${fee}, tickSpacing ${ts})`, `rebuilds to the pinned pool id ${r.poolId}`);
    } else if (r) {
      throw new RefusalError(`${ticker}: payoutRoute.venue ${JSON.stringify(r.venue)} is neither v3 nor v4`);
    }
    call("list", "clearinghouse", a.clearinghouse, "Clearinghouse", "registerMarket(address,uint64,bool)",
      [m.asset, m.strikeTick, false], `clearinghouse.registerMarket(${ticker}, strikeTick ${m.strikeTick}, DISABLED)`);
    // RegisterMarkets._feeCall: DeployV8 set the defaults to (v2.fees.exerciseFeeBps, 0); a market rent of 0 needs nothing.
    const fees = (registry.v2 || {}).fees || {};
    const exercise = toBig(fees.exerciseFeeBps ?? null, "v2.fees.exerciseFeeBps");
    const ppm = toBig(m.mintFeePpm ?? fees.mintFeePpm ?? 0, `${ticker}.mintFeePpm`);
    if (ppm !== 0n) {
      call("fees", "clearinghouse", a.clearinghouse, "Clearinghouse", "setMarketFees(address,uint16,uint32)",
        [m.asset, exercise, ppm], `clearinghouse.setMarketFees(${ticker}, exercise ${exercise} bps, rent ${ppm} ppm)`);
    }
    call("golive", "clearinghouse", a.clearinghouse, "Clearinghouse", "setMarketListing(address,bool,uint64)",
      [m.asset, true, m.strikeTick], `clearinghouse.setMarketListing(${ticker}, ENABLED, strikeTick ${m.strikeTick})`);
  }

  // createVault: only when asked, only with a factory, and only for a market that has no vault yet. Another
  // market's vault is not a reason to refuse (T-OP-172: two vaults at launch); the same market's is -- a second
  // vault for one underlying reverts (SeriesIdCollision). An unlabelled contracts.houseVault (no per-ticker twin)
  // is assumed to be the FIRST launch market's, which is what owner ruling 05:45Z option A records there.
  if (createVault) {
    if (!a.externals.houseVaultFactory) throw new RefusalError(`--create-vault ${createVault}: registry v2.contracts.houseVaultFactory is null`);
    const launch0 = ((registry.launchSet || {}).markets || [])[0] ?? null;
    const has = a.vaults.find((v) => v.ticker === createVault || (v.ticker === null && createVault === launch0));
    if (has) throw new RefusalError(`--create-vault ${createVault}: the registry already records a vault for ${createVault} (${has.ticker === null ? "v2.contracts.houseVault" : `markets[${createVault}].v2.houseVault`} = ${has.address}); a second vault for the same underlying reverts (SeriesIdCollision)`);
    const m = marketRow(registry, createVault);
    const lim = (registry.v2 || {}).vault || {};
    for (const k of ["maxSeriesUnits", "maxTotalNotional", "askToleranceBps", "maxBidBpsOfSpot", "maxOrderLifetime", "maxDailyOutflow"]) {
      if (lim[k] === undefined || lim[k] === null) throw new RefusalError(`--create-vault: registry v2.vault.${k} is null`);
    }
    const limits = [lim.maxSeriesUnits, lim.maxTotalNotional, lim.askToleranceBps, lim.maxBidBpsOfSpot, lim.maxOrderLifetime, lim.maxDailyOutflow].map((v, i) => toBig(v, `v2.vault[${i}]`));
    call("vault", "houseVaultFactory", a.externals.houseVaultFactory, "HouseVaultFactory",
      "createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)",
      [m.asset, limits, `Stonkhouse House ${createVault}`, `h${createVault}`],
      `houseVaultFactory.createVault(${createVault}, v2.vault limits, "Stonkhouse House ${createVault}", "h${createVault}")`,
      `the new vault is born UNMAPPED: record its address (VaultCreated) under markets[${createVault}].v2.houseVault${launch0 === createVault ? " (and v2.contracts.houseVault, option A)" : ""} and re-run this generator for its map + arm stages`, createVault);
  }

  // ARM, per vault: setProtocolAccount(x, true) for the protocol's own makers, then EVERY OTHER VAULT (design §4
  // item 4, T-OP-172). Scheduled after MAP has executed. Per vault the first blocked=true call is what arms take.
  if (a.vaults.length !== 0 && !skipMapping.includes("arm")) {
    const accounts = [];
    for (const key of protocolAccounts) {
      const addr = key === "feeSplitter" ? a.feeSplitter : key === "buybackExecutor" ? a.buybackExecutor : a[key] || a.externals[key];
      if (!addr) throw new RefusalError(`--protocol-accounts names ${key}, which the registry does not record`);
      const self = a.vaults.find((v) => v.address === addr);
      if (self) throw new RefusalError(`--protocol-accounts names a vault itself (${key} = ${vaultLabel(self)}); _requireNoSelfDeal already refuses that maker, and the other vaults are added pairwise by this generator`);
      accounts.push([key, addr]);
    }
    for (const v of a.vaults) {
      const me = vaultLabel(v);
      let first = true;
      const arm = (label, addr, extra) => {
        call("arm", "houseVault", v.address, "HouseVault", "setProtocolAccount(address,bool)", [addr, true],
          `${me}.setProtocolAccount(${label}, blocked=true)`,
          [first ? "the first blocked=true call ARMS take (ProtocolAccountsConfirmed)" : null, extra].filter(Boolean).join("; ") || null,
          v.ticker);
        first = false;
      };
      for (const [key, addr] of accounts) arm(key, addr, null);
      for (const other of a.vaults) {
        if (other.address === v.address) continue;
        arm(vaultLabel(other), other.address, "each vault a protocol account of the other (V8-DAILY-HOUSEVAULT-DESIGN §4 item 4): closes the take direction between the two");
      }
    }
  }
  const pairwise = a.vaults.length * (a.vaults.length - 1);
  if (a.vaults.length > 1) notes.push(`${a.vaults.length} house vaults (${a.vaults.map(vaultLabel).join(", ")}): ${pairwise} pairwise setProtocolAccount call(s) in ARM, n*(n-1)`);

  return { addresses: a, safe, ops, markets, defaults, notes, vaults: a.vaults, skippedVaults: a.skippedVaults };
}

/* ------------------------------------------------------------------------------------------------ */
/*  the verify receipt (T-OP-163)                                                                     */
/* ------------------------------------------------------------------------------------------------ */

/** Where the driver keeps the ONE list of recorded contract keys, in deploy order (T-OP-113). */
export const REGISTRY_ENV_LIB = join(REPO, "script", "v2", "lib", "registry-env.sh");
/** The driver's fingerprint script; the generator runs it, never re-implements it. */
export const BROADCAST_V8 = "script/v2/BroadcastV8.s.sol:BroadcastV8";

/**
 * CONTRACT_KEYS as lib/registry-env.sh defines them, lifted from the file by line pattern -- the technique
 * check-env-names.sh and broadcast-v8.sh --self-test use -- so this file never carries a second copy of the list. The
 * ORDER is part of the fingerprint: BroadcastV8 hashes the addresses in the order it is handed them, and the driver
 * hands them in CONTRACT_KEYS order (read_contract_addrs). A list typed here would drift from the lib's silently and
 * fingerprint a different deployment.
 */
export function contractKeysFromLib(libPath = REGISTRY_ENV_LIB) {
  let text;
  try { text = readFileSync(libPath, "utf8"); } catch (e) { throw new RefusalError(`cannot read ${libPath} (${e.message}): CONTRACT_KEYS, the fingerprint's address order, is lifted from it and nowhere else`); }
  const lines = text.split("\n").filter((l) => /^CONTRACT_KEYS="/.test(l));
  if (lines.length !== 1) throw new RefusalError(`expected exactly one ^CONTRACT_KEYS= line in ${libPath}, found ${lines.length}: the fingerprint's address order cannot be derived`);
  const keys = lines[0].replace(/^CONTRACT_KEYS="/, "").replace(/"\s*$/, "").trim().split(/\s+/).filter(Boolean);
  if (keys.length === 0) throw new RefusalError(`CONTRACT_KEYS in ${libPath} is empty`);
  return keys;
}

/** The registry path a CONTRACT_KEYS key is recorded at: flywheel.* beside v2.contracts, everything else inside it. */
export function registryPathOf(key) {
  return key.startsWith("flywheel.") ? `v2.flywheel.${key.slice("flywheel.".length)}` : `v2.contracts.${key}`;
}

/**
 * The comma-joined address list BroadcastV8 fingerprints, in CONTRACT_KEYS order. ABSENT IS NOT ZERO AND NOT OK: a
 * registry with a null slot cannot name the deployment the receipt is about, so it is refused here rather than handed
 * to forge as a shorter list (which BroadcastV8 also refuses, but after a compile and without the key's name).
 */
export function fingerprintAddrs(registry, keys) {
  const addrs = [];
  const missing = [];
  for (const k of keys) {
    const v = registryPathOf(k).split(".").reduce((o, seg) => (o && typeof o === "object" ? o[seg] : undefined), registry);
    if (isAddress(v)) addrs.push(checksumAddress(v)); else missing.push(k);
  }
  if (missing.length) throw new RefusalError(`${addrs.length} of ${keys.length} CONTRACT_KEYS addresses in the registry (missing: ${missing.join(" ")}): the fingerprint names every recorded contract or none`);
  return addrs;
}

/** sha256 of a file's bytes, hex -- the value broadcast-v8.sh records as registrySha256 (`shasum -a 256`). */
export function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/** The driver's receipt, every field required: a receipt that names no deployment binds the signature to nothing. */
export function readReceipt(path) {
  if (!existsSync(path)) throw new RefusalError(`no verify receipt at ${path}. VerifyV8 has not passed in a run whose receipt you can hand me, so nothing is written. broadcast-v8.sh writes <run-dir>/verify-passed.json when its VerifyV8 gate passes; point --verify-receipt at that file`);
  const r = readJson(path);
  for (const f of ["fingerprint", "chainId", "registrySha256"]) {
    if (r[f] === undefined || r[f] === null || r[f] === "") throw new RefusalError(`${path} has no ${f} field. A receipt that does not name the deployment it verified binds the batch to nothing`);
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(r.fingerprint))) throw new RefusalError(`${path}: fingerprint '${r.fingerprint}' is not a 32-byte hex value`);
  return { fingerprint: String(r.fingerprint).toLowerCase(), chainId: Number(r.chainId), registrySha256: String(r.registrySha256).toLowerCase(), verifiedAt: r.verifiedAt ?? null };
}

/**
 * Runs the driver's own fingerprint check: `forge script BroadcastV8.s.sol:BroadcastV8 --sig assertFingerprint()`
 * with the receipt's fingerprint expected, over `addrs` at `rpc`. The two conditions are the driver's (broadcast-v8.sh
 * step 3): forge must exit 0 AND print `BROADCASTV8 FINGERPRINT MATCHES`; a script stubbed to nothing exits 0 and
 * prints nothing, and that is not a match. On a mismatch BroadcastV8 prints EXPECTED and ACTUAL, which the refusal
 * carries. `exec` is injectable so the test suite can stand in a forge that answers either way.
 */
export function assertFingerprintOnChain({ fingerprint, addrs, rpc, exec = defaultExec, cwd = REPO }) {
  const env = {
    ...process.env,
    V8_EXPECT_FINGERPRINT: fingerprint,
    V8_FINGERPRINT_ADDRS: addrs.join(","),
    V8_MIN_CONTRACTS: String(addrs.length),
  };
  const args = ["script", BROADCAST_V8, "--sig", "assertFingerprint()", "--rpc-url", rpc, "--no-storage-caching", "--non-interactive"];
  const r = exec("forge", args, { env, cwd });
  const out = `${r.stdout || ""}\n${r.stderr || ""}`;
  const m = out.match(/BROADCASTV8 FINGERPRINT MATCHES (0x[0-9a-fA-F]{64})/);
  if (r.status === 0 && m && m[1].toLowerCase() === fingerprint) return m[1].toLowerCase();
  const expected = (out.match(/BROADCASTV8 EXPECTED\s+(0x[0-9a-fA-F]{64})/) || [])[1];
  const actual = (out.match(/BROADCASTV8 ACTUAL\s+(0x[0-9a-fA-F]{64})/) || [])[1];
  if (expected && actual) {
    throw new RefusalError(`the deployment at ${rpc} is not the one the receipt verified: receipt fingerprint ${expected}, chain fingerprint now ${actual} (BroadcastV8.assertFingerprint over ${addrs.length} CONTRACT_KEYS addresses). A redeploy, an upgrade or a wrong --registry between verify and now; nothing is written`);
  }
  const tail = out.trim().split("\n").slice(-6).join(" | ").slice(0, 600);
  throw new RefusalError(`BroadcastV8.assertFingerprint did not print MATCHES (forge exit ${r.status}): ${tail || "<no output>"}. A fingerprint check that did not run is not a pass; nothing is written`);
}

function defaultExec(cmd, args, opts) {
  const r = spawnSync(cmd, args, { ...opts, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.error) return { status: 127, stdout: "", stderr: String(r.error.message) };
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

/**
 * The gate. Refuses, by name, unless the receipt names THIS registry (sha256 of the bytes), THIS chain, and the
 * deployment that is on the chain NOW. Returns what the batch records about it.
 */
export function checkReceipt({ receiptPath, registryPath, registry, rpc, keys = null, exec = defaultExec, cwd = REPO }) {
  const receipt = readReceipt(receiptPath);
  const sha = sha256File(registryPath);
  if (receipt.registrySha256 !== sha) {
    throw new RefusalError(`${receiptPath} verified registry sha256 ${receipt.registrySha256}, but --registry ${registryPath} is ${sha}. The batch must be built from the byte-identical registry VerifyV8 was run against (a write-back after the verify changes the file: verify again); nothing is written`);
  }
  const chainId = (registry.shared || {}).chainId;
  if (receipt.chainId !== chainId) {
    throw new RefusalError(`${receiptPath} verified chain ${receipt.chainId}, and --registry says shared.chainId ${chainId}. A pass on one chain does not authorise signing on another; nothing is written`);
  }
  if (!rpc) throw new RefusalError(`--verify-receipt needs --rpc <url>: the fingerprint is a fact about the chain (chain id, addresses, code hashes) and is re-derived by BroadcastV8.assertFingerprint() now, exactly as broadcast-v8.sh re-derives it before it registers. Nothing is written`);
  const addrs = fingerprintAddrs(registry, keys || contractKeysFromLib());
  const fp = assertFingerprintOnChain({ fingerprint: receipt.fingerprint, addrs, rpc, exec, cwd });
  return { path: receiptPath, fingerprint: fp, chainId: receipt.chainId, registrySha256: sha, verifiedAt: receipt.verifiedAt, addresses: addrs.length };
}

/* ------------------------------------------------------------------------------------------------ */
/*  Safe Transaction Builder JSON                                                                     */
/* ------------------------------------------------------------------------------------------------ */

/** The tx-builder's serializer (safe-react-apps apps/tx-builder/src/lib/checksum.ts): sorted keys, JSON scalars. */
export function serializeForChecksum(json) {
  const replacer = (_, v) => (v === undefined ? null : v);
  if (Array.isArray(json)) return `[${json.map(serializeForChecksum).join(",")}]`;
  if (typeof json === "object" && json !== null) {
    const keys = Object.keys(json).sort();
    let acc = `{${JSON.stringify(keys, replacer)}`;
    for (const k of keys) acc += `${serializeForChecksum(json[k])},`;
    return `${acc}}`;
  }
  return JSON.stringify(json, replacer);
}

/** meta.name is nulled and meta.checksum absent when the checksum is computed, exactly as the app does it. */
export function batchChecksum(batch) {
  const meta = { ...batch.meta, name: null };
  delete meta.checksum;
  return keccakUtf8(serializeForChecksum({ ...batch, meta }));
}

const TX_BUILDER_VERSION = "1.17.1";

/** One contract input for the tx-builder's `contractMethod`, tuples carried with their components. */
const inputFor = (i) => {
  const out = { internalType: i.internalType || i.type, name: i.name, type: i.type };
  if (i.components) out.components = i.components.map(inputFor);
  return out;
};

/** BigInts become decimal strings, recursively (a Limits tuple is an array of them). */
export const plain = (v) => (typeof v === "bigint" ? v.toString() : Array.isArray(v) ? v.map(plain) : v);

/** The tx-builder shows `contractInputsValues` as strings; arrays and tuples as their JSON. */
const inputValue = (type, v) => {
  if (Array.isArray(v)) return JSON.stringify(plain(v));
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "boolean") return v ? "true" : "false";
  return String(v);
};

export function txBuilderBatch({ chainId, safe, name, description, createdAt, transactions }) {
  const batch = {
    version: "1.0",
    chainId: String(chainId),
    createdAt,
    meta: {
      name,
      description,
      txBuilderVersion: TX_BUILDER_VERSION,
      createdFromSafeAddress: safe,
      createdFromOwnerAddress: "",
    },
    transactions,
  };
  batch.meta.checksum = batchChecksum(batch);
  return batch;
}

function scheduleTx(op, abis, manager) {
  const fn = abis.fn("AccessManager", "schedule(address,bytes,uint48)");
  const args = [op.target.address, op.data, 0n];
  return {
    to: manager,
    value: "0",
    data: encodeCall(fn, args),
    contractMethod: { inputs: fn.inputs.map(inputFor), name: fn.name, payable: !!(fn.stateMutability === "payable") },
    contractInputsValues: Object.fromEntries(fn.inputs.map((i, k) => [i.name, inputValue(i.type, args[k])])),
  };
}

function executeTx(op) {
  return {
    to: op.target.address,
    value: "0",
    data: op.data,
    contractMethod: { inputs: op.fn.inputs.map(inputFor), name: op.fn.name, payable: !!(op.fn.stateMutability === "payable") },
    contractInputsValues: Object.fromEntries(op.fn.inputs.map((i, k) => [i.name, inputValue(i.type, op.args[k])])),
  };
}

const fmtDelay = (s) => (s % 86400 === 0 ? `${s / 86400} d` : s % 3600 === 0 ? `${s / 3600} h` : `${s} s`);

/**
 * Turns the plan into files. For every stage with operations: `<nn>-<stage>-schedule.json` (N calls to
 * AccessManager.schedule from the Safe) and `<nn>-<stage>-execute.json` (N direct target calls, same order), plus
 * plan.json (every op with its opId) and PLAN.md (the table the doc's appendix carries).
 */
export function render(p, { abis, createdAt, out, receipt = null }) {
  const files = {};
  let n = 0;
  const byStage = new Map(STAGES.map((s) => [s.id, []]));
  for (const op of p.ops) byStage.get(op.stage).push(op);
  const md = [];
  md.push(`# Day-zero admin batch — ${p.ops.length} operation(s) for the Admin Safe ${p.safe}`);
  md.push("");
  md.push(`Registry deployBlock ${p.addresses.deployBlock}, chain ${p.addresses.chainId}, markets ${p.markets.join(", ")}. Every opId = keccak256(abi.encode(safe, target, data)); verify with \`cast call <accessManager> "getSchedule(bytes32)(uint48)" <opId>\` (0 = not scheduled or consumed).`);
  md.push("");
  // The signed batch names the verified deployment it was built for, or says it is a preview built without one.
  md.push(receipt
    ? `VerifyV8 receipt: fingerprint \`${receipt.fingerprint}\` (${receipt.addresses} CONTRACT_KEYS addresses, re-derived on chain ${receipt.chainId} by BroadcastV8.assertFingerprint), registry sha256 \`${receipt.registrySha256}\`, verified at ${receipt.verifiedAt ?? "<unrecorded>"} — ${receipt.path}.`
    : "PREVIEW: built WITHOUT a VerifyV8 receipt (no --verify-receipt). Nothing here is signable; a run that writes batches (--out) refuses without the receipt.");
  md.push("");
  // The house vault set (T-OP-172): what is mapped/armed, and which launch market's vault is missing, BY NAME.
  const vaults = p.vaults || [];
  md.push(vaults.length
    ? `House vaults (${vaults.length}): ${vaults.map((v) => `\`${vaultLabel(v)}\` ${v.address}`).join(", ")} — each mapped and armed in its own calls; ${vaults.length * (vaults.length - 1)} pairwise setProtocolAccount call(s) (n*(n-1)).`
    : "House vaults: none recorded — no map, no arm, no protocol accounts for a vault in this batch.");
  for (const note of p.notes || []) md.push(`- NOTE: ${note}`);
  md.push("");
  for (const stage of STAGES) {
    const ops = byStage.get(stage.id);
    if (ops.length === 0) continue;
    n += 1;
    const nn = String(n).padStart(2, "0");
    const delay = ops[0].delayS;
    const after = (stage.after || []).filter((s) => byStage.get(s).length > 0);
    const schedName = `${nn}-${stage.id}-schedule.json`;
    const execName = `${nn}-${stage.id}-execute.json`;
    files[schedName] = txBuilderBatch({
      chainId: p.addresses.chainId, safe: p.safe, createdAt,
      name: `v8 day-zero ${nn} ${stage.id}: SCHEDULE (${ops[0].lane}, ${fmtDelay(delay)})`,
      description: `${ops.length} × AccessManager.schedule(target, data, 0) from the Admin Safe. ${stage.title}. ${after.length ? `Sign only after the EXECUTE of: ${after.join(", ")}. ` : ""}Execute batch: ${execName}, not before readyAt (getSchedule(opId)) and within one week of it.`,
      transactions: ops.map((op) => scheduleTx(op, abis, p.addresses.accessManager)),
    });
    files[execName] = txBuilderBatch({
      chainId: p.addresses.chainId, safe: p.safe, createdAt,
      name: `v8 day-zero ${nn} ${stage.id}: EXECUTE (${ops[0].lane}, after ${fmtDelay(delay)})`,
      description: `${ops.length} direct target call(s) from the Admin Safe; each consumes its scheduled op (not manager.execute). ${stage.title}. Every getSchedule(opId) must be non-zero and <= now, and now < readyAt + 1 week.`,
      transactions: ops.map(executeTx),
    });
    md.push(`## ${nn} ${stage.id} — ${stage.title}`);
    md.push("");
    md.push(`Lane **${ops[0].lane}** (role id ${ops[0].roleId}), delay **${fmtDelay(delay)}**${after.length ? `; schedule only after the execute of **${after.join(", ")}**` : ""}. Files: \`${schedName}\`, \`${execName}\`. Cancel: ${ops[0].cancelBy}.`);
    md.push("");
    md.push("| # | call | target | opId | verify after execute |");
    md.push("|---|---|---|---|---|");
    ops.forEach((op, i) => {
      md.push(`| ${i + 1} | \`${op.label}\`${op.note ? ` — ${op.note}` : ""} | \`${op.target.key}\` ${op.target.address} | \`${op.opId}\` | ${verifyHint(op, p)} |`);
    });
    md.push("");
  }
  files["plan.json"] = {
    generatedFrom: { deployBlock: p.addresses.deployBlock, chainId: p.addresses.chainId, safe: p.safe, markets: p.markets, verifyReceipt: receipt },
    houseVaults: (p.vaults || []).map((v) => ({ ticker: v.ticker, address: v.address })),
    skippedVaults: p.skippedVaults || [],
    notes: p.notes || [],
    defaults: Object.fromEntries(Object.entries(p.defaults).map(([k, v]) => [k, v.toString()])),
    operations: p.ops.map((op) => ({
      stage: op.stage, lane: op.lane, roleId: op.roleId, delayS: op.delayS, target: op.target, signature: op.signature,
      selector: op.data.slice(0, 10), args: plain(op.args),
      data: op.data, opId: op.opId, label: op.label, note: op.note, cancelBy: op.cancelBy,
    })),
  };
  files["PLAN.md"] = md.join("\n") + "\n";
  if (out) {
    mkdirSync(out, { recursive: true });
    for (const [name, content] of Object.entries(files)) {
      writeFileSync(join(out, name), typeof content === "string" ? content : JSON.stringify(content, null, 2) + "\n");
    }
  }
  return files;
}

/** The cast call that shows the operation took effect -- one per selector family. */
function verifyHint(op, p) {
  const A = p.addresses;
  const [asset] = op.args;
  switch (op.signature) {
    case "setTargetFunctionRole(address,bytes4[],uint64)":
      return `\`cast call ${A.accessManager} "getTargetFunctionRole(address,bytes4)(uint64)" ${op.args[0]} ${op.args[1][0]}\` → ${op.args[2]}`;
    case "setFeed(address,address,uint32,uint16)":
      return `\`cast call ${A.chainlink} "feeds(address)(address,uint32,uint16)" ${asset}\``;
    case "setPool(address,address,uint128,uint32)":
      return `\`cast call ${A.univ3} "pools(address)" ${asset}\``;
    case "setMarket(address,address[],uint16,uint32,uint32)":
      return `\`cast call ${A.settlementOracle} "marketConfig(address)(address[],uint16,uint32,uint32)" ${asset}\``;
    case "setRouteV3(address,uint24)":
    case "setRouteV4(address,uint24,int24)":
      return `\`cast call ${A.payoutAdapter} "routes(address)((uint8,uint24,int24,address,uint16))" ${asset}\``;
    case "registerMarket(address,uint64,bool)":
    case "setMarketListing(address,bool,uint64)":
    case "setMarketFees(address,uint16,uint32)":
      return `\`cast call ${A.clearinghouse} "market(address)" ${asset}\``;
    case "createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)":
      return `\`cast call ${op.target.address} "vaultOf(address)(address)" ${asset}\` → record under markets[${op.target.ticker ?? "<ticker>"}].v2.houseVault (and v2.contracts.houseVault for the first launch market)`;
    case "setProtocolAccount(address,bool)":
      return `\`cast call ${op.target.address} "protocolAccount(address)(bool)" ${asset}\`; \`"protocolAccountsConfirmed()(bool)"\` → true`;
    default:
      return "—";
  }
}

/* ------------------------------------------------------------------------------------------------ */
/*  CLI                                                                                               */
/* ------------------------------------------------------------------------------------------------ */

export const DEFAULT_PROTOCOL_ACCOUNTS = Object.freeze(["makerVault", "feeSplitter"]);

export function parseArgs(argv) {
  const o = {
    registry: null, roles: join(REPO, "script", "v2", "roles.v8.json"), abis: null, src: join(REPO, "src"), out: null,
    markets: null, createVault: null, protocolAccounts: [...DEFAULT_PROTOCOL_ACCOUNTS], skipMapping: [], createdAt: null, print: false,
    verifyReceipt: null, rpc: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => {
      if (i + 1 >= argv.length) throw new RefusalError(`${a} needs a value`);
      return argv[++i];
    };
    switch (a) {
      case "--registry": o.registry = val(); break;
      case "--roles": o.roles = val(); break;
      case "--abis": o.abis = val(); break;
      case "--src": o.src = val(); break;
      case "--out": o.out = val(); break;
      case "--markets": o.markets = val().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--create-vault": o.createVault = val(); break;
      case "--protocol-accounts": o.protocolAccounts = val().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--skip-mapping": o.skipMapping = val().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--created-at": o.createdAt = Number(val()); break;
      case "--verify-receipt": o.verifyReceipt = val(); break;
      case "--rpc": o.rpc = val(); break;
      case "--print": o.print = true; break;
      case "-h": case "--help": o.help = true; break;
      default: throw new RefusalError(`unknown flag ${a} (a typo must not become a silent default)`);
    }
  }
  return o;
}

export function defaultAbiDir() {
  const candidates = [];
  if (process.env.CALLHOUSE_DIR) candidates.push(join(process.env.CALLHOUSE_DIR, "ops", "abis", "v2"));
  candidates.push(join(REPO, "..", "callhouse", "ops", "abis", "v2"));
  candidates.push(join(REPO, "..", "..", "callhouse", "ops", "abis", "v2"));
  return candidates.find((d) => existsSync(join(d, "AccessManager.json"))) || candidates[0];
}

/** The stages that emit signable calldata -- every one of them; a run with --out writes them all. */
export const SIGNABLE_STAGES = Object.freeze(STAGES.map((s) => s.id));

export function run(argv, deps = {}) {
  const o = parseArgs(argv);
  if (o.help) {
    process.stdout.write(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(2, 60).map((l) => l.replace(/^\/\/ ?/, "")).join("\n") + "\n");
    return EXIT.OK;
  }
  if (!o.registry) throw new RefusalError("--registry <written-back registry> is required");
  const registry = readJson(o.registry);
  const roles = new Roles(readJson(o.roles));
  const abis = new Abis(o.abis || defaultAbiDir());
  const defaults = contractDefaults(o.src);
  const markets = o.markets || ((registry.launchSet || {}).markets ?? null);
  if (!Array.isArray(markets) || markets.length === 0) throw new RefusalError("no launch set: registry launchSet.markets is empty and --markets was not given");
  // THE GATE (T-OP-163). `--out` writes signable Safe Transaction Builder batches for every stage the plan fills,
  // so it is the signable mode and the receipt is REQUIRED before anything is planned; a run without --out is the
  // planning preview (PLAN.md on stdout, no batch file) and may omit it. A receipt handed to either mode is checked.
  let receipt = null;
  if (o.verifyReceipt) {
    receipt = checkReceipt({ receiptPath: o.verifyReceipt, registryPath: o.registry, registry, rpc: o.rpc, exec: deps.exec, cwd: deps.cwd });
  } else if (o.out) {
    throw new RefusalError(`--out writes signable batches (stages ${SIGNABLE_STAGES.join(", ")}: schedule/execute JSON the Admin Safe imports and signs) and needs --verify-receipt <run-dir>/verify-passed.json, the receipt broadcast-v8.sh writes when its VerifyV8 gate passes, plus --rpc to re-derive its fingerprint from the chain. A batch built for a deployment VerifyV8 never passed must not exist. Drop --out for a PREVIEW (PLAN.md only, nothing signable)`);
  }
  const p = plan({ registry, roles, abis, defaults, markets, createVault: o.createVault, protocolAccounts: o.protocolAccounts, skipMapping: o.skipMapping });
  if (p.ops.length === 0) throw new RefusalError("the plan is empty: nothing to sign is a refusal, not a success");
  const files = render(p, { abis, createdAt: o.createdAt ?? Date.now(), out: o.out, receipt });
  const summary = `day-zero-batch: ${p.ops.length} operation(s) in ${Object.keys(files).filter((f) => f.endsWith("-schedule.json")).length} stage(s) for Safe ${p.safe}` + (o.out ? `, written to ${o.out}` : " (PREVIEW, nothing written)") + (receipt ? `, verified deployment ${receipt.fingerprint}` : "");
  process.stdout.write((o.print || !o.out ? files["PLAN.md"] + "\n" : "") + summary + "\n");
  return EXIT.OK;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exit(run(process.argv.slice(2)));
  } catch (e) {
    if (e instanceof RefusalError) {
      process.stderr.write(`day-zero-batch: REFUSED: ${e.message}\n`);
      process.exit(EXIT.REFUSED);
    }
    throw e;
  }
}
