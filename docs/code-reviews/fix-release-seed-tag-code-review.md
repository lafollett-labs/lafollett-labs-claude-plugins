# Code Review: fix-release-seed-tag

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Branch** | `fix/release-seed-tag` |
| **PR** | [#22](https://github.com/lafollett-labs/lafollett-labs-claude-plugins/pull/22) |
| **Author** | @clafollett |
| **Reviewer** | Claude Code (`/code-reviewer` 2.14.1) for Cali LaFollett |
| **Review Round** | 1 |
| **Reviewed SHA** | `d001a857fefe4b43348437e3c8d108cb08f50f8c` |
| **Title** | fix(ci): seed the release baseline on a commit the token may tag |
| **Files Changed** | 2 |
| **Lines Changed** | +116 / -32 |
| **Date** | 2026-11-26 |

---

## Summary

The first Release run after #21 failed with HTTP 403 creating the seed tag at main^1. The PR changes three things:
- The seed lands on main itself when main^1's workflows differ and that skips no release; otherwise the run stops and names the command to tag it by hand.
- A refused release tag explains itself the same way.
- reconcile publishes the GitHub Release of a release tag made by hand.

The suite's stub gh now refuses as production did, and `release()` really clones fresh per run.

PE-AWS-Infra simulated the post-merge run on a scratch copy: it seeds `v1.34.1` at `41c4677` and releases nothing. It found two LOW findings and one INFO, none blocking:
- A refused seed is skipped silently by the next run.
- The comment states GitHub's rule more broadly than was observed.
- The new prelude makes a `gh release view` call on nearly every run.

CI was green on all 5 jobs at the reviewed SHA (run 45941852443).

---

## Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-AWS-Infra | none | none — TEST BUDGET none; CI run 45941852443 at `d001a85`: 5/5 green. Under M2, a post-merge simulation on a scratch bare copy (d001a85 squashed onto 41c4677, tags stripped, the stub's 403 rule): seeds v1.34.1 at 41c4677, 1 refs call, nothing to release, exit 0 |
| Primary | — | Author mutants on copies before review: 6 killed, 1 equivalent and dropped. main's `run-release.sh` against the new suite fails case 1 as production did |

---

## Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-AWS-Infra | 4 changed contracts → 3 consumers and 4 restatements (header, seed comment, push hint, PR body); README, CONTRIBUTING, CHANGELOG and release.yml grepped, none restate it; the lost-counter fix vs 2 sibling counters, neither affected | post-merge run simulated; 4 lifecycles traced (refused seed then next merge, missed wait then workflow merge, wait-loop tag, two refused releases out of order) | seed_baseline over root main, equal/different workflows, empty/non-empty plan, a release commit in range, an unlisted plugin dir; by_hand with GH_REPO set, unset, empty | `.github/workflows` scope vs the workflows permission; the seed refusal across runs (LOW-001); rulesets read: both target branches, none tags; job token Contents: write | 6 new failure paths, incl. the prelude's release view (INFO-001) and test `release()` clone failure | 9 mutants traced: 8 killed, 1 (the prelude's tag==v check) survives with no reachable case; 86 checks match the PR; the stub encodes the PR's own model (LOW-002) | 3 claims: GITHUB_TOKEN has no workflows permission (confirmed, docs); REST create-ref 403 on differing workflows (confirmed by run 45939130910); "any ref … default branch's" (UNVERIFIED, LOW-002) |

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 2 | 0 |
| ℹ️ INFO | 1 | 0 |

---

## In Scope Findings

### 🟢 LOW-001: A refused seed's changes are skipped silently by the next run

**Domains:** [Architecture] · **Move:** M4
**Location:** `scripts/ci/release/run-release.sh:99`
**Siblings:** `scripts/ci/release/test/run-release-integration-tests.sh:332`, `scripts/ci/release/run-release.sh:93`

seed_baseline refuses to seed on main when that would skip the activation merge's changes. The refusal lasts one run: if nobody tags by hand before the next merge, that run seeds at the new main^1, past the activation merge. Its plugin changes then ship without a bump, and nothing warns. Case 14b asserts exactly that. This repo is not exposed, since #21 changed no plugin, but any re-activation is.

**Recommendation:** Anchor the seed to the commit that added the release workflow, not to whichever run first finds no tag. Seed at its parent, with the same refusal when its workflows differ and the plan releases.

---

### 🟢 LOW-002: UNVERIFIED — "GitHub refuses a workflow token any ref … whose .github/workflows differs from the default branch's"

**Domains:** [Fact check] · **Move:** M7
**Location:** `scripts/ci/release/run-release.sh:75`
**Siblings:** `scripts/ci/release/run-release.sh:268`, `scripts/ci/release/run-release.sh:95`, `scripts/ci/release/test/run-release-integration-tests.sh:57`

Two parts are verified: GITHUB_TOKEN cannot get the workflows permission, and run 45939130910 got HTTP 403 creating a tag on a commit whose workflows differ from main's. No primary source states the general rule or its comparator. The push hint at `:268` assumes another comparator (the branch's old tip), so "any ref" contradicts the same file. The code uses the rule only for creating tags, which matches what was observed, but the comment and the stub both claim more.

**Recommendation:** Narrow the comment to the observed case (a new tag, REST, HTTP 403, run 45939130910) and leave the push hint's own model to `:268`.

---

### ℹ️ INFO-001: The reconcile prelude adds a `gh release view` to nearly every run

**Domains:** [Reliability] · **Move:** M5
**Location:** `scripts/ci/release/run-release.sh:135`
**Siblings:** `scripts/ci/release/run-release.sh:115`, `scripts/ci/release/run-release.sh:163`

publish_release reads any `release view` failure as "not published", then dies when `release create` finds the release exists. That path used to run only on runs that tagged; the prelude now runs it whenever the newest tag is a release commit. A transient API error turns an idle run red; a re-run recovers. The prelude also closes an older gap, where a tag whose publish failed was never published.

**Recommendation:** Awareness only.

---

## Out of Scope

None.

---

## Action Items

### Must Fix (blocks merge)

None.

### Required

None.

### Optional

- [ ] LOW-001: fix `scripts/ci/release/run-release.sh:99` + 2 siblings
- [ ] LOW-002: fix `scripts/ci/release/run-release.sh:75` + 3 siblings

---

## Files Reviewed

| File | Findings |
| - | - |
| `scripts/ci/release/run-release.sh` | 3 |
| `scripts/ci/release/test/run-release-integration-tests.sh` | 0 (siblings of LOW-001, LOW-002) |

---

## Merge Eligibility

**Locked to SHA:** `d001a857fefe4b43348437e3c8d108cb08f50f8c`
**Status:** ✅ Mergeable IF `git rev-parse HEAD == d001a857fefe4b43348437e3c8d108cb08f50f8c` (plus this review doc). Any later code commit invalidates this round and requires re-review.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
