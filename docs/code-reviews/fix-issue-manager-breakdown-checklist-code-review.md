# Code Review: fix-issue-manager-breakdown-checklist

**Verdict:** ✅ APPROVED at round 3 (`bece738`) — all findings resolved or accepted

| | |
| - | - |
| **Branch** | `fix/11-issue-manager-breakdown-checklist` (issue #11; renamed after round 3) |
| **Reviewer** | @Cali LaFollett |
| **Review Round** | 1 |
| **Reviewed SHA** | `160cceee08ec789f16824f0af666fd5ac5ea5715` |
| **Title** | issue-manager `create` no longer duplicates or wipes the Story Breakdown |
| **Files Changed** | 7 |
| **Lines Changed** | +116 / -15 |
| **Date** | 2026-09-22 |

---

## Review Round 1

### Summary

The branch replaces the `\Z` anchor, which JavaScript treats as a literal `Z`,
and changes the Story Breakdown from full regeneration to append-only. It also
adds 8 `node:test` cases and a CI step to run them. `pe-governance` reviewed
SKILL.md and `pe-aws-infra` reviewed ci.yml. `gh-issues.js` and its tests have
no matching PE, so the primary ran the generic three-pass on them.

The fix works for the exact heading `## Story Breakdown\n`. It misses any other
spelling of that heading, and on those it still produces the duplicate
section this PR exists to remove.

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 1 | 0 |
| 🟢 LOW | 4 | 0 |
| ℹ️ INFO | 2 | 0 |

### 🟡 MEDIUM-001: A heading variant still appends a duplicate breakdown

**Domains:** [Code Quality]
**Location:** `plugins/issue-manager/skills/issue-manager/scripts/gh-issues.js:563`

`STORY_BREAKDOWN_SECTION` requires `## Story Breakdown` followed immediately by
`\n`. Three headings miss the regex and fall through to the append branch, so
each ends up with 2 `## Story Breakdown` headings:

- a suffixed heading, e.g. `## Story Breakdown (by phase)`
- a trailing space
- CRLF line endings

**Recommendation:** Match the heading line with `^## Story Breakdown\b[^\n]*`
in multiline mode. Decide the separator from whether the section has a body,
rather than comparing against the exact heading string. Add a test for each
variant.

### 🟢 LOW-001: CI test step has no zero-test floor (PE-AWS-Infra)

**Location:** `.github/workflows/ci.yml:99`

A test file that registers no tests exits 0 and reports `tests 0`. Every
other step in this job asserts that it actually checked something.

### 🟢 LOW-002: Step 7 names `update` instead of giving the literal command (PE-Governance)

**Location:** `plugins/issue-manager/skills/issue-manager/SKILL.md:94`

The bare word `update` suggests an unscoped `update`, which re-pushes every
child issue. Give the literal command, scoped with `--file` to the epic.

### 🟢 LOW-003: Prose conditional leaves `update` optional, so a failed push stays stale (PE-Governance)

**Location:** `plugins/issue-manager/skills/issue-manager/SKILL.md:94`, `gh-issues.js:613-621`

In `create`, the local file is written before the push. If `gh issue edit`
fails, every later `create` finds nothing missing and never pushes again.

**Recommendation:** Write step 7 as pseudocode with an unconditional `update`.
Also write the file only after the push succeeds, so the next `create`
retries.

### 🟢 LOW-004: Hand-written unnumbered lines stay beside the appended `#N` lines (PE-Governance)

**Location:** `plugins/issue-manager/skills/issue-manager/SKILL.md:94`

Tell step 7 to replace any unnumbered line for the same child.

### ℹ️ INFO-001: No setup-node; one named test file (PE-AWS-Infra)

Tests passed on Node 20, 22 and 26. Requiring the file has no side effects,
and `actionlint` exits 0.

### ℹ️ INFO-002: "Phase heading" is undefined, and the Import flow never reaches step 7 (PE-Governance)

**Recommendation:** Add a phase example to `epic-template.md` and an Import
step that points to Create step 7.

### Action Items

- [ ] MEDIUM-001: match heading variants
- [ ] LOW-001 – LOW-004 (cheap, taken in the same remediation)

---

## Review Round 2

**Reviewed SHA:** `d3658f8` · **Verdict:** ✅ APPROVED (LOW/INFO only)

Round 1 is fully resolved:

- **MEDIUM-001.** The heading now matches as `^## Story Breakdown\b[^\n]*`, and the lookaheads accept `\r?\n`. CRLF input stays CRLF. Four tests were added, for a suffixed heading, CRLF, an empty section directly above the next heading, and a heading at end of file. The suite is 12/12.
  - The final code was replayed against all 12 Corebizy epics. None had a duplicate heading or a dropped `[x]` (0 bad).
- **LOW-001.** CI now runs the test file in-process, with a pass-count floor, and captures `rc` so that failing output is still printed.
  - Under `node --test`, an empty file is reported as one passing test on Node 20, 22 and 26. The recommended floor would not have tripped there, which is why the file runs in-process.
  - PE-AWS-Infra verified 10 cases on Node 20 through 26: real, empty, skip-only, failing, async throw, load throw, missing file and three others. Every case exits correctly. `actionlint` and `shellcheck` both pass.
- **LOW-002 to LOW-004.** Step 7 is now pseudocode that ends with a literal, unconditional `update --file 00-Epic-<Title>.md`. The loop deletes unnumbered duplicates. The CLI pushes before it writes the file.
- **INFO-002.** `### Phase …` is defined inline, and Import step 6 points to Create step 7. The template example was not taken.

| Severity | Finding | Disposition |
| - | - | - |
| 🟢 LOW | After a failed push, step 7's loop runs empty and `update` re-pushes the unmerged epic (PE-Governance) | Fixed in `bece738`: one `create` retry, then stop and report |
| ℹ️ INFO | CI floor is `>=1`, not the expected count (PE-AWS-Infra) | Accepted: an exact count would couple every test addition to CI |
| ℹ️ INFO | Test header still said `node --test` (PE-AWS-Infra) | Fixed in `bece738` |

---

## Review Round 3

**Reviewed SHA:** `bece738` · **Verdict:** ✅ APPROVED (0 findings)

PE-Governance re-reviewed only the round-2 remediation. The step 7 retry is bounded to a single `create` re-run, after which it stops and reports. It keys on the exact message printed by `updateEpicChecklist`. This resolves the round-2 LOW.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
