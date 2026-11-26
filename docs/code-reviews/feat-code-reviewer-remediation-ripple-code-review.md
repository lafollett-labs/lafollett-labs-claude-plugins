# Code Review: feat-code-reviewer-remediation-ripple

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Branch** | `feat/code-reviewer-remediation-ripple` |
| **PR** | not yet opened |
| **Author** | @clafollett |
| **Reviewer** | Claude Code (`/code-reviewer` 2.13.0) |
| **Review Round** | 1 |
| **Reviewed SHA** | `3d8e18d6344081b28cbfec8dc4b0b7422148b96e` |
| **Title** | code-reviewer 2.14.0: siblings, introduced_by, remediation pre-flight, fix cascade |
| **Files Changed** | 16 |
| **Lines Changed** | +151 / -64 |
| **Date** | 2026-11-26 |

---

## Summary

The branch adds `siblings` and `introduced_by` to the finding schema and a remediation pre-flight with ripple receipts. It also adds a fix-cascade ratio to every round and the halt message, plus the two carry-overs from 2.13.0. Two pe-governance reviews ran on the installed 2.13.0 definition, one for the skill and assets and one for the agents. With a Primary review of the human docs, they found 4 MEDIUM, all in the new contracts:
- the `introduced_by` enum has no value for a STILL_PRESENT re-flag or for new code;
- `siblings` excludes sites where the same defect recurs;
- ripple receipts are not bound to a SHA;
- the pre-flight orders fixes for LOW, INFO and out-of-scope findings.

---

## Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-Governance (skill + assets) | none | lint-shaped checks; `introduced_by` tree driven with 5 inputs; `extract_section` edge cases |
| PE-Governance (agents) | none | lint-shaped checks; md5 of the 3 synced blocks (Inputs bullet ×7, Review Moves paragraph ×7, Calibration Anchor ×6) |

---

## Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-Governance (skill + assets) | 6 changed contracts → 46 restatements grepped; paragraph hash ×7; version rule | 3 round-carried states through rounds 2–3 and post-approval invalidation | `introduced_by` tree × 5 inputs; pre-flight × 3 classes; receipts absent/none/present; `extract_section` × 3 | 2 new `valid()` clauses; fence rule | 2 paths: PRIOR REVIEW omitted, FIX DIFF unresolvable | 11 changed examples vs the new rules (1 contradicts) | 4 CHANGELOG claims; 2 label claims |
| PE-Governance (agents) | 3 synced blocks md5-identical; contract → 7 examples, asset, SKILL, template, 2 READMEs, CHANGELOG; 1 fix → 6 unfixed pointers | `introduced_by` vs STILL_PRESENT/RESOLVED/NEW in 7 workflows | classifier × 5 input kinds (2 uncovered); SPEC-* exemption ×3 | 2 `valid()` clauses vs the paragraph's MISSING rule | 2 paths: prior doc missing, asset unreadable | 9 example findings vs the siblings rule (2 contradict) | 4 claims |
| Primary | CHANGELOG, 2 READMEs, 2 manifests vs the new contracts (2 drifts) | n/a — human docs and manifests hold no state | n/a — no branch, parser or limit | n/a — no guard | n/a — no call that can fail | n/a — no test added or changed | versions 2.14.0 / 1.34.0 vs CHANGELOG |

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 4 | 0 |
| 🟢 LOW | 10 | 0 |
| ℹ️ INFO | 2 | 0 |

---

## In Scope Findings

### 🟡 MEDIUM-001: `introduced_by` has no value for a STILL_PRESENT re-flag or for new code

**Domains:** [Governance] · **Move:** M3
**Location:** `plugins/code-reviewer/skills/code-reviewer/assets/review-moves.md:103`
**Siblings:** the enum at `SKILL.md:246` and `:783`, `review-moves.md:115`, `summary-report-template.md:187`, `skills/code-reviewer/README.md:109`, `CHANGELOG.md:15`, and the example comment in all 7 PEs

Every PE re-flags an unfixed prior finding as STILL_PRESENT. The classifier sends it to `missed`, which is false, because it was reported. If the PE tags it with its own prior id instead, the fix cascade counts it as fix-caused. A round where nothing was fixed then reads as near n/n churn. Findings in new non-fix commits also land in `missed`. Found by both PE reviews.

---

### 🟡 MEDIUM-002: `siblings` excludes sites where the same defect recurs

**Domains:** [Governance] · **Move:** M6
**Location:** `plugins/code-reviewer/skills/code-reviewer/assets/review-moves.md:30`
**Siblings:** the "stating what the fix changes" comment at `SKILL.md:765`, `review-moves.md:114`, the 7 PE examples, `skills/code-reviewer/README.md:10`, `plugins/code-reviewer/README.md:99`

The predicate covers rules, contracts, definitions and repeated values only. SKILL.md's own example lists a recurring listener leak as a sibling. Under the narrow rule the remediator fixes one site, and M1's fix rule flags the other site next round.

---

### 🟡 MEDIUM-003: Ripple receipts are not bound to a SHA

**Domains:** [Governance] · **Move:** M2
**Location:** `plugins/code-reviewer/skills/code-reviewer/SKILL.md:288`
**Siblings:** the receipt shape at `SKILL.md:304`, `:331` and `:746`, `review-moves.md:97`, the Inputs bullet in 7 PEs, `plugins/code-reviewer/README.md:102`, `CHANGELOG.md:18`

AUTHOR RECEIPTS count only when they match `reviewed_sha`. Ripple receipts from a PR body or a hand-off have no SHA, so a previous round's receipts pass as current and steer M1 toward stale rules.

---

### 🟡 MEDIUM-004: The pre-flight orders fixes for every finding, LOW, INFO and out-of-scope included

**Domains:** [Governance] · **Move:** M3
**Location:** `plugins/code-reviewer/skills/code-reviewer/SKILL.md:742`
**Siblings:** the print step at `SKILL.md:728`, `plugins/code-reviewer/README.md:101`, `CHANGELOG.md:18`

That contradicts the Verdict Logic, which says LOW and INFO are awareness only, and Phase 2 scope discipline. The extra fixes grow the next fix diff and pull pre-existing code into scope, which is the churn the pre-flight exists to stop.

---

### 🟢 LOW findings

| ID | Move | Finding | Location | Siblings |
| - | - | - | - | - |
| LOW-001 | M1 | The synced paragraph gates `introduced_by` on "round 2", which no PE is told; pe-devtools defaults to round 1 | `agents/pe-devtools.md:446` | the paragraph in the other 6 PEs, `SKILL.md` Dispatch Input |
| LOW-002 | M1 | The Phase 5 pointer was removed, but "Apply the SKILL.md Severity Definitions calibration anchor" remains in the same synced block | `agents/pe-governance.md:217` | the same line in pe-go, pe-vue, pe-rust, pe-aws-infra, pe-audio |
| LOW-003 | M6 | pe-rust and pe-vue example siblings drop their subdir prefix, and pe-vue's restates nothing the XSS fix changes | `agents/pe-rust.md:769` | `agents/pe-vue.md:950`, the "FULL file paths" rule in 7 PEs |
| LOW-004 | M1 | The Spec Coverage YAML example's stack finding lacks the now-required `siblings` | `assets/spec-coverage-protocol.md:279` | none |
| LOW-005 | M1 | Calling-agent cross-PE findings, and an equal-severity merge, have no `siblings` / `introduced_by` rule | `SKILL.md:365` | none |
| LOW-006 | M3 | The siblings step sits inside M1, before M2–M7 and Pass 5 produce their findings | `assets/review-moves.md:29` | the `introduced_by` loop in § Round 2+ |
| LOW-007 | M2 | `introduced_by` ids recur per round, and PRIOR REVIEW is marked optional | `SKILL.md:246` | `SKILL.md:326`, `review-moves.md:104` |
| LOW-008 | M1 | The pre-flight's "record why not" has nowhere to go in a receipt | `SKILL.md:744` | `review-moves.md:98` |
| LOW-009 | M1 | The skill README loop diagram omits the pre-flight, receipts and cascade | `skills/code-reviewer/README.md:92` | none |
| LOW-010 | M7 | CHANGELOG says `valid()` requires `siblings` on every finding, but SPEC-* findings are exempt | `CHANGELOG.md:17` | none |

### ℹ️ INFO

| ID | Move | Finding | Location |
| - | - | - | - |
| INFO-001 | M1 | The new Inputs bullet is synced across 7 PEs but not listed in CONTRIBUTING's sync convention | `CONTRIBUTING.md:48` |
| INFO-002 | M7 | "spot-checked" and "exhaustive" name a mode split the asset never defines | `assets/summary-report-template.md:157` |

---

## Action Items

### Required

- [ ] MEDIUM-001: fix `assets/review-moves.md:103` + 13 siblings
- [ ] MEDIUM-002: fix `assets/review-moves.md:30` + 12 siblings
- [ ] MEDIUM-003: fix `SKILL.md:288` + 13 siblings
- [ ] MEDIUM-004: fix `SKILL.md:742` + 3 siblings

### Optional

- [ ] LOW-001 – LOW-010, INFO-001 – INFO-002 (siblings as listed)

---

## Files Reviewed

| File | Findings |
| - | - |
| `plugins/code-reviewer/skills/code-reviewer/assets/review-moves.md` | 4 |
| `plugins/code-reviewer/skills/code-reviewer/SKILL.md` | 5 |
| `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md` | 1 |
| `plugins/code-reviewer/skills/code-reviewer/assets/summary-report-template.md` | 1 |
| `plugins/code-reviewer/agents/pe-*.md` (7) | 3 |
| `CHANGELOG.md`, `CONTRIBUTING.md`, READMEs, manifests | 3 |

---

## Merge Eligibility

**Locked to SHA:** `83351e353fc37ac41240a3fe7c90f879c8658dc2`
**Status:** ✅ Mergeable IF `git rev-parse HEAD == 83351e353fc37ac41240a3fe7c90f879c8658dc2`. Any commit after this SHA invalidates this round and requires re-review (`/code-reviewer` again before merge).

---

## Review Round 2

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | Claude Code (`/code-reviewer` 2.13.0) |
| **Reviewed SHA** | `83351e353fc37ac41240a3fe7c90f879c8658dc2` |
| **Date** | 2026-11-26 |
| **Fix cascade** | 4 / 7 in-scope findings introduced by a prior fix |
| **Ripple receipts** | 9 spot-checked |

### Summary

Round 2 reviewed the round-1 fix (`3d8e18d..83351e3`) against 9 ripple receipts. All 16 round-1 findings are RESOLVED. The 7 new findings are LOW or INFO. Four were caused by round-1 fixes, and the spot-check caught where the receipts drifted: the receipt-shape receipt counted 8 lines that lack the new `; kept` clause, and the gating receipt left out 5 lines it should have kept.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-Governance (skill + assets) | none | lint-shaped checks; `§` refs resolve; Finding Keys classifier × 6 inputs; receipts absent / none / present / stale |
| PE-Governance (agents) | none | lint-shaped checks; md5 of 5 synced blocks (Inputs ×7, Review Moves paragraph ×7, Calibration Anchor ×6, scope comment ×7, probes frame ×7) |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-Governance (skill + assets) | 9 receipts spot-checked; 11 fix-diff hunks grepped; 16 round-1 findings checked | receipt lifecycle × 3 cases; ids across rounds 2→3 and a post-approval round | classifier × 6 inputs; pre-flight × 3 verdicts; receipts × 4 states | 3 guards: sha filter, spot-check count, `valid()` enum | 3 paths: receipts dropped by the sha filter, PRIOR REVIEW missing, no RIPPLE RECEIPTS line | 6 YAML examples vs `valid()` (1 mixes shapes) | 7 CHANGELOG claims; 2 README claims; 3 `§` refs |
| PE-Governance (agents) | 6 receipts spot-checked; 5 synced blocks md5-identical | `introduced_by` gate vs round state in 7 PE workflows | Inputs bullet × 4 receipt shapes; example blocks × 2 shapes | FIX DIFF gate vs `valid()` round gate; MISSING rule; repo-root rule | n/a — the fix diff adds no command, call or read to the agent files | 12 example findings vs the new keys (3 mix shapes) | 4 claims |
| Primary | 7 changed rules grepped across all non-review markdown before dispatch (0 stale) | n/a — human docs hold no state | n/a — no branch or parser | n/a — no guard | n/a — no call | n/a — no test | versions 2.14.0 / 1.34.0 unchanged since round 1 |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 5 | 0 |
| ℹ️ INFO | 2 | 0 |

### In Scope Findings

#### 🟢 LOW findings

| ID | Move | Introduced by | Finding | Location | Siblings |
| - | - | - | - | - | - |
| LOW-001 | M1 | LOW-008 | The synced PE "Ripple receipts" Inputs bullet gives the receipt shape without the `; kept <path:line> — <why>` clause the fix added (both PE reviews) | `agents/pe-governance.md:23` | the bullet in the other 6 PEs, `plugins/code-reviewer/README.md:103` |
| LOW-002 | M4 | MEDIUM-003 | The receipt filter `sha == reviewed_sha` is a literal equality: a 7-char receipt SHA fails it, and the drop is silent | `SKILL.md:291` | `SKILL.md:753`, `:572`, `summary-report-template.md:157`, `CHANGELOG.md:20` |
| LOW-003 | M4 | missed | The spot-check makes a count mismatch the finding, so an aligned restatement a receipt counted differently gets flagged | `assets/review-moves.md:93` | none |
| LOW-004 | M6 | missed | Example result blocks put a finding with `introduced_by` beside one without it, a shape `valid()` rejects from round 2 | `SKILL.md:772` | `agents/pe-governance.md:544`, `agents/pe-go.md:766` |
| LOW-005 | M7 | missed | The READMEs say every round-2 finding names the prior fix that caused it; most carry another enum value | `skills/code-reviewer/README.md:10` | `plugins/code-reviewer/README.md:103` |

#### ℹ️ INFO

| ID | Move | Introduced by | Finding | Location |
| - | - | - | - | - |
| INFO-001 | M7 | LOW-002 | CHANGELOG omits the Pass 4 severity-block change in the 6 synced PEs | `CHANGELOG.md:24` |
| INFO-002 | M1 | LOW-001 | The gating receipt's kept list omits 5 round-gated lines that are correct as written; receipt only, no file change | `SKILL.md:247` |

### Action Items

#### Consider
- [ ] LOW-001: fix `agents/pe-governance.md:23` + 7 siblings
- [ ] LOW-002: fix `SKILL.md:291` + 4 siblings
- [ ] LOW-003: fix `assets/review-moves.md:93` + 0 siblings
- [ ] LOW-004: fix `SKILL.md:772` + 2 siblings
- [ ] LOW-005: fix `skills/code-reviewer/README.md:10` + 1 sibling
- [ ] INFO-001: fix `CHANGELOG.md:24` + 0 siblings

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
