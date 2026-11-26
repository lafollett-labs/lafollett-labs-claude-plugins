# Code Review: feat-code-reviewer-review-moves

**Verdict:** ⚠️ CHANGES REQUESTED (round 3 of 3; its fixes are in `dc48b6b`, which has not been re-reviewed)

| | |
| - | - |
| **Branch** | `feat/code-reviewer-review-moves` |
| **PR** | not yet opened |
| **Author** | @clafollett |
| **Reviewer** | Claude Code (`/code-reviewer`) |
| **Review Round** | 1 |
| **Reviewed SHA** | `d4a7493716198427316bcdecf66529a77c316bd7` |
| **Title** | code-reviewer 2.13.0: seven review moves with per-move coverage |
| **Files Changed** | 19 |
| **Lines Changed** | +454 / -55 |
| **Date** | 2026-11-26 |

---

## Summary

The branch adds the review-moves asset and wires it into all seven PEs and the generic review. It also extends Phase 4.5 to any linked issue with acceptance criteria and adds a frontend-routing warning to init-project. Two pe-governance reviews, one for the skill and assets and one for the PE agents, found 3 MEDIUM issues:
- the `server_side` predicate fires on Nuxt Nitro code and misses common backend imports;
- the generic review never runs Spec Coverage;
- the new governance glob leaves out `skills/*/references/*.md`.

They also found 19 LOW issues, mostly restatements left out of step with a changed contract. All the in-scope findings are fixed in `bea3ba4`.

---

## Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-Governance (skill + assets) | none | lint-shaped checks: frontmatter, pseudocode determinism, table separators, cross-file references |
| PE-Governance (agents) | none | lint-shaped checks: shared-paragraph hash across 7 PEs, probe-table move names, Output Format examples against `valid()` |

---

## Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-Governance (skill + assets) | 6 changed contracts grepped across 19 files; 15 unfixed pass-count sites | Phase 4.5 link state × 3 branches; re-ping → MISSING → INCOMPLETE; deploy order skill vs cached PE | `generic_files` under 3 approaches; 6 AC heading variants; 3 H1 shapes | misfit: 4 false positives, 4 false negatives; `has_ac` 5 variants; glob run via `git ls-files` | 5 failure paths (asset Read, issue fetch, story resolution, Primary coverage) | 16 coverage examples vs `valid()`; 12 move tags vs triggers | 7 platform facts run or read (`gh --json labels` shape, BSD grep `\d`, pathspec globs) |
| PE-Governance (agents) | shared paragraph ×7 (hash-identical), 14 coverage examples, 9 move comments, glob vs 4 restatements | move ordering in 7 workflows; round 2+ FIX DIFF vs round-over-round rule | paragraph with no / unreadable `REVIEW_MOVES`; glob on root, nested, `.claude/skills` | glob (references/ miss); 49 probe cells read as rules (2 drop exemptions) | 3 paths: asset absent, unreadable, coverage omitted | 9 example tags vs the asset definition; pe-devtools example severity | 6 facts checked at source (GFM pipe escape, grep `\d`, skill layout) + 14 probe facts |
| Primary | README pass-count and template move names vs CONTRIBUTING (fixed before dispatch) | n/a — human docs and manifests hold no state | n/a — no branch, parser or limit in human docs | n/a — no guard in human docs | n/a — no call that can fail | n/a — no test added or changed | CHANGELOG claims vs the diff |

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 3 | 0 |
| 🟢 LOW | 19 | 1 |
| ℹ️ INFO | 5 | 1 |

---

## In Scope Findings

### 🟡 MEDIUM-001: `server_side` predicate flags Nuxt Nitro and frontend `api/` code, misses common backend imports

**Domains:** [Governance] · **Move:** M4
**Location:** `plugins/code-reviewer/skills/code-reviewer/SKILL.md:102`

Nuxt `server/` is Nitro, which pe-vue claims, so every full-stack Nuxt repo would get the init-project WARNING. `src/api/client.ts` (a frontend fetch wrapper) matched `api/`, and test files that read fixtures through `fs` matched as well. Meanwhile `@prisma/client`, bare `fs`/`http`, knex, drizzle-orm, typeorm, sequelize, ioredis and ws did not match.

**Fixed:** `server_side(f)` now excepts tests and Nuxt `server/`, drops `api/`, matches built-ins bare or `node:`, lists package families, and has an open clause. The init-project copy is identical and is on the CONTRIBUTING sync list.

---

### 🟡 MEDIUM-002: Spec Coverage never ran when no PE matched

**Domains:** [Governance] · **Move:** M1
**Location:** `plugins/code-reviewer/skills/code-reviewer/SKILL.md:199`

Phase 4.5 only enriched PE dispatch inputs. With approach `generic`, a resolvable link with acceptance criteria produced no Spec Coverage, even though the description says every linked change runs it.

**Fixed:** the generic review gains a `Spec` step that runs the protocol when approach is `generic` and Phase 4.5 reaches enrichment.

---

### 🟡 MEDIUM-003: Skill-asset routing fix misses `skills/*/references/*.md`

**Domains:** [Governance] · **Move:** M1
**Location:** `plugins/code-reviewer/agents/pe-governance.md:61`

Eleven reference docs that SKILL.md files load at runtime matched no PE.

**Fixed:** `**/skills/*/references/*.md` is added beside the assets glob in all four restatements and in the CHANGELOG.

---

### 🟢 LOW findings (all fixed in `bea3ba4`)

| ID | Move | Finding | Location |
| - | - | - | - |
| LOW-001 | M1 | init-project's proposed Generic row cannot take files from an overlapping pe-vue row; the warning now says the generic review is added and the row adds test commands | `skills/init-project/SKILL.md:198` |
| LOW-002 | M1 | Report template abbreviated four move names | `assets/summary-report-template.md:36` |
| LOW-003 | M1 | `# M2..M7 \| none` allowed-value comment | `agents/pe-governance.md:542` |
| LOW-004 | M1 | "four-pass" / "three-pass" left in 7 PE intros, 6 Constraints, READMEs, CLAUDE.md, SKILL.md | multiple |
| LOW-005 | M7 | `gh --json labels` returns objects; labels are now extracted by name | `SKILL.md:426` |
| LOW-006 | M4 | `has_ac` and the protocol parser accepted different headings; `has_ac` now uses the protocol parser, which is case-insensitive with optional colon and bold | `SKILL.md:411` |
| LOW-007 | M5 | A failed issue fetch skipped Spec Coverage silently; it now reports `SPEC-LINK-UNVERIFIED` | `SKILL.md:426` |
| LOW-008 | M4 | `valid()` could reject `findings: []` and accepted vacuous `checked` | `SKILL.md:229` |
| LOW-009 | M6 | Coverage examples short of five moves with no elision marker | `assets/review-moves.md:96` |
| LOW-010 | M3 | Review docs and lockfiles flowed into FIX DIFF and `unmatched` | `assets/review-moves.md:87` |
| LOW-011 | M2 | Re-dispatch timing relative to the next batch was unstated | `SKILL.md:235` |
| LOW-012 | M7 | "`grep -E` has no `\d`" is false on BSD grep | `agents/pe-governance.md:456` |
| LOW-013 | none | Description grew to 1000 characters | `SKILL.md:3` |
| LOW-014 | M1 | An issue number from another tracker, and an epic path from another project | `agents/pe-governance.md:477`, `assets/spec-coverage-protocol.md:285` |
| LOW-015 | M1 | Spec Coverage findings still said "story" | `assets/spec-coverage-protocol.md:40` |
| LOW-016 | M7 | Unescaped `\|\|` split a probe-table row | `agents/pe-aws-infra.md:713` |
| LOW-017 | M4 | pe-go and pe-rust M5 probes dropped their PE's exemptions | `agents/pe-go.md:675`, `agents/pe-rust.md:690` |
| LOW-018 | M6 | `move` was defined as "surfaced it" while examples tag by trigger; it is now defined by trigger | `assets/review-moves.md:94` |
| LOW-019 | M4 | Round-over-round discipline was scoped to Pass 4; the asset now applies the PE's calibration rules to moves | `assets/review-moves.md:3` |

### ℹ️ INFO

| ID | Move | Finding | Disposition |
| - | - | - | - |
| INFO-001 | M1 | Branch commits after `662435e` edit `plugins/` without their own bump | 2.13.0 is unreleased; squash-merge lands one commit with the bump |
| INFO-002 | M6 | pe-governance's n/a example nudged toward n/a when examples change | fixed |
| INFO-003 | M5 | A set but unreadable `REVIEW_MOVES` was unhandled | fixed in all seven PEs ("probes only — " prefix) |
| INFO-004 | M2 | Self-review ran the cached pre-branch pe-governance definition | round 2 dispatch reads the branch definition |
| INFO-005 | none | The MISSING label said "no YAML" for any failed check | fixed: the row records the failed check |

---

## Out of Scope

| Severity | Issue | Location |
| - | - | - |
| 🟢 LOW | pe-devtools rates header/exit-code drift CRITICAL, HIGH, MEDIUM and LOW in four places | `agents/pe-devtools.md:511` |
| ℹ️ INFO | Dash-run table separators in touched files (normalised to `\| - \|` in `bea3ba4`) | multiple |

---

## Action Items

### Must Fix (blocks merge)

- [x] none

### Required

- [x] MEDIUM-001 `server_side` predicate
- [x] MEDIUM-002 Spec Coverage in the generic review
- [x] MEDIUM-003 `references/` glob

### Optional

- [x] LOW-001 – LOW-019
- [ ] pe-devtools exit-code severity (out of scope, follow-up)

---

## Files Reviewed

| File | Findings |
| - | - |
| `plugins/code-reviewer/skills/code-reviewer/SKILL.md` | 11 |
| `plugins/code-reviewer/skills/code-reviewer/assets/review-moves.md` | 4 |
| `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md` | 2 |
| `plugins/code-reviewer/skills/code-reviewer/assets/summary-report-template.md` | 1 |
| `plugins/code-reviewer/skills/init-project/SKILL.md` | 2 |
| `plugins/code-reviewer/agents/pe-*.md` (7) | 9 |
| `CHANGELOG.md`, `CONTRIBUTING.md`, READMEs, manifests | 0 |

---

## Merge Eligibility

**Locked to SHA:** `3ae7cb4761c476c57cc1abe51d2c8246a1a5181a` (round 3)
**Status:** ⚠️ Not mergeable as reviewed. Round 3 requested changes, and they landed in `dc48b6b`. ROUND_CAP is reached, so the operator decides on a round 4 before merge.

---

## Review Round 2

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | Claude Code (`/code-reviewer`) |
| **Reviewed SHA** | `bd2665dcc67d8520aba2f6af4098e4abbf4d7154` |
| **Date** | 2026-11-26 |

### Summary

Every round-1 in-scope finding has been verified as resolved at HEAD. Both PE dispatches read the branch's pe-governance definition, not the cached copy. Checks confirmed the fixes:
- the shared paragraph is hash-identical across all 7 PEs;
- the governance glob matches all 16 skill asset and reference files;
- every probe row has the right number of pipes;
- no added line names a private repository, path or PR number.

The round found no CRITICAL, HIGH or MEDIUM issues, so the verdict is APPROVED. It did find 7 LOW and 3 INFO, mostly siblings of round-1 fixes. All of them are fixed in `56a56df`. That commit invalidates this lock, so round 3 reviews it.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-Governance (skill + assets) | none | lint-shaped checks; AC heading regex run under python `re` against 8 inputs; `--jq` label extraction run under jq |
| PE-Governance (agents) | none | lint-shaped checks; paragraph hash ×7; pipe count per probe row; `git ls-files ':(glob)'` on the governance globs |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-Governance (skill + assets) | 4 fix contracts → 2 predicate copies, 5 glob restatements, 3 AC siblings, 2 template rows | Phase 4.5 order vs dispatch (1 gap); re-ping → MISSING; 2 deploy orders | 8 AC headings; empty `generic_files`; empty issue body; 3 server layouts | `server_side` 3+3 inputs; AC regex 8 inputs (1 miss); `valid()` 2 edge inputs | 4 paths: asset Read, Trigger fetch, second body fetch, Primary coverage | 5 YAML examples vs `valid()` | 7 facts run or read (jq, python `re`, description length 838) |
| PE-Governance (agents) | paragraph and workflow line ×7; move names; glob ×4 + CHANGELOG; pass-count wording in 7 intros, 7 Constraints | move ordering ×7; 2 deploy orders | absent vs unreadable `REVIEW_MOVES`; pe-audio with zero audio units | 11 FIX DIFF hunks; `valid()` vs 14 example strings (1 miss); 7 tables pipe-counted | 3 paths: asset absent, unreadable, coverage omitted | 14 coverage blocks vs `valid()`; 9 move tags | 5 facts (BSD grep `\d` run; GFM pipe escape; CHANGELOG claim vs 7 files) |
| Primary | CHANGELOG, CONTRIBUTING, 3 READMEs vs the fixed contracts (1 drift: init-project README) | n/a — human docs and manifests hold no state | n/a — no branch, parser or limit | n/a — no guard | n/a — no call that can fail | n/a — no test added or changed | version fields 2.13.0 / 1.33.0 vs CHANGELOG |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 7 | 0 |
| ℹ️ INFO | 3 | 0 |

### In Scope Findings

| ID | Move | Finding | Location | Disposition |
| - | - | - | - | - |
| LOW-001 | M4 | AC heading regex rejected `**Acceptance Criteria:**` (colon inside bold); a bold heading's section had no end | `assets/spec-coverage-protocol.md:24` | fixed |
| LOW-002 | M1 | The claims heading and `[x]` claim regex were not widened along with the AC parser | `assets/spec-coverage-protocol.md:54` | fixed |
| LOW-003 | M2 | The generic Spec step depended on Phase 4.5, which was never ordered before dispatch | `SKILL.md:207` | fixed: ordering line in § Dispatch |
| LOW-004 | M1 | "PEs need no reference file at runtime" contradicted `REVIEW_MOVES`, and CONTRIBUTING had no exception (agents INFO-002 merged here) | `SKILL.md:142`, `CONTRIBUTING.md:33` | fixed |
| LOW-005 | M4 | A verbatim copy of the shared example `checked` passed `valid()` | `agents/pe-go.md:747` | fixed: `valid()` rejects a copied example |
| LOW-006 | M1 | pe-audio Constraints lacked "five passes and § Review Moves", so the CHANGELOG claim was false for it | `agents/pe-audio.md:711` | fixed |
| LOW-007 | M1 | init-project README still named `api/` dirs and an unconditional `server/` | `skills/init-project/README.md:14` | fixed |
| INFO-001 | M1 | pe-governance structural_check had no entry for skill assets or references | `agents/pe-governance.md:86` | fixed |
| INFO-002 | M5 | Story File Resolution re-fetched the body the Trigger already held | `SKILL.md:461` | fixed: reuses `issue.body` |
| INFO-003 | M6 | The Spec Coverage YAML example lacked `moves_coverage` | `assets/spec-coverage-protocol.md:267` | fixed |

### Action Items

#### Must Fix (blocks merge)
- [x] none

#### Should Fix
- [x] none

#### Consider
- [x] LOW-001 – LOW-007, INFO-001 – INFO-003 (all applied in `56a56df`)

---

## Review Round 3

**Verdict:** ⚠️ CHANGES REQUESTED

| | |
| - | - |
| **Reviewer** | Claude Code (`/code-reviewer`) |
| **Reviewed SHA** | `3ae7cb4761c476c57cc1abe51d2c8246a1a5181a` |
| **Date** | 2026-11-26 |

### Summary

All round-2 findings are resolved at `3ae7cb4`. One regression was introduced by a round-2 fix. The new section-end rule ended an `Acceptance Criteria` section at its first sub-heading or bold sub-label. That dropped ACs and could produce false SPEC-NO-AC or SPEC-MISSING findings. It is MEDIUM. Four LOW siblings and 1 INFO were also found.

All six are fixed in `dc48b6b`, and the fixes were checked directly:
- `extract_section` was simulated under python `re` on 6 AC-section shapes and 1 grouped claims section, and every one parses correctly;
- the `[[xX]]` check-off grep was run on a sample epic;
- the six synced Calibration Anchors still hash identical.

This is round 3 of `ROUND_CAP = 3`. `dc48b6b` has not been re-reviewed. A round 4 is the operator's call: proceed, abort or escalate.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-Governance | none | lint-shaped checks; AC and claims regexes run under python `re` on 18 inputs; section-end rule simulated on 5 sections |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-Governance | 6 fix hunks sibling-grepped: checkbox matchers (2 unfixed), Constraints ×7, runtime-read claim vs 7 PEs | Phase 4.5 order vs Asset Paths, Dispatch, generic Spec (0 gaps); `issue.body` lifetime | 5 AC-section shapes (3 drop ACs); 18 headings; empty body | regexes on 18 inputs; end rule on 5 sections (3 false negatives); `valid()` vs 16 examples | 3 paths: fetch → SPEC-LINK-UNVERIFIED, empty body → gate, gate advice (1 unreachable) | 1 changed example vs `valid()`; 14 PE example lines | 5 claims (runtime reads false for 6 PEs) |
| Primary | n/a — no human doc changed this round | n/a — no state | n/a — no parser in human docs | n/a — no guard | n/a — no call that can fail | n/a — no test added or changed | n/a — no claim added to human docs |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 1 | 0 |
| 🟢 LOW | 4 | 0 |
| ℹ️ INFO | 1 | 0 |

### In Scope Findings

#### 🟡 MEDIUM-001: Section-end rule truncated AC and claims sections at their first sub-heading

**Domains:** [Governance] · **Move:** M4
**Location:** `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md:25`

The rule "a section ends at the next heading or bold-only line" applied to `#` headings too. A `## Acceptance Criteria` holding `### Functional` / `### Non-functional` parsed zero ACs, and ACs after a `### Edge cases` were dropped. A PR body grouping claims under `### Addressed` / `### Deferred` parsed zero claims.

**Fixed in `dc48b6b`:** a single `extract_section` definition. A `#` section ends at the next heading of the same or fewer `#`. A bold or bare heading's section ends at the next `#` heading or bold-only line.

| ID | Move | Finding | Location | Disposition |
| - | - | - | - | - |
| LOW-001 | M4 | `valid()` could not recognise the example string the PE files carry | `SKILL.md:241` | fixed: the literal is named |
| LOW-002 | M1 | `done_at_target` and `verify_local` accepted only lowercase `[x]` | `SKILL.md:84`, `assets/spec-coverage-protocol.md:227` | fixed |
| LOW-003 | M1 | Failure Gate advised checking gh auth for a failure that no longer reaches it | `SKILL.md:488` | fixed |
| LOW-004 | M7 | "PEs read only dispatch assets" was false while six Calibration Anchors said to re-read SKILL.md | `SKILL.md:142`, 6 PE files | fixed: the pointer is dropped from all six synced anchors |
| INFO-001 | M4 | "none, and no frontmatter" read as a requirement | `agents/pe-governance.md:92` | fixed |

### Action Items

#### Must Fix (blocks merge)
- [x] none

#### Should Fix
- [x] MEDIUM-001 (fixed in `dc48b6b`, verified by simulation, not re-reviewed)

#### Consider
- [x] LOW-001 – LOW-004, INFO-001
- [ ] Round 4 on `dc48b6b`: the operator decides (ROUND_CAP reached)

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
