#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// T-263. FIND EVERY CHEATCODE EATEN BY AN ARGUMENT EXPRESSION.
//
// Solidity evaluates a call's arguments BEFORE the call itself, and `vm.prank`,
// `vm.expectRevert`, `vm.expectEmit` and `vm.expectCall` are SINGLE-USE. So in
//
//     vm.prank(admin);
//     house.setPerformanceFeeBps(house.PERFORMANCE_FEE_CEIL_BPS() + 1);
//
// the inner `house.PERFORMANCE_FEE_CEIL_BPS()` executes first and consumes the prank;
// `setPerformanceFeeBps` then arrives from the TEST CONTRACT. The failure surfaces as
// NotAuthorized or ERC20InsufficientBalance -- indistinguishable from the contract
// correctly refusing an unauthorised caller -- or, when the eaten cheatcode is an
// expectation, the expectation binds to a view that cannot revert and the test passes
// having never reached its subject. That is the motivating instance (claude-21, T-HV-SUITE).
//
// WHY THIS IS AN AST WALK AND NOT A SEMGREP RULE. Both halves of the problem need
// something a pattern cannot supply:
//
//   FINDING CANDIDATES is structural, not textual. A regex for "a call whose arguments
//   contain a call" matches 845 places in this tree (measured: see the report). Almost all
//   are `abi.encodeWithSelector(...)` operands on continuation lines, which a line-oriented
//   pattern cannot tell apart from the statement that follows a cheatcode. The AST gives
//   statement order inside a Block for free, which is the actual predicate: "the next
//   statement after an armed cheatcode".
//
//   FILTERING BY VISIBILITY IS THE WHOLE JOB, and it is not expressible textually at all.
//   An INTERNAL call is a JUMP, not a message call, so it consumes no cheatcode. Eight of
//   the operator's ten hand-triaged candidates were false for exactly that reason
//   (`V2Ids.shortIdOf`, `Policy.launchDefaults`, `_pick` and the rest are `internal`).
//   Deciding internal-vs-external needs the callee's DECLARATION, which only solc's AST has,
//   via `referencedDeclaration`. Semgrep's Solidity support does not resolve declarations.
//
//   AND THE GATE WOULD BECOME NOISY. `.pre-commit-config.yaml:55` runs
//   `semgrep scan --config .semgrep/solidity.yml --error`, so `--error` is passed GLOBALLY:
//   any rule added to that file fails the commit on any hit, whatever severity the rule
//   declares. A rule that cannot resolve visibility would fail every commit on those eight
//   internal calls, and a gate that cries wolf is a gate that gets bypassed. So
//   `.semgrep/solidity.yml` is deliberately NOT touched by this row.
//
// `vm.startPrank` IS EXCLUDED, DELIBERATELY. It persists until `vm.stopPrank()`, so an inner
// call does not exhaust it -- the inner call runs pranked too, which may or may not be
// intended, but it is not THIS defect and folding it in would bury the single-use cases in
// noise. The operator's sweep excluded it for the same reason.
//
// INPUT: solc ASTs. Two ways to get them, and `--compile` is the one to prefer.
//
//   --compile (SELF-SUFFICIENT, SECONDS). Asks solc for the AST and NOTHING ELSE, through
//     standard-json with `outputSelection: {"*": {"": ["ast"]}}`. Requesting no bytecode means
//     solc runs the parser and the analyser and then STOPS: no code generation. That matters
//     for more than speed here -- `forge build` on this repo needs `via_ir = true` because
//     `script/Verify.s.sol:250` hits "Stack too deep", and stack-too-deep is a CODEGEN
//     failure. An AST-only request never reaches codegen, so it compiles that file without
//     via-IR and without the optimizer, in seconds rather than the many minutes a full
//     via-IR build of 352 files costs. `--skip` does not help: forge still compiles the file.
//
//   out/**/*.json from `forge build --ast`. Used when present and `--compile` is not passed.
//     Equivalent input, far slower to produce. Kept because it is the path a reviewer can
//     reproduce straight from the task contract with no extra tooling.
//
// EITHER WAY THE TOOL REFUSES RATHER THAN REPORTING A CLEAN TREE when it has no ASTs: "no
// ASTs" and "no findings" must never look the same. That is the defect class this row exists
// to find, so the finder must not be an instance of it.
//
// NEVER POINT THIS AT ANOTHER WORKTREE'S `out/`. Artifacts built from a different source state
// parse perfectly and describe a tree that is not the one under scan. A missing artifact that
// makes this tool exit 2 is the safe state; a stale one that makes it exit 0 is not.
//
// USAGE
//   node script/v2/cheatcode-scope.mjs --compile        # build ASTs with solc, then scan
//   node script/v2/cheatcode-scope.mjs                  # scan using out/ from forge build --ast
//   node script/v2/cheatcode-scope.mjs --json           # machine-readable
//   node script/v2/cheatcode-scope.mjs --include <re>   # limit to sources matching a regex
//   node script/v2/cheatcode-scope.mjs --out <dir>      # artifact dir (default: out)
//   node script/v2/cheatcode-scope.mjs --solc <path>    # solc binary (default: auto-detect 0.8.28)
// Exit 0 = no findings, 1 = findings, 2 = the tool could not run (missing ASTs, bad input).
// Exit 2 is NOT "clean": a checker that cannot see its subject must never report success.

import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, relative } from "node:path";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";

const SINGLE_USE_CHEATCODES = new Set([
  "prank",
  "expectRevert",
  "expectEmit",
  "expectCall",
]);

// A CALL TO `vm` IS NOT COUNTED, AND THIS IS A JUDGEMENT, NOT A MEASUREMENT. `vm` is a real
// contract at a fixed address, so `vm.parseJsonBytes(...)` inside an argument list IS a
// message call in EVM terms. Foundry's prank machinery special-cases the cheatcode address and
// does not let such a call consume a prank -- if it did, every `vm.toString()` between a prank
// and its call would break, which is not how this or any foundry repo behaves.
//
// I DID NOT VERIFY THAT BY EXECUTION. It rests on reading foundry's documented behaviour, not
// on a run, and it is recorded as a suspicion in the ledger. It changes exactly one live
// result: `test/v2/unit/FreezeV1.t.sol:112-114`, where `vm.prank(sender)` precedes
// `vm.parseJsonAddress(...).call(vm.parseJsonBytes(...))`. If foundry ever did let a cheatcode
// consume a prank, that batch would execute from the test contract rather than the Safe and
// the freeze fixture would be testing nothing. `--include-vm` surfaces it.
const VM_INNER = "vm-cheatcode";

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
};

const OUT_DIR = opt("--out", "out");
const AS_JSON = flag("--json");
const COMPILE = flag("--compile");
const SOLC = opt("--solc", null);
const INCLUDE_VM = flag("--include-vm");
const INCLUDE = opt("--include", null);
const includeRe = INCLUDE ? new RegExp(INCLUDE) : null;

/* ------------------------------------------------------- solc, the fast path */

// The pinned compiler. foundry.toml names the version; foundry keeps the binary under svm.
function solcBinary() {
  if (SOLC) return SOLC;
  let version = "0.8.28";
  try {
    const toml = readFileSync("foundry.toml", "utf8");
    const m = toml.match(/^\s*solc(?:_version)?\s*=\s*"([^"]+)"/m);
    if (m) version = m[1].replace(/^v/, "");
  } catch {
    /* fall through to the default */
  }
  const svm = join(homedir(), "Library/Application Support/svm", version, `solc-${version}`);
  if (existsSync(svm)) return svm;
  const svmLinux = join(homedir(), ".svm", version, `solc-${version}`);
  if (existsSync(svmLinux)) return svmLinux;
  return "solc"; // PATH, and it must match foundry.toml or the ASTs describe another dialect
}

function collectTestSources() {
  const out = [];
  for (const f of walkFiles("test", ".sol")) if (f.endsWith(".t.sol")) out.push(f);
  return out.sort();
}

function remappings() {
  const r = spawnSync("forge", ["remappings"], { encoding: "utf8" });
  if (r.status !== 0 || !r.stdout) return [];
  return r.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
}

// Ask solc for the AST and nothing else. No codegen means no stack-too-deep and no via-IR.
function compileAsts() {
  const bin = solcBinary();
  const entries = collectTestSources();
  if (entries.length === 0) {
    console.error("cheatcode-scope: no test/**/*.t.sol found. REFUSING.");
    process.exit(2);
  }
  const sources = {};
  for (const p of entries) sources[p] = { urls: [p] };
  const input = {
    language: "Solidity",
    sources,
    settings: { remappings: remappings(), outputSelection: { "*": { "": ["ast"] } } },
  };
  const res = spawnSync(bin, ["--standard-json", "--allow-paths", ".,lib,test,src"], {
    input: JSON.stringify(input),
    encoding: "utf8",
    maxBuffer: 1 << 30,
  });
  if (res.error || !res.stdout) {
    console.error(`cheatcode-scope: could not run solc at '${bin}': ${res.error || "no output"}`);
    process.exit(2);
  }
  let out;
  try {
    out = JSON.parse(res.stdout);
  } catch {
    console.error(`cheatcode-scope: solc at '${bin}' did not return JSON. REFUSING.`);
    process.exit(2);
  }
  const errors = (out.errors || []).filter((e) => e.severity === "error");
  if (errors.length) {
    console.error(`cheatcode-scope: solc reported ${errors.length} error(s); the ASTs are incomplete.`);
    for (const e of errors.slice(0, 5)) console.error("  " + (e.formattedMessage || e.message).split("\n")[0]);
    console.error("REFUSING: a partial AST would under-report.");
    process.exit(2);
  }
  const byPath = new Map();
  for (const [path, entry] of Object.entries(out.sources || {})) {
    if (entry && entry.ast) byPath.set(entry.ast.absolutePath || path, entry.ast);
  }
  return { byPath, artifacts: Object.keys(out.sources || {}).length, solc: bin };
}

/* ------------------------------------------------------------------ artifacts */

function* walkFiles(dir, ext = ".json") {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }
  for (const e of entries) {
    const p = join(dir, e);
    let st;
    try {
      st = statSync(p);
    } catch {
      continue;
    }
    if (st.isDirectory()) yield* walkFiles(p, ext);
    else if (e.endsWith(ext)) yield p;
  }
}

// One AST per source file. Artifacts repeat the same `ast` for every contract in a file, so
// key on absolutePath and keep the first.
function loadAsts(outDir) {
  const byPath = new Map();
  let artifacts = 0;
  for (const f of walkFiles(outDir)) {
    let j;
    try {
      j = JSON.parse(readFileSync(f, "utf8"));
    } catch {
      continue;
    }
    artifacts++;
    const ast = j.ast;
    if (!ast || !ast.absolutePath) continue;
    if (!byPath.has(ast.absolutePath)) byPath.set(ast.absolutePath, ast);
  }
  return { byPath, artifacts };
}

/* ------------------------------------------------------------------ ast utils */

function eachNode(node, visit) {
  if (!node || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (const n of node) eachNode(n, visit);
    return;
  }
  if (typeof node.nodeType === "string") visit(node);
  for (const k of Object.keys(node)) {
    if (k === "nodeType" || k === "src") continue;
    eachNode(node[k], visit);
  }
}

// id -> FunctionDefinition, across EVERY source, so a callee declared in src/ resolves from a
// call site in test/.
function declarationIndex(asts) {
  const byId = new Map();
  for (const ast of asts) {
    eachNode(ast, (n) => {
      if (n.nodeType === "FunctionDefinition" && typeof n.id === "number") byId.set(n.id, n);
      if (n.nodeType === "VariableDeclaration" && typeof n.id === "number" && n.stateVariable) {
        byId.set(n.id, n);
      }
    });
  }
  return byId;
}

function lineTable(absolutePath) {
  const candidates = [absolutePath, join(process.cwd(), absolutePath)];
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    const text = readFileSync(p, "utf8");
    const starts = [0];
    for (let i = 0; i < text.length; i++) if (text[i] === "\n") starts.push(i + 1);
    return { starts, text };
  }
  return null;
}

function lineOf(table, src) {
  if (!table) return { line: 0, text: "" };
  const offset = Number(String(src).split(":")[0]);
  const { starts, text } = table;
  let lo = 0;
  let hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= offset) lo = mid;
    else hi = mid - 1;
  }
  const end = text.indexOf("\n", starts[lo]);
  return { line: lo + 1, text: text.slice(starts[lo], end === -1 ? undefined : end).trim() };
}

/* ------------------------------------------------- classify one call expression */

function isVmMember(expr) {
  return (
    expr &&
    expr.nodeType === "MemberAccess" &&
    expr.expression &&
    expr.expression.nodeType === "Identifier" &&
    expr.expression.name === "vm"
  );
}

// Which single-use cheatcode this statement arms, or null.
function armedCheatcode(stmt) {
  if (!stmt || stmt.nodeType !== "ExpressionStatement") return null;
  const call = stmt.expression;
  if (!call || call.nodeType !== "FunctionCall") return null;
  if (!isVmMember(call.expression)) return null;
  const name = call.expression.memberName;
  return SINGLE_USE_CHEATCODES.has(name) ? name : null;
}

function isStartPrank(stmt) {
  if (!stmt || stmt.nodeType !== "ExpressionStatement") return false;
  const call = stmt.expression;
  if (!call || call.nodeType !== "FunctionCall") return false;
  return isVmMember(call.expression) && call.expression.memberName === "startPrank";
}

// Does this FunctionCall reach a message call? Returns a category, or null when it does not.
function callCategory(call, byId) {
  if (!call || call.nodeType !== "FunctionCall") return null;

  // `IERC20(addr)` and `Struct({...})` are not calls at all.
  if (call.kind === "typeConversion" || call.kind === "structConstructorCall") return null;

  const expr = call.expression;
  if (!expr) return null;

  // `new Thing(...)` is a creation message call and consumes a prank. `new Thing[](n)` is an
  // ARRAY ALLOCATION -- memory, no call, nothing consumed. Distinguished by the typeName.
  if (expr.nodeType === "NewExpression") {
    const tn = expr.typeName;
    if (tn && (tn.nodeType === "ArrayTypeName" || tn.nodeType === "ElementaryTypeName")) return null;
    return "new";
  }

  if (isVmMember(expr)) return VM_INNER;

  // Low-level: `addr.call(...)`, `.staticcall(...)`, `.delegatecall(...)`.
  if (expr.nodeType === "MemberAccess" && ["call", "staticcall", "delegatecall"].includes(expr.memberName)) {
    return "low-level";
  }

  const refId = expr.referencedDeclaration;
  if (typeof refId !== "number") return null; // builtin: abi.*, keccak256, type(), etc.

  const decl = byId.get(refId);
  if (!decl) return null;

  // A public state variable's generated getter, reached through a contract instance, is an
  // external call.
  if (decl.nodeType === "VariableDeclaration") {
    return decl.visibility === "public" && expr.nodeType === "MemberAccess" ? "public-getter" : null;
  }

  if (decl.nodeType !== "FunctionDefinition") return null;

  // THE FILTER THIS TOOL EXISTS FOR. An internal or private call is a JUMP: no message call,
  // no cheatcode consumed. This is the line that clears the operator's eight false positives.
  if (decl.visibility === "internal" || decl.visibility === "private") return null;

  // `this.f()` / `other.f()` on a public function is a message call. A bare `f()` naming a
  // public function in the SAME contract is an internal jump.
  if (decl.visibility === "public" && expr.nodeType !== "MemberAccess") return null;

  return decl.visibility === "external" ? "external" : "public";
}

// Every message call inside this expression's ARGUMENTS, in source order.
function messageCallsInArguments(call, byId) {
  const found = [];
  for (const arg of call.arguments || []) {
    eachNode(arg, (n) => {
      if (n.nodeType !== "FunctionCall") return;
      const cat = callCategory(n, byId);
      if (!cat) return;
      if (cat === VM_INNER && !INCLUDE_VM) return;
      found.push({ node: n, category: cat });
    });
  }
  found.sort((a, b) => Number(String(a.node.src).split(":")[0]) - Number(String(b.node.src).split(":")[0]));
  return found;
}

// The outer call a statement performs, if any.
function outerCallOf(stmt) {
  if (!stmt) return null;
  if (stmt.nodeType === "ExpressionStatement") {
    const e = stmt.expression;
    if (!e) return null;
    if (e.nodeType === "FunctionCall") return e;
    if (e.nodeType === "Assignment" && e.rightHandSide && e.rightHandSide.nodeType === "FunctionCall") {
      return e.rightHandSide;
    }
    return null;
  }
  if (stmt.nodeType === "VariableDeclarationStatement") {
    const v = stmt.initialValue;
    return v && v.nodeType === "FunctionCall" ? v : null;
  }
  return null;
}

function describeCall(node) {
  const e = node.expression;
  if (!e) return "<call>";
  if (e.nodeType === "MemberAccess") {
    const base = e.expression;
    const baseName =
      base && base.nodeType === "Identifier"
        ? base.name
        : base && base.nodeType === "MemberAccess"
          ? base.memberName
          : base && base.nodeType === "FunctionCall"
            ? "<expr>"
            : "<expr>";
    return `${baseName}.${e.memberName}()`;
  }
  if (e.nodeType === "Identifier") return `${e.name}()`;
  if (e.nodeType === "NewExpression") return "new ...()";
  return "<call>";
}

/* ------------------------------------------------------------------- the walk */

function scanBlock(block, ctx) {
  const stmts = block.statements || [];
  let armed = [];
  for (const stmt of stmts) {
    const cheat = armedCheatcode(stmt);
    if (cheat) {
      armed.push({ name: cheat, src: stmt.src });
      continue;
    }
    if (isStartPrank(stmt)) {
      armed = []; // persistent; not this defect
      continue;
    }
    if (armed.length === 0) continue;

    const outer = outerCallOf(stmt);
    if (!outer) {
      // Not a call, so nothing consumed it here; the cheatcode stays armed for a later
      // statement in the same block.
      continue;
    }

    // THE PREDICATE, AND IT IS NOT "an argument contains a call". A cheatcode binds to the
    // next MESSAGE CALL in evaluation order. If the outer call is INTERNAL -- `assertEq(...)`,
    // `assertApproxEqAbs(...)`, a local helper -- then it consumes nothing, and the external
    // call inside its arguments is exactly what the author aimed the cheatcode at. That is
    // correct, idiomatic forge code and reporting it would bury the real defect: measured on
    // this tree, dropping this condition turns 2 findings into dozens.
    //
    // The defect is the outer call being a message call TOO: the author aimed the cheatcode at
    // the outer call, and an argument spent it first.
    const outerCategory = callCategory(outer, ctx.byId);
    const inner = outerCategory ? messageCallsInArguments(outer, ctx.byId) : [];
    if (inner.length > 0) {
      const first = inner[0];
      const at = lineOf(ctx.table, first.node.src);
      const stmtAt = lineOf(ctx.table, stmt.src);
      ctx.findings.push({
        file: ctx.file,
        line: stmtAt.line,
        statement: stmtAt.text,
        eaten: armed.map((a) => `vm.${a.name}`),
        outerCall: describeCall(outer),
        outerCategory,
        innerCall: describeCall(first.node),
        innerCallLine: at.line,
        innerCategory: first.category,
        additionalInnerCalls: inner.slice(1).map((i) => describeCall(i.node)),
      });
    }
    armed = [];
  }
}

function scan(asts, byId, includeRe) {
  const findings = [];
  const scannedFiles = [];
  for (const [absPath, ast] of asts) {
    if (!absPath.endsWith(".t.sol")) continue;
    if (!absPath.startsWith("test/")) continue;
    if (includeRe && !includeRe.test(absPath)) continue;
    scannedFiles.push(absPath);
    const table = lineTable(absPath);
    const ctx = { file: absPath, table, findings, byId };
    eachNode(ast, (n) => {
      if (n.nodeType === "Block") scanBlock(n, ctx);
    });
  }
  findings.sort((a, b) => (a.file === b.file ? a.line - b.line : a.file < b.file ? -1 : 1));
  return { findings, scannedFiles };
}

/* ------------------------------------------------------------------------ main */

function main() {
  if (COMPILE) {
    const { byPath, artifacts, solc } = compileAsts();
    if (byPath.size === 0) {
      console.error("cheatcode-scope: solc returned no ASTs. REFUSING.");
      process.exit(2);
    }
    return report(byPath, byPath.size, `solc ${solc} (${artifacts} source(s) analysed, AST only)`);
  }
  if (!existsSync(OUT_DIR)) {
    console.error(
      `cheatcode-scope: no artifact directory at '${OUT_DIR}'. Run \`forge build --ast\` first.\n` +
        `REFUSING rather than reporting a clean tree: a scan with no ASTs is not a scan.`,
    );
    process.exit(2);
  }

  const { byPath, artifacts } = loadAsts(OUT_DIR);
  const withAst = byPath.size;
  if (withAst === 0) {
    console.error(
      `cheatcode-scope: read ${artifacts} artifact(s) under '${OUT_DIR}' and not one carried an \`ast\`.\n` +
        `Run \`forge build --ast\` (plain \`forge build\` omits the AST). REFUSING: exit 2 is not 'clean'.`,
    );
    process.exit(2);
  }

  return report(byPath, withAst, `${OUT_DIR}/ (forge build --ast)`);
}

function report(byPath, withAst, sourceLabel) {
  const byId = declarationIndex(byPath.values());
  const { findings, scannedFiles } = scan(byPath, byId, includeRe);

  if (AS_JSON) {
    console.log(
      JSON.stringify(
        { scannedFiles: scannedFiles.length, sourcesWithAst: withAst, findings },
        null,
        2,
      ),
    );
  } else {
    console.log(`cheatcode-scope: ${scannedFiles.length} test source(s) scanned from ${withAst} AST(s).`);
    console.log(`  ast source: ${sourceLabel}`);
    if (findings.length === 0) {
      console.log("no eaten cheatcodes found.");
    } else {
      for (const f of findings) {
        console.log("");
        console.log(`${f.file}:${f.line}`);
        console.log(`  ${f.statement}`);
        console.log(`  EATEN: ${f.eaten.join(" + ")}`);
        console.log(
          `  by ${f.innerCall} [${f.innerCategory}] at line ${f.innerCallLine}, ` +
            `evaluated before ${f.outerCall}`,
        );
        if (f.additionalInnerCalls.length) {
          console.log(`  (also in the argument list: ${f.additionalInnerCalls.join(", ")})`);
        }
      }
      console.log("");
      console.log(`${findings.length} finding(s).`);
    }
  }

  process.exit(findings.length > 0 ? 1 : 0);
}

main();
