# Code Review: fix-issue-manager-breakdown-checklist

**Verdict:** ⚠️ CHANGES REQUESTED

| | |
| - | - |
| **Branch** | `fix/issue-manager-breakdown-checklist` |
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

🤖 Generated with [Claude Code](https://claude.com/claude-code)
