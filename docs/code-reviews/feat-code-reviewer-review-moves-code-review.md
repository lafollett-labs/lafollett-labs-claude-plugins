# Code Review: feat-code-reviewer-review-moves

**Verdict:** ⚠️ CHANGES REQUESTED

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

**Locked to SHA:** `d4a7493716198427316bcdecf66529a77c316bd7`
**Status:** ⚠️ Not mergeable — CHANGES REQUESTED. Round 2 reviews the remediation.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
