# Code Review: feat-code-reviewer-rust-audio-pes

**Verdict:** ✅ APPROVED (Round 3)

| | |
| - | - |
| **Branch** | `feat/code-reviewer-rust-audio-pes` |
| **Reviewer** | @Cali LaFollett (pe-governance dispatched) |
| **Review Round** | 1 |
| **Reviewed SHA** | `272dfde1e417f787f81344840313a2e9d60d79b8` |
| **Title** | pe-rust and pe-audio PEs, Vite PWA lenses in pe-vue, local story linkage for Spec Coverage |
| **Files Changed** | 15 |
| **Lines Changed** | +1981 / -168 |
| **Date** | 2026-11-26 |

---

## Summary

The branch adds `pe-rust` (stack) and `pe-audio` (domain) agents, extends `pe-vue` to Vite SPAs/PWAs, wires both into SKILL.md routing and cross-PE rules, and lets Phase 4.5 resolve stories from local `docs/epics` codes without GitHub. pe-governance found no blocking defects but six MEDIUMs: a domain-PE diff command built from brace globs git cannot parse, woodwind-specific rules applied as blocking HIGHs to every audio project, two silent-skip paths (non-`# Story:` H1s, masked `cargo audit`), a false HIGH on vite-plugin-pwa's default `navigateFallback`, and shell metacharacters reachable from a PR-body deferral path. Manifests, CHANGELOG, version bumps and table separators pass the primary's checks.

---

## Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| pe-governance | none | lint-shaped checks only (markdown) |
| Primary (generic, human docs + manifests) | — | JSON valid ×all manifests; marketplace ↔ plugin.json agree; no hardcoded marketplace keys; no `\|---\|` separators in added lines; `code-reviewer` 2.11.0 → 2.12.0, marketplace 1.31.0 → 1.32.0 |

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 6 | 0 |
| 🟢 LOW | 9 | 1 |
| ℹ️ INFO | 0 | 1 |

---

## In Scope Findings

| ID | Location | Finding | Recommendation |
| - | - | - | - |
| 🟡 MEDIUM-001 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:268` | A domain PE's DIFF COMMAND is built from `domain_paths`, whose brace globs (`**/{audio,dsp,pitch}/**/*.{rs,…}`) git pathspecs do not support — quoted, the diff is empty and pe-audio can return `findings: []`; unquoted, zsh errors. | Pass a domain PE the literal diff files its globs matched. |
| 🟡 MEDIUM-002 | `plugins/code-reviewer/agents/pe-audio.md:229` | Product-specific rules fire as blocking HIGHs everywhere: voice processing must be off for every `getUserMedia` (wrong for RTC/dictation), `extreme_instrument` tests fixed 27.5 Hz / 4.5 kHz, "woodwind" defaults; pe-vue flags `registerType: 'autoUpdate'` HIGH even without a live session. | Condition on analysis use and the project's declared range; flag autoUpdate only when the app has a live-session state. |
| 🟡 MEDIUM-003 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:390` | A resolved story code whose file's first H1 is not `# Story:`/`# Epic:` (hand-written story) is silently not linked and the Failure Gate never fires. | Exclude only known non-story types (`# Task:`, `# Bug:`). |
| 🟡 MEDIUM-004 | `plugins/code-reviewer/agents/pe-rust.md:401` | `cargo audit 2>/dev/null \|\| true` / `cargo deny check …` make a missing tool look like a clean run and hide cargo-deny's stderr diagnostics — contradicts pe-rust's own "skipped — not installed" rule. | Version-probe each tool; record skipped + INFO; capture `2>&1` and exit status. |
| 🟡 MEDIUM-005 | `plugins/code-reviewer/agents/pe-vue.md:290` | HIGH for unset `navigateFallback`, but vite-plugin-pwa's generateSW defaults it to `index.html`. | Flag only when explicitly nulled/denylisted under vite-plugin-pwa, or when a hand-written / injectManifest SW has no navigation fallback. |
| 🟡 MEDIUM-006 | `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md:80` | Deferral capture `\S+\.md` accepts `$(…)`, backticks and `../` from a contributor-written PR body, which then reach a Bash existence check. | Restrict to `[A-Za-z0-9._/-]+\.md`, reject `..` and leading `/`, check with Read/Glob not Bash; same charset for evidence `file:line`. |
| 🟢 LOW-001 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:327` | New cross-PE rules read data no PE emits (export lists, "no allocation" claims, pe-vue mic teardown, "live session"). | Let the calling agent compute export lists; phrase the rest as finding-overlap merges; give pe-vue's lifecycle check mic/AudioContext teardown. |
| 🟢 LOW-002 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:378` | `pr.title`/`pr.body` never fetched; `story_file_path` from `grep -rl` is repo-relative but STORY_FILE must be absolute. | Fetch title/body when `pr_number`; `realpath` before enrichment. |
| 🟢 LOW-003 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:391` | Trigger comments number 1, 3, 2 against execution order; "— unchanged" describes the diff. | Number in execution order; drop "unchanged". |
| 🟢 LOW-004 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:77` | Uppercase non-story tokens (UTF-8, SHA-256, ES-2022) count as declared codes, fire the Failure Gate and name the review doc. | Declared only when the prefix is used by some `**Code:** <PREFIX>-` line. |
| 🟢 LOW-005 | `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md:228` | "Done in its epic" grep expects `- [x] <CODE>` only; bold or link forms never match. | Widen to `\[x\]\s*(\*\*\|\[)?<code>\b`. |
| 🟢 LOW-006 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:478` | Phase 4.5 severity summary drifted from the protocol's table (DEFER-CLOSED, DEFER-UNVERIFIED, FORMAT at LOW). | Defer to the protocol's table. |
| 🟢 LOW-007 | `plugins/code-reviewer/agents/pe-audio.md:122` | Allocation grep has a backtick inside double quotes — bash syntax error. | Single-quote the pattern. |
| 🟢 LOW-008 | `plugins/code-reviewer/agents/pe-rust.md:95` | `wasm-pack test` self-installs the target / wasm-bindgen-cli; "never ./..." is a Go-ism; round-continuity path is relative to the workspace subdir. | Gate wasm-pack on the installed target; use `<worktree>/docs/code-reviews/…`. |
| 🟢 LOW-009 | `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md:55` | Two justification comments that change no behaviour. | Delete; keep `# newest first`. |

---

## Out of Scope

| Severity | Issue | Location |
| - | - | - |
| 🟢 LOW | pe-vue / pe-go issue-linkage check still requires a PR body `Closes #NNN`; pe-rust now accepts a branch story code. | `plugins/code-reviewer/agents/pe-vue.md:434` |
| ℹ️ INFO | SKILL.md says each agent pins `claude-opus-4-7`; no agent frontmatter sets `model:`. | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:125` |

---

## Action Items

### Must Fix (blocks merge)

- (none)

### Required

- [ ] MEDIUM-001 — literal file list for domain-PE diff commands
- [ ] MEDIUM-002 — condition pe-audio/pe-vue product-specific HIGHs
- [ ] MEDIUM-003 — link any story-code file except Task/Bug
- [ ] MEDIUM-004 — un-mask cargo audit / cargo deny
- [ ] MEDIUM-005 — navigateFallback rule matches vite-plugin-pwa defaults
- [ ] MEDIUM-006 — safe charset + no-shell check for deferral/evidence paths

### Optional

- [ ] LOW-001 … LOW-009

---

## Files Reviewed

| File | Findings |
| - | - |
| `plugins/code-reviewer/skills/code-reviewer/SKILL.md` | 6 |
| `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md` | 3 |
| `plugins/code-reviewer/agents/pe-rust.md` | 2 |
| `plugins/code-reviewer/agents/pe-audio.md` | 2 |
| `plugins/code-reviewer/agents/pe-vue.md` | 2 |
| `plugins/code-reviewer/skills/init-project/SKILL.md` | 0 |
| `.claude-plugin/marketplace.json`, `plugins/code-reviewer/.claude-plugin/plugin.json`, `CHANGELOG.md`, READMEs, `CONTRIBUTING.md`, YAML template | 0 (primary) |

---

## Merge Eligibility

**Locked to SHA:** `dba6c75` (Round 3)
**Status:** ✅ Mergeable IF the plugin content equals `dba6c75` (later commits on this branch touch only this review doc). Any later change under `plugins/` invalidates this round.

---

## Review Round 2

**Verdict:** ⚠️ CHANGES REQUESTED

| | |
| - | - |
| **Reviewer** | @Cali LaFollett (pe-governance dispatched) |
| **Reviewed SHA** | `298bbf8` |
| **Fix diff** | `272dfde..298bbf8` |
| **Date** | 2026-11-26 |

### Summary

All six round-1 MEDIUMs and LOW-001…LOW-007, LOW-009 are RESOLVED, as is the out-of-scope linkage LOW. LOW-008 is PARTIAL: `never ./...` stays because it sits in the § Test Budget block that CONTRIBUTING requires to be identical across the four suite-running PEs. Two new MEDIUMs: commit-subject story codes can link an unrelated or shipped story and BLOCK a fix/chore branch, and two repo-derived strings (a `**Code:**` value in a contributor-added file, and `story_file_path` before `realpath`) still reach Bash unvalidated.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| pe-governance | none | lint-shaped checks; all named § refs resolve; frontmatter tools ⊇ body tool calls; BSD grep confirms the widened epic done-check matches bold/link forms and not `LT-020` |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 2 | 0 |
| 🟢 LOW | 5 | 0 |
| ℹ️ INFO | 0 | 1 |

### In Scope Findings

| ID | Location | Finding | Recommendation |
| - | - | - | - |
| 🟡 MEDIUM-001 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:372` | Any commit subject naming a resolving code (`fix(LT-01): …`, `docs: tick LT-01`) links that story, including shipped ones, and every AC becomes a blocking SPEC-MISSING. | Accept subject codes only from `feat` subjects naming one distinct code; never link a story already checked off at `<target>`. |
| 🟡 MEDIUM-002 | `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md:225` | `verify_local` interpolates a `**Code:**` value from a contributor-added file into a double-quoted grep; the Trigger `realpath`s a repo-derived filename. | Validate code as `^[A-Z]{2,5}-[0-9]+$` and paths as `^[A-Za-z0-9._/-]+$` without `..`; single-quote in Bash. |
| 🟢 LOW-001 | `plugins/code-reviewer/agents/pe-vue.md:428` | Lifecycle rule flags shared module-level AudioContext singletons HIGH and out-ranks pe-vue's own wake-lock rule. | Per-instance resources only; leave wake lock to its own rule; extend the verification grep. |
| 🟢 LOW-002 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:330` | Cross-PE export list misses signature changes under an unchanged attribute, methods in `#[wasm_bindgen] impl`, and `js_name`. | Build it from changed fn signatures under `#[wasm_bindgen]` (direct or impl); grep `js_name` when set. |
| 🟢 LOW-003 | `plugins/code-reviewer/agents/pe-audio.md:153` | `range` is one pair, but two checks read per-profile data. | Resolve `profiles` and derive `range`. |
| 🟢 LOW-004 | `plugins/code-reviewer/agents/pe-audio.md:296` | Fixture matrix still applies extremes with no range, odd-harmonic timbre universally, and detector cases to synthesis. | Gate each case. |
| 🟢 LOW-005 | `plugins/code-reviewer/agents/pe-rust.md:65` | PARTIAL LOW-008: `never ./...` wording; `wasm-pack test` can download wasm-bindgen-cli. | Gate wasm-pack on a matching installed `wasm-bindgen`; wording kept for the sync convention. |

### Out of Scope

| Severity | Issue | Location |
| - | - | - |
| ℹ️ INFO | STILL_PRESENT: SKILL.md says each agent pins `claude-opus-4-7`; no agent sets `model:`. | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:128` |

### Action Items

#### Should Fix
- [ ] MEDIUM-001 — restrict commit-subject story links; skip shipped stories
- [ ] MEDIUM-002 — validate repo-derived code and path strings before Bash

#### Consider
- [ ] LOW-001 … LOW-005

---

## Review Round 3

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | @Cali LaFollett (pe-governance dispatched) |
| **Reviewed SHA** | `dba6c75` |
| **Fix diff** | `298bbf8..dba6c75` |
| **Date** | 2026-11-26 |

### Summary

Both round-2 MEDIUMs and all round-2 LOWs are RESOLVED, including the out-of-scope model-pin INFO. Commit-subject links now require a `feat` subject that names exactly one resolving code. Stories already checked off at the target never link, and repo-derived paths must pass `safe_path` before any shell use. Four LOWs remain; they are awareness-only and do not block. The round cap has been reached, so they are left for a follow-up rather than a fourth round.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| pe-governance | none | lint-shaped checks; named § refs resolve; frontmatter tools ⊇ body calls in all 7 PEs; temp-repo run of `done_at_target` (plain/bold/link forms, `LT-04` ≠ `LT-040`), `story_code` grep and the `feat` subject filter; § Test Budget block identical across pe-go / pe-vue / pe-rust / pe-aws-infra |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 4 | 0 |
| ℹ️ INFO | 0 | 0 |

### In Scope Findings

| ID | Location | Finding | Recommendation |
| - | - | - | - |
| 🟢 LOW-001 | `plugins/code-reviewer/skills/code-reviewer/assets/spec-coverage-protocol.md:214` | The deferral `<CODE>` branch passes a `grep -rl` filename to `realpath` without the `safe_path` check. A contributor-added file named `…$(…).md` that carries a matching `**Code:**` line could reach a shell. | Apply the SKILL.md `safe_path` check before `verify_local`, or compare paths without a shell. |
| 🟢 LOW-002 | `plugins/code-reviewer/skills/code-reviewer/SKILL.md:76` | A story file rejected by `safe_path` looks the same as a missing one. A lowercase branch token skips Phase 4.5 silently, and the gate's message does not name the cause. | Return the rejected path so the gate fires and names it. |
| 🟢 LOW-003 | `plugins/code-reviewer/agents/pe-rust.md:263` | pe-rust rates a u64/i64 → `number` mismatch MEDIUM where pe-vue and SKILL.md rate it HIGH. pe-rust exempts `--weak-refs` builds from `.free()`, but pe-vue does not. | Align on HIGH, and add the `--weak-refs` exemption to pe-vue. |
| 🟢 LOW-004 | `plugins/code-reviewer/agents/pe-vue.md:432` | The lifecycle-leak rule does not accept cleanup in `onUnmounted`. | Accept any unmount hook or `onScopeDispose`. |

### Action Items

#### Consider
- [ ] LOW-001 … LOW-004 (follow-up; round cap reached)

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
