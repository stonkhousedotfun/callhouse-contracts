// SPDX-License-Identifier: MIT
//
// T-589. Holds script/v2/early-return-scope.mjs to its fixtures, marker by marker.
//
//   node --test script/v2/early-return-scope.test.mjs
//
// THE FIXTURES ARE THE SPEC. Every return line in fixtures/early-return-scope/Shapes.t.sol.txt and
// Clean.t.sol.txt carries either `EXPECT: <class>` (must be reported, with that class, on that line) or
// `PERMIT: <reason>` (must be seen and cleared, with that reason, on that line). This file reads the
// markers back and checks three things at once: every marker is matched by exactly one report, every
// report is matched by a marker, and every line carrying the `return` keyword carries a marker -- so
// neither the fixture nor the tool can quietly grow an untested case.
//
// THE REFUSALS ARE TESTED AS REFUSALS. "No ASTs" and "no findings" must never look alike, so a
// fixture that does not compile, a scan with a missing AST, an AST built from another version of the
// file, a walker that lost a return, and a typo in a flag are each held to exit 2 -- never 0.
//
// It compiles with the same solc the tool would pick (foundry.toml's version, from svm), AST only.
// Fixtures end in `.txt` so forge never compiles them; they are copied to a scratch root as
// test/<Name>.t.sol, which is the layout the tool scans.

import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  EXIT,
  UnableError,
  analyzeSource,
  blankCommentsAndStrings,
  collectTestSources,
  compileAsts,
  lexicalReturnCount,
  parseArgs,
  run,
  scanAsts,
  solcBinary,
} from "./early-return-scope.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = join(HERE, "fixtures", "early-return-scope");
// solc is resolved from the REPO's foundry.toml, before any test chdirs into a scratch root.
const REPO_ROOT = resolve(HERE, "..", "..");
const SOLC = inDir(REPO_ROOT, () => solcBinary(null));

// Run `fn` with `dir` as the working directory and always restore. The tool resolves sources, the
// allow-list and `--root` against cwd, so every scan below is fenced this way.
function inDir(dir, fn) {
  const prev = process.cwd();
  process.chdir(dir);
  try {
    return fn();
  } finally {
    process.chdir(prev);
  }
}

// A scratch root holding test/<name>.t.sol for each fixture named. Returns the root.
function scratchRoot(...names) {
  const root = mkdtempSync(join(tmpdir(), "early-return-scope-"));
  mkdirSync(join(root, "test"));
  for (const n of names) copyFileSync(join(FIXTURES, `${n}.t.sol.txt`), join(root, "test", `${n}.t.sol`));
  return root;
}

// Compile and scan every test source under `root`, exactly as the CLI's default path does.
function scan(root, includeRe = null) {
  return inDir(root, () => {
    const { selected } = collectTestSources(includeRe);
    const byPath = compileAsts(selected, SOLC);
    return { byPath, selected, result: scanAsts(byPath, selected) };
  });
}

// Read the EXPECT / PERMIT markers out of a fixture, keyed "file:line". Also returns every line that
// carries the `return` keyword (comments and strings blanked), so an unmarked return can be caught.
function markersOf(file, text) {
  const expect = new Map();
  const permit = new Map();
  const returnLines = [];
  const blanked = blankCommentsAndStrings(Buffer.from(text, "utf8")).toString("utf8").split("\n");
  text.split("\n").forEach((line, i) => {
    const n = i + 1;
    // A marker sits on a CODE line (`return; // EXPECT: ...`). The fixture header describes the marker
    // format in comment-only lines, and those must not read as markers.
    const hasCode = blanked[i].trim() !== "";
    const e = hasCode && line.match(/\/\/\s*EXPECT:\s*([a-z-]+)\s*$/);
    const p = hasCode && line.match(/\/\/\s*PERMIT:\s*(.+?)\s*$/);
    if (e) expect.set(`${file}:${n}`, e[1]);
    if (p) permit.set(`${file}:${n}`, p[1]);
    if (/\breturn\b/.test(blanked[i]) || /\bstop\(\)/.test(blanked[i])) returnLines.push(`${file}:${n}`);
  });
  return { expect, permit, returnLines };
}

// Capture what `run` prints, and its exit code, without letting it chdir the test process for good.
function runCli(argv) {
  const lines = [];
  const orig = console.log;
  console.log = (...a) => lines.push(a.join(" "));
  const prev = process.cwd();
  try {
    let code;
    try {
      code = run(argv);
    } catch (e) {
      // Mirrors main(): a refusal is exit 2. Anything else is a real bug and propagates.
      if (!(e instanceof UnableError)) throw e;
      code = EXIT.UNABLE;
    }
    return { code, out: lines.join("\n") };
  } finally {
    console.log = orig;
    process.chdir(prev);
  }
}

describe("early-return-scope: the Shapes fixture, marker by marker", () => {
  let root;
  let result;
  let markers;
  before(() => {
    root = scratchRoot("Shapes", "Inherited");
    ({ result } = scan(root));
    markers = {
      shapes: markersOf("test/Shapes.t.sol", readFileSync(join(root, "test/Shapes.t.sol"), "utf8")),
      inherited: markersOf("test/Inherited.t.sol", readFileSync(join(root, "test/Inherited.t.sol"), "utf8")),
    };
  });
  after(() => rmSync(root, { recursive: true, force: true }));

  test("every EXPECT marker is reported with its class, and nothing else is reported", () => {
    const expected = new Map([...markers.shapes.expect, ...markers.inherited.expect]);
    const reported = new Map(result.findings.map((f) => [`${f.file}:${f.line}`, f.class]));
    assert.ok(expected.size >= 20, `the fixture should carry many EXPECT markers, saw ${expected.size}`);
    for (const [at, cls] of expected) assert.equal(reported.get(at), cls, `EXPECT ${cls} at ${at}`);
    for (const [at, cls] of reported) assert.equal(expected.get(at), cls, `reported ${cls} at ${at} has no marker`);
    assert.equal(result.findings.length, expected.size);
  });

  test("every PERMIT marker is seen and cleared with its reason, and nothing else is permitted", () => {
    const expected = new Map([...markers.shapes.permit, ...markers.inherited.permit]);
    const seen = new Map(result.permitted.map((p) => [`${p.file}:${p.line}`, p.reason]));
    assert.ok(expected.size >= 10, `the fixture should carry many PERMIT markers, saw ${expected.size}`);
    for (const [at, why] of expected) assert.equal(seen.get(at), why, `PERMIT "${why}" at ${at}`);
    for (const [at, why] of seen) assert.equal(expected.get(at), why, `permitted "${why}" at ${at} has no marker`);
    assert.equal(result.permitted.length, expected.size);
  });

  test("every line that returns carries a marker: the fixture cannot grow an untested case", () => {
    for (const m of [markers.shapes, markers.inherited]) {
      for (const at of m.returnLines) {
        assert.ok(m.expect.has(at) || m.permit.has(at), `${at} returns but carries no EXPECT/PERMIT marker`);
      }
    }
  });

  test("each named shape lands in the class the row asks for", () => {
    const byFn = new Map();
    for (const f of result.findings) byFn.set(f.function, [...(byFn.get(f.function) || []), f]);
    const one = (fn) => {
      const l = byFn.get(fn);
      assert.ok(l && l.length === 1, `${fn}: expected exactly one finding, saw ${l ? l.length : 0}`);
      return l[0];
    };
    assert.equal(one("Shapes.test_inlineReturn").where, "if-inline");
    assert.equal(one("Shapes.test_blockReturn").where, "if-block");
    assert.equal(one("Shapes.test_catchReturn").where, "catch");
    assert.equal(one("Shapes.test_trySuccessReturn").where, "try-success");
    assert.equal(one("Shapes.test_nestedBranches").where, "if-block");
    assert.equal(one("Shapes.test_elseReturn").where, "else-inline");
    // Nearest construct wins for `where`; the loop is reported on its own flag.
    assert.equal(one("Shapes.test_loopReturn").where, "if-inline");
    assert.equal(one("Shapes.test_loopReturn").inLoop, true);
    assert.equal(one("Shapes.test_loopReturn").terminal, false);
    assert.equal(one("Shapes.test_inlineReturn").inLoop, false);
    assert.equal(one("Shapes.test_uncheckedReturn").where, "if-inline");
    assert.equal(one("Shapes.test_inlineReturn").guard, "!ok()");
    assert.equal(one("Shapes.test_postAssertionReturn").assertedBefore, true);
    assert.equal(one("Shapes.test_inlineReturn").assertedBefore, false);
    assert.equal(one("Shapes.test_unconditionalReturn").where, "body");
    assert.equal(one("Shapes.test_assemblyReturn").where, "assembly");
    assert.equal(one("Shapes.test_assemblyStop").where, "assembly");
    assert.equal(one("Shapes.testFuzz_caseDiscard").class, "case-discard");
    assert.equal(one("Shapes.invariant_caseDiscard").class, "case-discard");
    assert.equal(one("Shapes.statefulFuzz_caseDiscard").class, "case-discard");
  });

  test("a modifier bail counts the tests wearing it, across files", () => {
    const bails = result.findings.filter((f) => f.kind === "modifier");
    const by = new Map(bails.map((b) => [b.function, b]));
    assert.equal(by.get("Shapes.bailsBare").testsAffected, 1);
    // Declared in Harness (Shapes.t.sol), worn only by Inherited.t.sol's test: the index spans files.
    assert.equal(by.get("Harness.bailsInBase").testsAffected, 1);
    assert.ok(!by.has("Shapes.bailsButNoTestWearsIt"), "an unworn modifier is permitted, not reported");
    for (const b of bails) assert.equal(b.class, "modifier-bail");
  });

  test("the count is exact and the whole tree was walked", () => {
    assert.equal(result.scannedFiles, 2);
    // Every test function in both files, including the one wearing the base modifier.
    assert.ok(result.testFunctions >= 30, `saw ${result.testFunctions} test functions`);
    // Every finding plus every permitted return, and nothing walked went unlisted. `stop()` is a
    // halt the tool reports but not a `return` keyword, so it is outside the lexical cross-check.
    const stops = result.findings.filter((f) => /\bstop\(\)/.test(f.statement)).length;
    assert.equal(stops, 1);
    assert.equal(result.returnsSeen + stops, result.findings.length + result.permitted.length);
  });

  test("the CLI exits 1 on findings, and --json carries the same report", () => {
    const { code, out } = runCli(["--root", root, "--json"]);
    assert.equal(code, EXIT.FINDINGS);
    const j = JSON.parse(out);
    assert.equal(j.tool, "early-return-scope");
    assert.equal(j.findings.length, result.findings.length);
    assert.equal(j.permitted.length, result.permitted.length);
    assert.equal(j.limited, null);
  });

  test("--include limits the scan and says so", () => {
    const { code, out } = runCli(["--root", root, "--json", "--include", "Inherited"]);
    assert.equal(code, EXIT.CLEAN, "Inherited.t.sol alone has no test-body return");
    const j = JSON.parse(out);
    assert.match(j.limited, /LIMITED by --include Inherited: 1 of 2/);
    // The base modifier it wears lives in a file outside the include, so its bail is not visible here:
    // a limited scan is a limited scan, and the report says so rather than pretending.
    assert.equal(j.scannedFiles, 1);
  });
});

describe("early-return-scope: the Clean fixture", () => {
  let root;
  before(() => {
    root = scratchRoot("Clean");
  });
  after(() => rmSync(root, { recursive: true, force: true }));

  test("a clean tree is 'seen and cleared', never 'never looked'", () => {
    const { result } = scan(root);
    const m = markersOf("test/Clean.t.sol", readFileSync(join(root, "test/Clean.t.sol"), "utf8"));
    assert.equal(result.findings.length, 0);
    assert.equal(m.expect.size, 0);
    const seen = new Map(result.permitted.map((p) => [`${p.file}:${p.line}`, p.reason]));
    assert.deepEqual([...seen].sort(), [...m.permit].sort());
    assert.equal(result.returnsSeen, m.permit.size);
    for (const at of m.returnLines) assert.ok(m.permit.has(at), `${at} returns without a PERMIT marker`);
  });

  test("the CLI exits 0 and lists the permitted returns on request", () => {
    const { code, out } = runCli(["--root", root, "--permitted"]);
    assert.equal(code, EXIT.CLEAN);
    assert.match(out, /no early returns found/);
    assert.match(out, /4 return\(s\) seen and permitted/);
    assert.match(out, /Clean\.onlyFork\s+-- modifier: vm\.skip\(true\) dominates/);
    assert.match(out, /Clean\.setUp\s+-- setUp is not a test body/);
  });
});

describe("early-return-scope: refusals exit 2, never 0", () => {
  test("a fixture that does not compile is UNABLE, not clean", () => {
    const root = scratchRoot("Broken");
    try {
      assert.throws(() => scan(root), (e) => e instanceof UnableError && /solc reported \d+ error/.test(e.message));
      const { code } = runCli(["--root", root]);
      assert.equal(code, EXIT.UNABLE);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a test source with no AST refuses the whole scan", () => {
    const root = scratchRoot("Clean");
    try {
      const { byPath, selected } = scan(root);
      const partial = new Map(byPath);
      partial.delete("test/Clean.t.sol");
      assert.throws(
        () => inDir(root, () => scanAsts(partial, selected)),
        (e) => e instanceof UnableError && /1 test source\(s\) have no AST/.test(e.message),
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an AST built from another version of the file refuses", () => {
    const root = scratchRoot("Clean");
    try {
      const { byPath } = scan(root);
      const ast = byPath.get("test/Clean.t.sol");
      const file = join(root, "test/Clean.t.sol");
      const stale = Buffer.concat([readFileSync(file), Buffer.from("\n// one more line\n")]);
      assert.throws(
        () => analyzeSource(ast, stale, "test/Clean.t.sol"),
        (e) => e instanceof UnableError && /describes another version/.test(e.message),
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a walker that cannot see a return refuses rather than under-reporting", () => {
    const root = scratchRoot("Shapes", "Inherited");
    try {
      const { byPath } = scan(root);
      const ast = structuredClone(byPath.get("test/Shapes.t.sol"));
      // Hide exactly one Return node from the walker; the lexical count still sees it.
      let hidden = 0;
      (function hide(n) {
        if (!n || typeof n !== "object") return;
        if (n.nodeType === "Return" && hidden === 0) {
          n.nodeType = "NotAReturnAnyMore";
          hidden++;
          return;
        }
        for (const k of Object.keys(n)) hide(n[k]);
      })(ast);
      assert.equal(hidden, 1);
      assert.throws(
        () => analyzeSource(ast, readFileSync(join(root, "test/Shapes.t.sol")), "test/Shapes.t.sol"),
        (e) => e instanceof UnableError && /blind to some construct/.test(e.message),
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an unknown flag or a valueless flag is a refusal, not a silent default", () => {
    assert.throws(() => parseArgs(["--jsno"]), (e) => e instanceof UnableError && /unknown argument/.test(e.message));
    assert.throws(() => parseArgs(["--include"]), (e) => e instanceof UnableError && /needs a value/.test(e.message));
    assert.throws(() => parseArgs(["--root", "--json"]), (e) => e instanceof UnableError);
    const root = scratchRoot("Clean");
    try {
      assert.equal(runCli(["--root", root, "--jsno"]).code, EXIT.UNABLE);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("an empty tree and an --include that matches nothing both refuse", () => {
    const root = mkdtempSync(join(tmpdir(), "early-return-scope-empty-"));
    mkdirSync(join(root, "test"));
    try {
      assert.equal(runCli(["--root", root]).code, EXIT.UNABLE);
      writeFileSync(join(root, "test", "X.t.sol"), "// SPDX-License-Identifier: MIT\npragma solidity 0.8.28;\ncontract X {}\n");
      assert.equal(runCli(["--root", root, "--include", "nothing-matches-this"]).code, EXIT.UNABLE);
      assert.equal(runCli(["--root", root]).code, EXIT.CLEAN, "a test source with no returns is clean");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("early-return-scope: the lexical cross-check", () => {
  test("counts the keyword `return`, not `returns`, and ignores comments and strings", () => {
    const src = Buffer.from(
      [
        "function f() public returns (uint256) {",
        '  string memory s = "return"; // return',
        "  /* return */ if (true) return 1;",
        "  return 2;",
        "}",
      ].join("\n"),
    );
    const blanked = blankCommentsAndStrings(src);
    assert.equal(blanked.length, src.length, "blanking must preserve byte offsets");
    assert.equal(lexicalReturnCount(blanked, 0, src.length), 2);
  });

  test("blanking keeps newlines and multi-byte characters' byte count", () => {
    const src = Buffer.from("// — ≥ × é\nreturn; // é\n", "utf8");
    const blanked = blankCommentsAndStrings(src);
    assert.equal(blanked.length, src.length);
    assert.equal(blanked.toString("utf8").split("\n").length, src.toString("utf8").split("\n").length);
    assert.equal(lexicalReturnCount(blanked, 0, src.length), 1);
  });
});
