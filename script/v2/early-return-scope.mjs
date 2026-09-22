#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// T-589. FIND EVERY TEST BODY THAT RETURNS EARLY AND REPORTS PASSED.
//
// A Foundry test that `return`s before its assertions does not fail and does not skip. It PASSES,
// having asserted nothing, and the result line is identical to a real pass. The only trace is the
// gas column, which nobody reads. That is the shape T-564 fixed seven times in
// test/fork/ForkLive.t.sol, and it is the defect T-CT5-01 was opened for one layer up:
//
//     function test_fork_assignedWeekSettlesOnLiveClear() public onlyFork {
//         if (!_dealBoth()) return;          // <- PASSED whenever the precondition is missing
//         ...
//
// The honest form reports SKIPPED instead:
//
//         if (!_dealBoth()) { vm.skip(true); return; }
//
// WHY THIS IS AN AST WALK AND NOT A GREP. A naive regex over the sixteen fork suites at 5e962fe0 found
// TWO sites and ZERO in ForkLive.t.sol, which had seven before T-564 landed. It misses `catch { ...;
// return; }`, it misses a return several lines below its guard, and it cannot tell a return in a test
// body from one in a helper, a modifier or setUp, which are correct. What decides a finding is
// structural: WHICH FUNCTION the return sits in, and WHETHER a `vm.skip(true)` precedes it on the
// same control-flow path. solc's AST gives both. A pattern gives neither.
//
// THE RULE, and it is deliberately strict:
//
//   A `return` inside a Foundry test function (public/external, named test*, invariant*,
//   statefulFuzz* or table*) is a FINDING unless a statement `vm.skip(true)` DOMINATES it: that
//   statement sits earlier in a Block that encloses the return. A skip in a SIBLING branch does not
//   dominate. A skip inside a helper does not dominate: the AST cannot see into the helper's
//   control flow, so this tool does not pretend to. A `vm.skip(cond)` with anything but the literal
//   `true` does not dominate, because when `cond` is false the next line still returns PASSED.
//
//   Helpers, setUp and modifiers are NOT test bodies. Their returns are not test-body findings.
//   ONE deliberate extension, stated rather than smuggled: a MODIFIER that returns before its `_`
//   without a dominating `vm.skip(true)` skips the whole body of every test it decorates, so each
//   such modifier that at least one test function actually uses is reported under its own class,
//   `modifier-bail`. The correct `onlyFork` (vm.skip(true) then return, ForkLive.t.sol) is not.
//
// EVERY FINDING IS CLASSIFIED, so the report can be triaged without re-reading each site. Every class
// counts toward exit 1; the class says what kind of bail it is, not whether it matters:
//
//   precondition-bail      a concrete test bails with no assertion before it on the path: the whole
//                          test reports PASSED having asserted nothing. The T-564 shape.
//   case-discard           the same bail in a fuzz test (it takes parameters) or an invariant: one
//                          input or one run passes vacuously, not necessarily the whole test. Often a
//                          deliberate vacuous-truth guard; vm.assume would say so to the runner.
//   post-assertion-return  an assertion already ran on the path, and the return skips what follows
//                          it. That is not "safe": the skipped part is usually the subject.
//   unconditional-return   a return at the top level of the body, outside every branch.
//   assembly-halt          `return(...)` or `stop()` in inline assembly inside a test body.
//   modifier-bail          see above.
//
// THE FINDER REFUSES TO BE AN INSTANCE OF WHAT IT FINDS. "No ASTs" and "no findings" must never look
// the same, so each of these exits 2 rather than 0:
//   - solc missing, not JSON, or reporting any error (a partial AST under-reports);
//   - a test source on disk with no AST, or an out/ artifact whose AST length disagrees with the file;
//   - no test sources at all; an unknown flag (a typo must not become a silent default);
//   - THE SELF-CHECK: for every function and modifier body, the walker's count of return statements
//     must equal a LEXICAL count of the `return` keyword in the same byte range, with comments and
//     string literals blanked. A walker that silently stopped descending into some node type would
//     otherwise report a clean tree; this makes it report that it could not see.
//
// OFFSETS ARE BYTES. solc's `src` is a UTF-8 byte offset, and 54 of the 162 test sources at this row's
// base carry non-ASCII (mostly em dashes in comments). Indexing a JS string with it drifts one line per
// multi-byte character above the site, so every file here is read as a Buffer.
//
// INPUT, as in script/v2/cheatcode-scope.mjs, whose shape this follows:
//   default (--compile)  ask solc for the AST and nothing else: standard-json with
//                        outputSelection {"*": {"": ["ast"]}}. No codegen, so no via-IR and no
//                        stack-too-deep; seconds, not the many minutes of a full build.
//   --out <dir>          read ASTs from forge artifacts (`forge build --ast`). Every test source must
//                        have one and its length must match the file on disk, or exit 2.
//
// NEVER POINT --out AT ANOTHER WORKTREE'S out/. Artifacts built from a different source state parse
// perfectly and describe a tree that is not the one under scan.
//
// USAGE
//   node script/v2/early-return-scope.mjs                   # compile ASTs with solc, then scan test/
//   node script/v2/early-return-scope.mjs --json            # machine-readable, permitted returns included
//   node script/v2/early-return-scope.mjs --permitted       # also list every return seen and cleared, and why
//   node script/v2/early-return-scope.mjs --include <re>    # limit to test sources matching a regex
//   node script/v2/early-return-scope.mjs --root <dir>      # scan another checkout (e.g. a git archive)
//   node script/v2/early-return-scope.mjs --out <dir>       # use forge build --ast artifacts
//   node script/v2/early-return-scope.mjs --solc <path>     # solc binary (default: foundry.toml's)
// Exit 0 = no findings, 1 = findings (fully reported), 2 = the tool could not complete the scan.

import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

export const EXIT = Object.freeze({ CLEAN: 0, FINDINGS: 1, UNABLE: 2 });

// Foundry's own prefixes: `test` (including testFuzz/testFail), `invariant` and its alias
// `statefulFuzz`, and `table` for table tests. `fixture*`, `setUp` and `afterInvariant` are not tests.
const TEST_NAME = /^(test|invariant|statefulFuzz|table)/;

export class UnableError extends Error {}

/* ------------------------------------------------------------------ files and bytes */

export function* walkFiles(dir, ext) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }
  for (const e of entries.sort()) {
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

// Every .sol under test/, not only *.t.sol: an abstract base that declares test functions may live in
// a plain .sol file, and a handler must at least be seen to be ruled out.
export function collectTestSources(includeRe) {
  const all = [...walkFiles("test", ".sol")].sort();
  return { all, selected: includeRe ? all.filter((p) => includeRe.test(p)) : all };
}

function lineStarts(buf) {
  const starts = [0];
  for (let i = 0; i < buf.length; i++) if (buf[i] === 0x0a) starts.push(i + 1);
  return starts;
}

function parseSrc(src) {
  const [o, l] = String(src).split(":").map(Number);
  return { offset: o, length: l };
}

export function lineOf(buf, starts, offset) {
  let lo = 0;
  let hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= offset) lo = mid;
    else hi = mid - 1;
  }
  let end = buf.indexOf(0x0a, starts[lo]);
  if (end === -1) end = buf.length;
  return { line: lo + 1, text: buf.subarray(starts[lo], end).toString("utf8").trim() };
}

function textOf(buf, src) {
  const { offset, length } = parseSrc(src);
  return buf.subarray(offset, offset + length).toString("utf8").replace(/\s+/g, " ").trim();
}

// Blank comments and string literals to spaces, byte for byte, keeping offsets and newlines. Every
// delimiter involved is ASCII and every byte of a multi-byte UTF-8 character is >= 0x80, so a
// byte-wise scan cannot split a character into a false delimiter.
export function blankCommentsAndStrings(buf) {
  const out = Buffer.from(buf);
  const n = out.length;
  let i = 0;
  const blank = (a, b) => {
    for (let k = a; k < b && k < n; k++) if (out[k] !== 0x0a) out[k] = 0x20;
  };
  while (i < n) {
    const c = out[i];
    if (c === 0x2f && out[i + 1] === 0x2f) {
      let j = i;
      while (j < n && out[j] !== 0x0a) j++;
      blank(i, j);
      i = j;
    } else if (c === 0x2f && out[i + 1] === 0x2a) {
      let j = i + 2;
      while (j < n && !(out[j] === 0x2a && out[j + 1] === 0x2f)) j++;
      blank(i, j + 2);
      i = j + 2;
    } else if (c === 0x22 || c === 0x27) {
      let j = i + 1;
      while (j < n && out[j] !== c && out[j] !== 0x0a) j += out[j] === 0x5c ? 2 : 1;
      blank(i, j + 1);
      i = j + 1;
    } else {
      i++;
    }
  }
  return out;
}

const isWordByte = (b) =>
  (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || b === 0x5f || b === 0x24;

// Occurrences of the keyword `return` (not `returns`) in [offset, offset + length) of a blanked buffer.
export function lexicalReturnCount(blanked, offset, length) {
  const word = Buffer.from("return");
  let count = 0;
  let at = blanked.indexOf(word, offset);
  while (at !== -1 && at + word.length <= offset + length) {
    const before = at === 0 ? 0x20 : blanked[at - 1];
    const after = blanked[at + word.length];
    if (!isWordByte(before) && !isWordByte(after ?? 0x20)) count++;
    at = blanked.indexOf(word, at + 1);
  }
  return count;
}

/* ------------------------------------------------------------------ the AST */

// Visit every AST node below `node` with the path that leads to it: one {node, key, index} entry per
// edge, so a visitor can ask "which Block encloses me, and at which statement".
function walk(node, path, visit) {
  if (!node || typeof node !== "object") return;
  if (typeof node.nodeType === "string") visit(node, path);
  for (const key of Object.keys(node)) {
    if (key === "nodeType" || key === "src" || key === "typeDescriptions") continue;
    const child = node[key];
    if (Array.isArray(child)) {
      child.forEach((c, i) => {
        if (c && typeof c === "object") walk(c, [...path, { node, key, index: i }], visit);
      });
    } else if (child && typeof child === "object") {
      walk(child, [...path, { node, key, index: -1 }], visit);
    }
  }
}

function each(node, visit) {
  walk(node, [], (n) => visit(n));
}

function calleeName(call) {
  const e = call && call.expression;
  if (!e) return null;
  if (e.nodeType === "Identifier") return e.name;
  if (e.nodeType === "MemberAccess") return e.memberName;
  return null;
}

// `vm` by name, or anything typed as forge-std's Vm, so an aliased cheatcode handle is still seen.
function isVmReceiver(expr) {
  if (!expr) return false;
  if (expr.nodeType === "Identifier" && expr.name === "vm") return true;
  const t = expr.typeDescriptions && expr.typeDescriptions.typeString;
  return t === "contract Vm";
}

export function isSkipTrue(stmt) {
  if (!stmt || stmt.nodeType !== "ExpressionStatement") return false;
  const call = stmt.expression;
  if (!call || call.nodeType !== "FunctionCall") return false;
  const e = call.expression;
  if (!e || e.nodeType !== "MemberAccess" || e.memberName !== "skip" || !isVmReceiver(e.expression)) return false;
  const first = (call.arguments || [])[0];
  return !!first && first.nodeType === "Literal" && first.kind === "bool" && first.value === "true";
}

// A call that fails the test when its condition does not hold, or arms one that will.
function isAssertionCall(call) {
  const name = calleeName(call);
  if (!name) return false;
  if (/^assert/.test(name) || name === "fail" || name === "require") return true;
  const e = call.expression;
  return e.nodeType === "MemberAccess" && /^expect/.test(name) && isVmReceiver(e.expression);
}

function containsAssertion(node) {
  let found = false;
  each(node, (n) => {
    if (!found && n.nodeType === "FunctionCall" && isAssertionCall(n)) found = true;
  });
  return found;
}

const BLOCKS = new Set(["Block", "UncheckedBlock"]);
const LOOPS = new Set(["ForStatement", "WhileStatement", "DoWhileStatement"]);

// Everything this tool says about one return, read off the path from the function body down to it.
function contextOf(path) {
  let dominated = false;
  let assertedBefore = false;
  let terminal = true;
  let loop = false;
  let where = null;
  let guardNode = null;

  for (let d = path.length - 1; d >= 0; d--) {
    const { node, key, index } = path[d];
    if (BLOCKS.has(node.nodeType) && key === "statements") {
      const before = node.statements.slice(0, index);
      if (before.some(isSkipTrue)) dominated = true;
      if (before.some(containsAssertion)) assertedBefore = true;
      if (index !== node.statements.length - 1) terminal = false;
    }
    if (LOOPS.has(node.nodeType) && key === "body") {
      loop = true;
      where = where || "loop";
    }
    if (node.nodeType === "IfStatement" && (key === "trueBody" || key === "falseBody")) {
      if (!where) {
        const inline = d === path.length - 1;
        where = key === "falseBody" ? (inline ? "else-inline" : "else-block") : inline ? "if-inline" : "if-block";
        guardNode = node.condition;
      }
    }
    if (node.nodeType === "TryStatement" && key === "clauses") {
      if (!where) where = index === 0 ? "try-success" : "catch";
    }
  }
  if (loop) terminal = false;
  return { dominated, assertedBefore, terminal, loop, where: where || "body", guardNode };
}

function classify(ctx, perCase) {
  if (ctx.where === "body") return "unconditional-return";
  if (ctx.assertedBefore) return "post-assertion-return";
  if (perCase) return "case-discard";
  return "precondition-bail";
}

// A fuzz test (it takes parameters) or an invariant runs many cases; a bail discards one of them.
function isPerCase(fn) {
  const params = (fn.parameters && fn.parameters.parameters) || [];
  return params.length > 0 || /^(invariant|statefulFuzz)/.test(fn.name);
}

function isTestFunction(fn) {
  return (
    fn.nodeType === "FunctionDefinition" &&
    fn.kind === "function" &&
    !!fn.body &&
    (fn.visibility === "public" || fn.visibility === "external") &&
    TEST_NAME.test(fn.name)
  );
}

function isYulHalt(n) {
  return n.nodeType === "YulFunctionCall" && n.functionName && ["return", "stop"].includes(n.functionName.name);
}

// Walk one function or modifier body. Returns every return with its context, and the self-check pair.
function returnsIn(body) {
  const sites = [];
  let yulReturns = 0;
  walk(body, [], (n, path) => {
    if (n.nodeType === "Return") sites.push({ node: n, ctx: contextOf(path), yul: false });
    else if (isYulHalt(n)) {
      if (n.functionName.name === "return") yulReturns++;
      sites.push({ node: n, ctx: contextOf(path), yul: true });
    }
  });
  const solidityReturns = sites.filter((s) => !s.yul).length;
  return { sites, walkerReturnCount: solidityReturns + yulReturns };
}

/* ------------------------------------------------------------------ one source */

// Analyse one source unit. `buf` is the file's bytes; the AST's offsets index into it.
export function analyzeSource(ast, buf, file) {
  if (!ast || ast.nodeType !== "SourceUnit") throw new UnableError(`${file}: AST is not a SourceUnit`);
  // A SourceUnit's range starts at its first token (after any leading comment) and runs to the end of
  // the file. An end that is not the file's length means the AST was built from another version of it.
  const unit = parseSrc(ast.src);
  if (unit.offset + unit.length !== buf.length) {
    throw new UnableError(
      `${file}: AST ends at byte ${unit.offset + unit.length} but the file has ${buf.length}; ` +
        `the AST describes another version of it`,
    );
  }
  const starts = lineStarts(buf);
  const blanked = blankCommentsAndStrings(buf);
  const findings = [];
  const modifierBails = [];
  const permitted = [];
  const tests = [];
  let returnsSeen = 0;

  const at = (node) => lineOf(buf, starts, parseSrc(node.src).offset);
  const guardText = (ctx) => (ctx.guardNode ? textOf(buf, ctx.guardNode.src).slice(0, 160) : null);

  // Walk one body, then hold the walk to the lexical count of `return` in the same bytes.
  const walkBody = (label, body) => {
    const { sites, walkerReturnCount } = returnsIn(body);
    const { offset, length } = parseSrc(body.src);
    const lexical = lexicalReturnCount(blanked, offset, length);
    if (lexical !== walkerReturnCount) {
      throw new UnableError(
        `${file}:${lineOf(buf, starts, offset).line} ${label}: the AST walk saw ${walkerReturnCount} return(s) ` +
          `where the source has ${lexical}. The walker is blind to some construct here; refusing rather ` +
          `than under-reporting.`,
      );
    }
    returnsSeen += walkerReturnCount;
    return sites;
  };
  const permit = (s, fn, reason) => permitted.push({ file, line: at(s.node).line, function: fn, reason });

  for (const contract of ast.nodes || []) {
    if (contract.nodeType !== "ContractDefinition") continue;
    for (const member of contract.nodes || []) {
      const label = `${contract.name}.${member.name || member.kind}`;

      if (member.nodeType === "ModifierDefinition" && member.body) {
        const sites = walkBody(`modifier ${label}`, member.body);
        // A return AFTER the last `_` cannot skip the body the modifier wraps.
        let lastPlaceholder = -1;
        each(member.body, (n) => {
          if (n.nodeType === "PlaceholderStatement") lastPlaceholder = Math.max(lastPlaceholder, parseSrc(n.src).offset);
        });
        for (const s of sites) {
          if (s.ctx.dominated) permit(s, label, "modifier: vm.skip(true) dominates");
          else if (parseSrc(s.node.src).offset > lastPlaceholder) permit(s, label, "modifier: after the last _");
          else {
            modifierBails.push({
              kind: "modifier",
              file,
              line: at(s.node).line,
              function: label,
              modifierId: member.id,
              class: "modifier-bail",
              where: s.yul ? "assembly" : s.ctx.where,
              guard: guardText(s.ctx),
              assertedBefore: s.ctx.assertedBefore,
              terminal: false,
              statement: at(s.node).text,
            });
          }
        }
        continue;
      }

      if (member.nodeType !== "FunctionDefinition" || !member.body) continue;

      if (!isTestFunction(member)) {
        // Walked all the same: the self-check then covers every body in the file, and each return is
        // listed as permitted with the reason, so a negative control reads "seen and cleared", never
        // merely "absent".
        const reason = member.name === "setUp" ? "setUp is not a test body" : "not a test function";
        for (const s of walkBody(`function ${label}`, member.body)) permit(s, label, reason);
        continue;
      }

      const perCase = isPerCase(member);
      tests.push({
        name: label,
        file,
        modifierIds: (member.modifiers || [])
          .map((m) => m.modifierName && m.modifierName.referencedDeclaration)
          .filter((x) => typeof x === "number"),
      });
      for (const s of walkBody(`test ${label}`, member.body)) {
        if (s.ctx.dominated) {
          permit(s, label, "vm.skip(true) dominates");
          continue;
        }
        findings.push({
          kind: "test-body",
          file,
          line: at(s.node).line,
          function: label,
          class: s.yul ? "assembly-halt" : classify(s.ctx, perCase),
          where: s.yul ? "assembly" : s.ctx.where,
          // `where` names the NEAREST enclosing construct; a return under an `if` inside a loop reads
          // `if-inline` here and `inLoop: true`, so a loop-guarded bail is still visible as one.
          inLoop: s.ctx.loop,
          guard: guardText(s.ctx),
          assertedBefore: s.ctx.assertedBefore,
          terminal: s.ctx.terminal,
          statement: at(s.node).text,
        });
      }
    }
  }
  return { findings, modifierBails, permitted, tests, returnsSeen };
}

/* ------------------------------------------------------------------ the tree */

// byPath: Map(path -> AST). expected: the test sources that MUST be covered. read: path -> Buffer.
export function scanAsts(byPath, expected, read = (p) => readFileSync(p)) {
  const missing = expected.filter((p) => !byPath.has(p));
  if (missing.length) {
    throw new UnableError(
      `${missing.length} test source(s) have no AST, e.g. ${missing.slice(0, 3).join(", ")}. ` +
        `A partial AST would under-report.`,
    );
  }
  const findings = [];
  const modifierBails = [];
  const permitted = [];
  const tests = [];
  let returnsSeen = 0;
  for (const file of expected) {
    const r = analyzeSource(byPath.get(file), read(file), file);
    findings.push(...r.findings);
    modifierBails.push(...r.modifierBails);
    permitted.push(...r.permitted);
    tests.push(...r.tests);
    returnsSeen += r.returnsSeen;
  }
  // A modifier bail matters only where a test function wears the modifier. The index spans every
  // scanned source, so a modifier declared in a base contract resolves from a child's test.
  const usedBy = new Map();
  for (const t of tests) for (const id of t.modifierIds) usedBy.set(id, (usedBy.get(id) || 0) + 1);
  for (const m of modifierBails) {
    const { modifierId, ...rest } = m;
    const uses = usedBy.get(modifierId) || 0;
    if (uses === 0) permitted.push({ file: m.file, line: m.line, function: m.function, reason: "modifier: no test wears it" });
    else findings.push({ ...rest, testsAffected: uses });
  }
  const order = (a, b) => (a.file === b.file ? a.line - b.line : a.file < b.file ? -1 : 1);
  return {
    findings: findings.sort(order),
    permitted: permitted.sort(order),
    testFunctions: tests.length,
    returnsSeen,
    scannedFiles: expected.length,
  };
}

/* ------------------------------------------------------------------ solc */

export function solcBinary(explicit) {
  if (explicit) return explicit;
  let version = "0.8.28";
  try {
    const toml = readFileSync("foundry.toml", "utf8");
    const m = toml.match(/^\s*solc(?:_version)?\s*=\s*"([^"]+)"/m);
    if (m) version = m[1].replace(/^v/, "");
  } catch {
    /* no foundry.toml: the default stands */
  }
  const candidates = [
    join(homedir(), "Library/Application Support/svm", version, `solc-${version}`),
    join(homedir(), ".svm", version, `solc-${version}`),
  ];
  for (const c of candidates) if (existsSync(c)) return c;
  return "solc";
}

function remappings() {
  if (!existsSync("foundry.toml")) return [];
  const r = spawnSync("forge", ["remappings"], { encoding: "utf8" });
  if (r.status !== 0 || !r.stdout) return [];
  return r.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
}

// AST only: solc parses and analyses, then stops before codegen.
export function compileAsts(entries, solc) {
  const sources = {};
  for (const p of entries) sources[p] = { urls: [p] };
  const input = {
    language: "Solidity",
    sources,
    settings: { remappings: remappings(), outputSelection: { "*": { "": ["ast"] } } },
  };
  const res = spawnSync(solc, ["--standard-json", "--allow-paths", ".,lib,test,src"], {
    input: JSON.stringify(input),
    encoding: "utf8",
    maxBuffer: 1 << 30,
  });
  if (res.error || !res.stdout) throw new UnableError(`could not run solc at '${solc}': ${res.error || "no output"}`);
  let out;
  try {
    out = JSON.parse(res.stdout);
  } catch {
    throw new UnableError(`solc at '${solc}' did not return JSON`);
  }
  const errors = (out.errors || []).filter((e) => e.severity === "error");
  if (errors.length) {
    const first = errors
      .slice(0, 5)
      .map((e) => "  " + (e.formattedMessage || e.message).split("\n")[0])
      .join("\n");
    throw new UnableError(`solc reported ${errors.length} error(s); the ASTs are incomplete.\n${first}`);
  }
  const byPath = new Map();
  for (const [path, entry] of Object.entries(out.sources || {})) {
    if (entry && entry.ast) byPath.set(entry.ast.absolutePath || path, entry.ast);
  }
  return byPath;
}

// One AST per source file from forge artifacts. Artifacts repeat the same `ast` for every contract in
// a file, so key on absolutePath and keep the first.
export function loadArtifactAsts(outDir) {
  if (!existsSync(outDir)) throw new UnableError(`no artifact directory at '${outDir}'. Run \`forge build --ast\`.`);
  const byPath = new Map();
  let artifacts = 0;
  for (const f of walkFiles(outDir, ".json")) {
    let j;
    try {
      j = JSON.parse(readFileSync(f, "utf8"));
    } catch {
      continue;
    }
    artifacts++;
    const ast = j.ast;
    if (ast && ast.absolutePath && !byPath.has(ast.absolutePath)) byPath.set(ast.absolutePath, ast);
  }
  if (byPath.size === 0) {
    throw new UnableError(`read ${artifacts} artifact(s) under '${outDir}' and not one carried an \`ast\` (forge build --ast).`);
  }
  return byPath;
}

/* ------------------------------------------------------------------ cli */

const FLAGS_WITH_VALUE = new Set(["--include", "--root", "--out", "--solc"]);
const FLAGS = new Set(["--json", "--compile", "--permitted"]);

export function parseArgs(argv) {
  const opts = { json: false, permitted: false, include: null, root: null, out: null, solc: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (FLAGS.has(a)) {
      if (a === "--json") opts.json = true;
      if (a === "--permitted") opts.permitted = true;
      continue;
    }
    if (FLAGS_WITH_VALUE.has(a)) {
      const v = argv[i + 1];
      if (v === undefined || v.startsWith("--")) throw new UnableError(`${a} needs a value`);
      opts[a.slice(2)] = v;
      i++;
      continue;
    }
    throw new UnableError(`unknown argument '${a}'`);
  }
  return opts;
}

function describe(f) {
  const bits = [`class: ${f.class}`, `where: ${f.where}${f.inLoop ? " (in loop)" : ""}`];
  if (f.guard) bits.push(`guard: ${f.guard}`);
  bits.push(`asserted-before: ${f.assertedBefore ? "yes" : "no"}`);
  if (f.kind === "modifier") bits.push(`tests wearing it: ${f.testsAffected}`);
  return bits.join("   ");
}

export function run(argv) {
  const opts = parseArgs(argv);
  if (opts.root) process.chdir(resolve(opts.root));
  const includeRe = opts.include ? new RegExp(opts.include) : null;
  const { all, selected } = collectTestSources(includeRe);
  if (all.length === 0) throw new UnableError(`no test/**/*.sol under ${process.cwd()}`);
  if (selected.length === 0) throw new UnableError(`--include '${opts.include}' matches none of ${all.length} test sources`);

  let byPath;
  let astSource;
  if (opts.out) {
    byPath = loadArtifactAsts(opts.out);
    astSource = `${opts.out}/ (forge build --ast)`;
  } else {
    const solc = solcBinary(opts.solc);
    byPath = compileAsts(selected, solc);
    astSource = `solc ${solc} (${byPath.size} source(s) analysed, AST only)`;
  }
  const result = scanAsts(byPath, selected);
  const limited = includeRe ? `LIMITED by --include ${opts.include}: ${selected.length} of ${all.length} test sources` : null;

  if (opts.json) {
    console.log(JSON.stringify({ tool: "early-return-scope", astSource, limited, ...result }, null, 2));
  } else {
    console.log(
      `early-return-scope: ${result.scannedFiles} test source(s), ${result.testFunctions} test function(s), ` +
        `${result.returnsSeen} return(s) walked in function and modifier bodies, each body cross-checked lexically.`,
    );
    console.log(`  ast source: ${astSource}`);
    if (limited) console.log(`  ${limited}`);
    if (opts.permitted) {
      console.log(`  ${result.permitted.length} return(s) seen and permitted:`);
      for (const p of result.permitted) console.log(`    ${p.file}:${p.line}  ${p.function}  -- ${p.reason}`);
    }
    if (result.findings.length === 0) {
      console.log("no early returns found.");
    } else {
      for (const f of result.findings) {
        console.log("");
        console.log(`${f.file}:${f.line}  ${f.function}`);
        console.log(`  ${f.statement}`);
        console.log(`  ${describe(f)}`);
      }
      const byClass = {};
      for (const f of result.findings) byClass[f.class] = (byClass[f.class] || 0) + 1;
      console.log("");
      console.log(
        `${result.findings.length} finding(s): ` +
          Object.entries(byClass)
            .sort()
            .map(([k, v]) => `${k} ${v}`)
            .join(", "),
      );
    }
  }
  return result.findings.length > 0 ? EXIT.FINDINGS : EXIT.CLEAN;
}

function main() {
  let code;
  try {
    code = run(process.argv.slice(2));
  } catch (e) {
    if (!(e instanceof UnableError)) throw e;
    console.error(`early-return-scope: ${e.message}`);
    console.error("REFUSING: exit 2 is not 'clean'. A scan that could not see its subject reports nothing.");
    code = EXIT.UNABLE;
  }
  process.exitCode = code;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (e) {
    // Anything unexpected is also "could not complete", never a clean exit.
    console.error(`early-return-scope: internal error: ${e && e.stack ? e.stack : e}`);
    process.exitCode = EXIT.UNABLE;
  }
}
