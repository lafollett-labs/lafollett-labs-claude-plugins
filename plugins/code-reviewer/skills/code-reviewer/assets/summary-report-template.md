# Code Review: {ISSUE-ID}

**Verdict:** ✅ APPROVED | ⚠️ CHANGES REQUESTED | 🚫 BLOCKED | ⚠️ INCOMPLETE

| | |
| - | - |
| **Branch** | `{branch-name}` |
| **PR** | [#{number}]({url}) |
| **Author** | @{pr-author} |
| **Reviewer** | @{reviewer} |
| **Review Round** | 1 |
| **Reviewed SHA** | `{full-sha}` |
| **Title** | {Brief description} |
| **Files Changed** | {count} |
| **Lines Changed** | +{added} / -{removed} |
| **Date** | {YYYY-MM-DD} |

---

## Summary

{2-3 sentences summarizing the review. What was changed, what issues were found, overall assessment.}

---

## Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| {PE} | {none / targeted / full / MISSING} | {pass2_evidence lines, or "<failed check> after re-ping"} |

---

## Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| {PE or Primary} | {checked, or "n/a — note", or MISSING} | … | … | … | … | … | … |

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 0 | 0 |

---

## In Scope Findings

-Issues in the changed code - must address based on severity-

### 🔴 CRITICAL-001: {Title}

**Domains:** [Security] · **Move:** {M1..M7 | none}
**Location:** `{src/full/path/from/repo/root}:{line}`
**Siblings:** {`path:line`, … | none}

{Description of the issue}

**Recommendation:**
{How to fix, with code example if helpful}

---

### 🟠 HIGH-001: {Title}

**Domains:** [Architecture, Code Quality] · **Move:** {M1..M7 | none}
**Location:** `{src/full/path/from/repo/root}:{line}`
**Siblings:** {`path:line`, … | none}

{Description}

**Recommendation:**
{Fix}

---

### 🟡 MEDIUM-001: {Title}

**Domains:** [{Domain}] · **Move:** {M1..M7 | none}
**Location:** `{src/full/path/from/repo/root}:{line}`
**Siblings:** {`path:line`, … | none}

{Description and recommendation}

---

## Out of Scope

-Pre-existing issues not introduced by this PR - log to backlog, don't block-

| Severity | Issue | Location |
| - | - | - |
| 🟡 MEDIUM | {Pre-existing issue description} | `{file}:{line}` |
| 🟢 LOW | {Pre-existing issue description} | `{file}:{line}` |

---

## Action Items

### Must Fix (blocks merge)

- [ ] {CRITICAL-NNN}: fix `{location}` + {N} siblings
- [ ] {HIGH-NNN}: fix `{location}` + {N} siblings

### Required

- [ ] {MEDIUM-NNN}: fix `{location}` + {N} siblings

### Optional

- [ ] {LOW-NNN}: fix `{location}` + {N} siblings

---

## Files Reviewed

| File | Findings |
| - | - |
| `{path/to/file}` | {count} |
| `{path/to/file}` | {count} |

---

## Merge Eligibility

**Locked to SHA:** `{full-sha}`
**Status:** ✅ Mergeable IF `git rev-parse HEAD == {full-sha}`. Any commit after this SHA invalidates this round and requires re-review (`/code-reviewer` again before merge).

<!--
MULTI-ROUND REVIEWS: When appending subsequent reviews, add the following
section before this footer. Increment the round number. Update the top-level
Verdict to match the latest round. Update Merge Eligibility above to lock to
the LATEST round's SHA.

If the prior round was ✅ APPROVED and new commits exist, prepend the round
heading with: "🚫 PRIOR ROUND INVALIDATED — re-reviewing post-approval changes"

---

## Review Round {N}

**Verdict:** ✅ APPROVED | ⚠️ CHANGES REQUESTED | 🚫 BLOCKED | ⚠️ INCOMPLETE

| | |
| - | - |
| **Reviewer** | @{reviewer} |
| **Reviewed SHA** | `{full-sha}` |
| **Date** | {YYYY-MM-DD} |
| **Fix cascade** | {n} / {total} in-scope findings introduced by a prior fix |
| **Ripple receipts** | {N spot-checked, or "none — M1 ran exhaustive over the fix diff's rules"} |

### Summary

{2-3 sentences summarizing this round's findings and any agreement/disagreement with prior rounds}

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| {PE} | {none / targeted / full / MISSING} | {pass2_evidence lines, or "<failed check> after re-ping"} |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| {PE or Primary} | {checked, or "n/a — note", or MISSING} | … | … | … | … | … | … |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 0 | 0 |

### In Scope Findings

{Same format as primary findings, plus `**Introduced by:** {prior finding id | still-present | new | missed | pre-existing}` under each Location}

### Action Items

#### Must Fix (blocks merge)
- [ ] {ID}: fix `{location}` + {N} siblings

#### Should Fix
- [ ] {ID}: fix `{location}` + {N} siblings

#### Consider
- [ ] {ID}: fix `{location}` + {N} siblings
-->

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
