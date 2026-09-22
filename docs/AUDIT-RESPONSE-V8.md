# Audit response — Stonkhouse INTERFACE_VERSION 8

> **Status at this commit: there is no audit, and there are no findings.** The engagement
> (`OWN8-12`, owner decision V3-D33) has not started, no report exists, and
> [docs/audit-findings-v8.json](audit-findings-v8.json) ships **empty** — `auditor: null`, every
> `packetShas` entry `null`, `findings: []`. That is the correct state, not a gap. This document and
> its checker are the **mechanism** `C8-14` will use; the auditor supplies rows, this repository
> supplies columns.
>
> Scope is [docs/AUDIT-SCOPE.md](AUDIT-SCOPE.md) and this file is its sibling: scope is what we asked
> to be looked at, response is what came back and what we did about it.

> **Paths** resolve from the root of this repository, stonkhousedotfun/callhouse-contracts, except
> where a path is marked as belonging to the app (stonkhousedotfun/callhouse), the site, the docs
> repository, or to the planning workspace (`v8-plan/`, `stonkhouse-plan/`), which are siblings of
> this checkout rather than part of it.

---

## Contents

1. [The register, and why it is a file rather than prose](#1-the-register-and-why-it-is-a-file-rather-than-prose)
2. [The schema](#2-the-schema)
3. [The checker](#3-the-checker)
4. [The audit packet: which four SHAs were audited](#4-the-audit-packet-which-four-shas-were-audited)
5. [Re-verification checklist](#5-re-verification-checklist)
6. [The copy flip](#6-the-copy-flip)
7. [Accepted risks, by reference](#7-accepted-risks-by-reference)

---

## 1. The register, and why it is a file rather than prose

[docs/audit-findings-v8.json](audit-findings-v8.json) is the machine-readable record of the audit
response: one object per finding, with the fix commit, the regression test that would catch it
coming back, or the rationale the owner accepted instead.

It is a file and not a section of this document for the same reason
[script/v2/roles.v8.json](../script/v2/roles.v8.json) is a file: a table that several consumers must
agree on drifts the moment it exists in two places. `roles.v8.json` is the model this register was
built on — checked-in JSON, one source of truth, read by tooling rather than by eye.

**The register ships empty and must stay empty until the auditor reports.** Section 7 of
`v8-plan/00-MASTER-2026-09-19.md` lists six risks the owner has already accepted. They are **not**
pre-seeded here as `accepted` rows, deliberately: pre-answering a finding nobody has made lets a
real finding be silently absorbed into a row that already says "accepted". They are referenced from
§7 below and nowhere else.

## 2. The schema

Every record in `findings` carries:

| Field | Type | Meaning |
|---|---|---|
| `id` | string, unique | the auditor's identifier for the finding |
| `severity` | `critical` \| `high` \| `medium` \| `low` \| `informational` | the auditor's scale, not ours. `docs/AUDIT-SCOPE.md` §1 maps it onto P1–P4 |
| `title` | string | one line, the auditor's words |
| `scope` | array of repo-relative paths under `src/v2` or `script/v2` | what the finding is about |
| `status` | `fixed` \| `accepted` \| `disputed` \| `out-of-scope` | the response. There is no `open`: an open finding is not a response |
| `fixCommit` | commit SHA in this repository | required when `status` is `fixed` |
| `regressionTest` | `test/v2/<file>.t.sol::<testName>` | required when `status` is `fixed`. The test that fails if the fix is reverted |
| `rationale` | string | required when `status` is `accepted`. Why this is not being fixed |
| `ownerAccepted` | `{ by, date }` | required when `status` is `accepted`. Who signed it and when |
| `reReviewed` | `{ date }` | when the auditor re-reviewed the fix. Required by `--final` |
| `interfaceImpact` | boolean | true when a selector, event or constant moved |
| `interfaceLogEntry` | string | required when `interfaceImpact` is true. The entry in `v8-plan/status/INTERFACE-CHANGES-V8.md` |

`interfaceImpact` is the field with teeth. A moved selector means every consumer regenerates, and the
interface log is the only durable record of that — the one that already published two wrong selectors
in its first entry (`take`, `quoteTake`) and was corrected in place. A finding that moves an
interface and logs nothing is refused.

## 3. The checker

```bash
script/v2/check-audit-response.sh                     # check docs/audit-findings-v8.json
script/v2/check-audit-response.sh --register <path>   # check another register
script/v2/check-audit-response.sh --final             # additionally require reReviewed.date on every record
script/v2/check-audit-response.sh --self-test         # run the fixture suite
```

It exits 0 and prints `<N> findings registered` on a clean register — **`0 findings registered`
today**, so it is green on the empty file this commit ships. On a rejection it prints one
`REJECT <rule> <id>: <message>` line per problem and exits 1. Rules:

| Rule | Fires when |
|---|---|
| `envelope-interfaceversion`, `envelope-findings`, `envelope-auditor`, `envelope-packetshas` | the register is not a v8 audit-response register: wrong `interfaceVersion`, `findings` not an array, no `auditor` key, or `packetShas` missing one of `contracts` / `app` / `site` / `docs` |
| `id-missing`, `id-duplicate`, `title-empty`, `severity-invalid` | the record does not identify itself |
| `scope-empty`, `scope-outside` | `scope` is empty, or names a path outside `src/v2` and `script/v2` |
| `status-unset`, `status-open`, `status-invalid` | there is no response, or it is still `open` |
| `fixcommit-missing`, `fixcommit-unresolvable` | `fixed` with no `fixCommit`, or one that does not resolve via `git cat-file -e <sha>^{commit}` in this repository |
| `regressiontest-missing`, `regressiontest-malformed`, `regressiontest-file-missing`, `regressiontest-function-missing` | `fixed` with no regression test, one not in `test/v2/<file>.t.sol::<testName>` form, one naming a file that does not exist, or one naming a function that file does not contain |
| `rationale-empty`, `owneraccepted-date-missing` | `accepted` with nothing written down, or nobody's signature |
| `interfacelogentry-missing` | `interfaceImpact` is true and `interfaceLogEntry` is empty |
| `rereviewed-date-missing` | `--final` and a record the auditor has not re-reviewed |

`bash` and `jq` only, no python, bash 3.2 compatible — the convention
[script/v2/export-abis.sh](../script/v2/export-abis.sh) states in its own header.

**The trap this checker is written against.** `jq -r '.findings[].fixCommit'` on a record that omits
`fixCommit` prints the four-character string `null`, and `[ -n "null" ]` is **true**. A checker
written that way passes on exactly the incomplete record it exists to reject, and reports green —
the same shape as a stubbed dependency whose function returns its own input. Every value here is read
through one helper that uses `// empty`, so an absent key and a literal-`null` key both arrive as the
empty string. `test/v2/fixtures/audit-response/bad-fixcommit-absent.json` and
`bad-fixcommit-null.json` are the two halves of that trap, and the self-test asserts both are refused.

**The self-test asserts rules by name, not exit codes.** `test/v2/fixtures/audit-response/` holds one
valid register (`valid-empty.json`), one populated valid register, a `--final`-clean variant, and one
bad fixture per rejection rule, each asserted to be refused **by that rule's name**. A suite that only
checked exit codes would still pass if every rule collapsed into one.

## 4. The audit packet: which four SHAs were audited

The audit is of four repositories at four exact commits, recorded in `packetShas`. All four are
`null` at this commit because no packet has been cut.

| Key | Repository |
|---|---|
| `contracts` | stonkhousedotfun/callhouse-contracts — this repository, the audited surface |
| `app` | stonkhousedotfun/callhouse — indexer, web, keeper; mounts this repository at `contracts/` |
| `site` | the marketing site, which carries the public "unaudited" copy |
| `docs` | the docs repository, likewise |

The app, site and docs SHAs are recorded not because they are audited but because the **copy flip**
in §6 happens in them, and a flip has to name the commit it was made against.

## 5. Re-verification checklist

`C8-14` is not finished when the findings are fixed. Every step below runs on the **changed** code,
after the last fix commit:

1. **Re-run the `O8-13` gate set** on the changed code — `v8-plan/01-CONTEXT.md` §4, the `contracts`
   block: `forge build && forge test`, `forge fmt --check src/v2 script/v2 test/v2`, the
   `FOUNDRY_PROFILE=fork` suite **with** `--fork-url` (without it the fork tests pass by skipping),
   `script/v2/batch-refusals.sh --registry <a registry copy>`. Record the counts you measure rather
   than the counts a document quotes.
2. **Re-export the ABIs**: `script/v2/export-abis.sh --callhouse <app checkout> --check`. A fix that
   changes a function signature changes the published ABI, and this is what notices.
3. **Add an interface-log entry if any selector, event or constant moved** —
   `v8-plan/status/INTERFACE-CHANGES-V8.md`, and set `interfaceImpact: true` with that entry named in
   the register. Consumers regenerate from the published ABI; the log is how they know to.
4. **Re-run the full rehearsal on the final build**:
   `PORT=8582 REGISTRY=<a registry copy> script/v2/rehearse-v2.sh`.
5. **Get the auditor's re-review** of the fixes, record each `reReviewed.date`, and run
   `script/v2/check-audit-response.sh --final`. That mode exists so "we fixed it" and "they agreed we
   fixed it" cannot be confused.

## 6. The copy flip

Only when §5 is complete and the report link exists may public copy stop saying **unaudited**. The
handoff is to `D8-02` (docs), `S8-02` (site) and `W8-02` (web), and each of those tasks owns its own
repository's copy — this one does not cross into them.

Find every site that has to change by running the grep, not by working from a list:

```bash
git grep -ni unaudited                 # in each of: contracts, app, site, docs
```

**The list is deliberately not written down here.** It moves every day — a frozen list of line
numbers is wrong within a day of being written, and a copy flip that works from a stale list leaves
the one occurrence nobody grepped for. `docs/AUDIT-SCOPE.md`'s own status block is one of the hits in
this repository, and it says in terms that `C8-14` adds the report link.

## 7. Accepted risks, by reference

The owner has already accepted several risks for v8. They live in **`v8-plan/00-MASTER-2026-09-19.md`
§7**, alongside the trust model in [SECURITY.md](../SECURITY.md) and
[docs/V2-ARCHITECTURE.md](V2-ARCHITECTURE.md).

They are referenced, not restated, and they are **not** rows in the register. Two copies of an
accepted-risk list drift; worse, a pre-seeded `accepted` row is a place a real finding can land and
disappear. When the auditor reports something that section 7 already covers, it still gets its own
record, with its own `rationale` and its own `ownerAccepted.date`.
