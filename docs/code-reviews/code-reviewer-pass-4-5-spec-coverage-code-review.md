# Code Review: code-reviewer-pass-4-5-spec-coverage

**Verdict:** ✅ APPROVED (Round 2)

| | |
| - | - |
| **Branch** | `claude/code-reviewer-pass-4-5-spec-coverage` |
| **PR** | [#3](https://github.com/clafollett/lafollettlabs-claude-plugins/pull/3) |
| **Author** | @clafollett |
| **Reviewer** | @clafollett |
| **Review Round** | 1 |
| **Reviewed SHA** | `36f3fe9a2d3d5286efc29a4dcf4569f47f467e27` |
| **Title** | feat(code-reviewer): Phase 4.5 Spec Coverage for story-linked PRs (v2.9.0) |
| **Files Changed** | 10 |
| **Lines Changed** | +412 / -3 |
| **Date** | 2026-05-17 |

---

## Summary

Asset-based architecture for Spec Coverage is correctly placed (protocol authoritative in `assets/spec-coverage-protocol.md` where reviewer agents can Read it). Frontmatter tools cover Read/Bash/Grep needs, no new permissions required, schema field names align across SKILL.md producer + PE consumer + asset. Four MEDIUMs surface around discoverability and silent-failure gates: PE Workflow blocks don't reference the new Spec Coverage section in their numbered steps (skim-test failure), `${CLAUDE_PLUGIN_ROOT}` substitution mechanism in SKILL.md is unspecified (risk of literal placeholder leaking to PEs), story file resolution has no failure gate (PEs can be dispatched with STORY_LINKED:true but unresolved STORY_FILE), and the 5 identical Spec Coverage blocks across PE files contradict CONTRIBUTING.md's documented sync convention.

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| -------- | -------- | ------------ |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 4 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 2 | 0 |

---

## In Scope Findings

### 🟡 MEDIUM-001: Spec Coverage section not referenced in PE Workflow numbered steps — skim-test failure

**Domains:** [Governance]
**Location:** `plugins/code-reviewer/agents/pe-go.md:641`, `pe-vue.md:674`, `pe-aws-infra.md:671`, `pe-governance.md:441`, `pe-devtools.md:439`

Each PE's `## Workflow` block enumerates concrete numbered steps that end at "Deliver YAML findings" (step 7 or 8) — the agent's execution roadmap. The new `## Spec Coverage (Story-Linked PRs)` section is appended AFTER Pass 5 / Self-Adversarial / blind_spot_scan and a `---` separator, with no entry in the Workflow numbered list pointing to it.

An agent reading the file top-to-bottom and following the numbered Workflow may execute steps 1-8 and emit YAML without ever scrolling into the Spec Coverage section. The dispatch input field `STORY_LINKED` lives in the dispatch contract, but the agent's own workflow doesn't reference checking for it. Surfaced via Pass 4 / agent_skim_test.

The asset-based design is correct (protocol authoritative in one file), but the trigger in each PE needs to be reachable from the Workflow's primary execution path.

**Recommendation:**

Add a numbered step to each PE's Workflow block referencing the Spec Coverage section. Example for pe-go (adjust step number per PE):

```
8. If dispatch_input.STORY_LINKED is true: execute § Spec Coverage
   (Story-Linked PRs) — append SPEC-* findings to YAML.
9. Deliver YAML findings (see Output Format). ...
```

Same insertion in pe-vue.md, pe-aws-infra.md, pe-governance.md, pe-devtools.md Workflow blocks.

---

### 🟡 MEDIUM-002: `${CLAUDE_PLUGIN_ROOT}` substitution mechanism unspecified in SKILL.md — risk calling agent passes literal placeholder

**Domains:** [Governance, Architecture]
**Location:** `plugins/code-reviewer/skills/code-reviewer/SKILL.md:298-309`

Phase 4.5 dispatch enrichment template (line 305):

```
SPEC_COVERAGE_PROTOCOL: ${CLAUDE_PLUGIN_ROOT}/skills/code-reviewer/assets/spec-coverage-protocol.md
```

Followed by prose at line 309:

> "${CLAUDE_PLUGIN_ROOT} is resolved by the calling agent before substitution — pass the absolute path literally so PEs don't need to resolve plugin paths from their (depth-1) context."

The intent is correct (calling agent resolves; PEs see absolute path), but there is no pseudocode step showing HOW the calling agent performs the resolution. A naive calling agent reading "pass it literally" may pass the literal STRING `${CLAUDE_PLUGIN_ROOT}/skills/code-reviewer/assets/spec-coverage-protocol.md` to PEs verbatim. PEs would then `Read()` a path containing an unresolved shell-variable placeholder and fail.

CONTRIBUTING.md:31 explicitly warns that `${CLAUDE_PLUGIN_ROOT}` substitution is unreliable from sub-agent prose. This SKILL.md change correctly relies on the calling agent (skill orchestrator) to do the substitution before dispatch — which IS where the env var is reliably available — but the resolution step needs to be explicit. Surfaced via Pass 4 / agent_skim_test + cross-file blind_spot_scan.

**Recommendation:**

Add an explicit resolve step before the Dispatch Input Enrichment template:

```
# Resolve plugin root once (calling agent has CLAUDE_PLUGIN_ROOT in env):
plugin_root = bash: echo "$CLAUDE_PLUGIN_ROOT"
spec_coverage_protocol_path = plugin_root + "/skills/code-reviewer/assets/spec-coverage-protocol.md"

Append these fields to each PE's dispatch input when story_linked:
  STORY_LINKED: true
  STORY_FILE: <absolute path resolved above>
  SPEC_COVERAGE_PROTOCOL: <spec_coverage_protocol_path — absolute, no ${...} placeholders>
  PR_NUMBER: <number>
```

Reinforces the contract that PEs receive only absolute paths.

---

### 🟡 MEDIUM-003: Story file resolution has no failure gate — STORY_LINKED can dispatch with missing STORY_FILE

**Domains:** [Governance, Robustness]
**Location:** `plugins/code-reviewer/skills/code-reviewer/SKILL.md:274-296`

Story File Resolution pseudocode tries three sources in priority: caller-provided `STORY_FILE` → local `.github-state.json` mapping → `gh issue view` body to a `/tmp` file. If all three fail (no caller arg, no local epic mapping, `gh issue view` rate-limited or network down), `story_file_path` is None.

Phase 4.5 then falls through to Dispatch Input Enrichment with `STORY_LINKED: true` but `STORY_FILE: <unresolved>`. PEs execute Spec Coverage protocol against a path that doesn't exist — `Read(STORY_FILE)` errors, asset parsing fails, every AC flags `SPEC-MISSING-*` against an empty `acs` list, or the PE itself errors. Surfaced via Pass 4 / silence_check.

**Recommendation:**

Add an explicit gate after the fallback step:

```
if story_file_path is None:
  # All three resolution paths failed — record blocking finding,
  # do NOT enrich dispatch (Phase 4.5 effectively skipped this round)
  record SPEC-STORY-FILE-UNRESOLVED finding in calling-agent's own
  report-time finding list:
    severity: MEDIUM
    title: "Story link detected but story file unresolvable"
    description: "PR closes story-labeled issue #<NNN> but neither
                  caller-provided STORY_FILE, local docs/epics/
                  mapping, nor gh issue view fallback resolved
                  a story file. Spec Coverage pass skipped."
    recommendation: "Pass STORY_FILE explicitly via dispatch
                     input, or open a local epic file mapped to
                     the GH issue."
  return  # do not enrich dispatch
```

---

### 🟡 MEDIUM-004: Five identical Spec Coverage blocks in PE files — sync drift risk, contradicts documented sync convention

**Domains:** [Governance, Maintainability]
**Location:** `plugins/code-reviewer/agents/pe-go.md:641-652`, `pe-vue.md:674-685`, `pe-aws-infra.md:671-682`, `pe-governance.md:441-452`, `pe-devtools.md:439-450` (+ `CONTRIBUTING.md:33-45`)

The new Spec Coverage section is duplicated verbatim across all 5 PE files (15 lines × 5 = 75 lines of identical governance content paid on every PE dispatch, story-linked or not).

Two specific concerns:

**(a) CONTRIBUTING.md inconsistency.** `CONTRIBUTING.md:33-45` documents a "sync convention for shared blocks" listing exactly which blocks must stay in sync across PE files (Calibration Anchor + six common lenses + How to Apply Pass 4). It explicitly states:

> "pe-devtools.md runs a different lens set (single-operator local threat model) and is NOT part of this sync."

The new Spec Coverage block adds a NEW shared block across all FIVE PEs — including pe-devtools — without updating CONTRIBUTING.md's sync convention. Future editors will not know they need to keep these five blocks in sync, AND the rule "pe-devtools not part of sync" is now silently violated.

**(b) Sync drift.** Today identical; in six months one PE changes wording, another adds a guard clause, and the dispatch contract diverges.

Surfaced via Pass 4 / two_agent_contradiction + blind_spot_scan.

**Recommendation:**

Either:

**(a)** Update `CONTRIBUTING.md` § Sync convention to add a new entry:

```
The Spec Coverage trigger block (`## Spec Coverage (Story-Linked PRs)`)
is shared across ALL FIVE PE files (pe-go, pe-vue, pe-aws-infra,
pe-governance, pe-devtools — NOT excluded like the Pass 4 lens set).
Edit all five together. The block intentionally stays slim because the
authoritative protocol lives in
skills/code-reviewer/assets/spec-coverage-protocol.md.
```

**OR (b)** Lean further into the asset-based design: replace each PE's 15-line block with a 3-line stub that just Reads the asset:

```
## Spec Coverage (Story-Linked PRs)

If dispatch_input.STORY_LINKED is true:
  Read(dispatch_input.SPEC_COVERAGE_PROTOCOL) and follow it.
Otherwise skip.
```

and move the optional `discharges_ac` annotation note to the asset itself. Reduces 75 lines of duplicated governance to 25 — single source-of-truth for the protocol.

---

### ℹ️ INFO-001: Multi-PE parallel dispatch produces 5x duplicate SPEC-* findings — Phase 4 dedupes, but redundant bash work upstream

**Domains:** [Performance, Architecture]
**Location:** `plugins/code-reviewer/skills/code-reviewer/SKILL.md:253-315`

When `approach == multi_pe` (mixed-stack diff), all matching PEs run Spec Coverage in parallel. Each independently:

- Reads the asset
- Reads `STORY_FILE`
- Calls `gh pr view <N>` for PR description
- Calls `gh issue view` for deferral verification
- Runs `git log` / `git diff` for evidence verification

Findings collide identically. Phase 4 de-duplication consolidates them correctly, so output is right — but the wasted bash + tool calls scale linearly with PE count.

An alternative is to designate ONE PE (e.g., pe-governance, which is already domain-adjacent to PR description / story file content) as Spec Coverage owner; other PEs skip the section. Trades a single-PE bottleneck for less wasted work. Surfaced via Pass 4 / instruction_leak_across_personas.

Not a defect — flagging for awareness during a future release.

**Recommendation:**

Consider for a future release: gate the Spec Coverage trigger in non-governance PEs:

```
if dispatch_input.STORY_LINKED is true AND
   (dispatch_input.SPEC_COVERAGE_OWNER is None OR
    dispatch_input.SPEC_COVERAGE_OWNER == this_pe_name):
  Read(SPEC_COVERAGE_PROTOCOL) and run.
```

SKILL.md Phase 4.5 sets `SPEC_COVERAGE_OWNER: pe-governance` when multiple PEs dispatched. Single-PE dispatches set it to whichever PE matched. Phase 4 de-dup logic stays unchanged (defense in depth).

---

### ℹ️ INFO-002: Context-budget weight — 75 lines paid by every PE dispatch even on non-story PRs

**Domains:** [Governance, Performance]
**Location:** `plugins/code-reviewer/agents/pe-*.md` (Spec Coverage section + transitions)

Governance files load into PE context on every invocation. The 15-line Spec Coverage block in each PE × 5 PEs = 75 lines of governance prose paid on every PE invocation, including the vast majority of PRs (chores, bugfixes, tasks) where `STORY_LINKED` is false and the block is skipped.

The token cost is small (15 lines per PE), but it compounds with the repo's other shared blocks (Pass 4 Calibration Anchor + six common lenses are similarly duplicated across 4 PEs per CONTRIBUTING.md). Tracking direction-of-travel — surfaced via Pass 4 / context_budget_creep.

Mitigation is covered by MEDIUM-004 option (b) above (slim 3-line stub + asset is single source).

**Recommendation:**

Address via MEDIUM-004 (b) — or accept the cost as the price of sub-agent self-containment per CONTRIBUTING.md.

---

## Out of Scope

None. All findings are scoped to changes introduced by this PR.

---

## Action Items

### Must Fix (blocks merge)

None.

### Required (CHANGES REQUESTED)

- [ ] **MEDIUM-001** — Add a numbered Workflow step to each PE referencing the Spec Coverage section
- [ ] **MEDIUM-002** — Add explicit `${CLAUDE_PLUGIN_ROOT}` resolve pseudocode to SKILL.md Phase 4.5 before the Dispatch Input Enrichment template
- [ ] **MEDIUM-003** — Add failure-gate `if story_file_path is None` after the fallback resolution in SKILL.md Phase 4.5
- [ ] **MEDIUM-004** — Either (a) update `CONTRIBUTING.md` sync convention to include the new Spec Coverage block (and document that pe-devtools IS in this sync), OR (b) slim each PE's Spec Coverage block to a 3-line asset-Read stub

### Optional (INFO)

- [ ] **INFO-001** — Future release: add `SPEC_COVERAGE_OWNER` dispatch field to avoid 5x duplicate emission
- [ ] **INFO-002** — Mitigated by adopting MEDIUM-004 (b)

---

## Files Reviewed

| File | Findings |
| ---- | -------- |
| `plugins/code-reviewer/skills/code-reviewer/SKILL.md` | 2 (MED-002, MED-003) + shared (INFO-001) |
| `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md` | 0 |
| `plugins/code-reviewer/agents/pe-go.md` | shared (MED-001, MED-004, INFO-002) |
| `plugins/code-reviewer/agents/pe-vue.md` | shared (MED-001, MED-004, INFO-002) |
| `plugins/code-reviewer/agents/pe-aws-infra.md` | shared (MED-001, MED-004, INFO-002) |
| `plugins/code-reviewer/agents/pe-governance.md` | shared (MED-001, MED-004, INFO-002) |
| `plugins/code-reviewer/agents/pe-devtools.md` | shared (MED-001, MED-004, INFO-002) |
| `.claude-plugin/marketplace.json` | 0 (version bump consistent with repo convention) |
| `plugins/code-reviewer/.claude-plugin/plugin.json` | 0 (version bump; description still accurate for non-story PRs) |
| `CHANGELOG.md` | 0 (comprehensive entry, references architecture + motivation) |

---

## Merge Eligibility

**Locked to SHA:** `ae927fb1ea46be1d04d8e9985fa5c1321748170c`
**Status:** ✅ Mergeable IF `git rev-parse HEAD == ae927fb1ea46be1d04d8e9985fa5c1321748170c`. Any commit after this SHA invalidates this round and requires re-review (`/code-reviewer` again before merge).

---

## Review Round 2

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | @clafollett |
| **Reviewed SHA** | `ae927fb1ea46be1d04d8e9985fa5c1321748170c` |
| **Date** | 2026-05-17 |

### Summary

All 4 MEDIUMs from Round 1 are genuinely discharged. PE Workflow blocks now reference the Spec Coverage section in their numbered steps (MED-001), SKILL.md Phase 4.5 has explicit `${CLAUDE_PLUGIN_ROOT}` resolve pseudocode with realpath fallback (MED-002), the story_file_path None failure gate emits `SPEC-STORY-FILE-UNRESOLVED` at calling-agent level and returns before Dispatch Input Enrichment (MED-003), and the 5 PE Spec Coverage blocks slim from 15-line duplicates to 3-line asset-Read stubs with the `discharges_ac` annotation rule moved into the asset as single source of truth (MED-004, Option B). pe-governance found no new in-scope defects in the Round 2 changes.

### Findings Overview

| Severity | In Scope | Out of Scope |
| -------- | -------- | ------------ |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 0 | 0 |

### Round 1 Remediation Verification

| Finding | Status | Evidence |
| ------- | ------ | -------- |
| MED-001 — Workflow step skim-test | ✅ Discharged | All 5 PEs now have a numbered step before "Deliver YAML" referencing § Spec Coverage |
| MED-002 — `${CLAUDE_PLUGIN_ROOT}` substitution | ✅ Discharged | `SKILL.md:330-338` explicit `plugin_root = bash: echo "$CLAUDE_PLUGIN_ROOT"` + realpath fallback; PEs receive absolute paths |
| MED-003 — Silent-failure gate | ✅ Discharged | `SKILL.md:303-322` initializes `story_file_path = None`, threads None through all three resolution paths, gates with explicit `return` before Dispatch Input Enrichment, emits `SPEC-STORY-FILE-UNRESOLVED` finding |
| MED-004 — Sync drift / 5 identical blocks | ✅ Discharged (Option B) | Each PE's Spec Coverage section slimmed to 3-line asset-Read stub; `discharges_ac` annotation rule moved to asset § "Optional Annotation on Stack Findings". Net: −47 lines across PE files, single source of truth in the asset |

### Action Items

#### Must Fix (blocks merge)

None.

#### Should Fix

None.

#### Consider

- **INFO-001 from Round 1** (still applicable): For a future release, consider a `SPEC_COVERAGE_OWNER` dispatch field so only ONE designated PE runs Spec Coverage instead of all dispatched PEs running it in parallel (Phase 4 dedupes the duplicates correctly, but it's wasted bash work). Non-blocking — flagged for awareness during a future refactor.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
