# Code Review: plugins#15 (PE test budget and capped parallel dispatch)

**Verdict:** 🔄 Round 3 CHANGES REQUESTED. The fixes are applied, and the round cap has been reached (see Round 3).

| | |
| - | - |
| **Branch** | `feat/15-pe-test-budget` |
| **Closes** | #15 |
| **Reviewers** | pe-governance |
| **Review Round** | 1 |
| **Reviewed SHA** | `50e0430` |
| **Date** | 2026-09-25 |

## Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| pe-governance | none | markdown only |

## Round 1 findings and resolutions

| ID | Sev | Finding | Resolution |
| - | - | - | - |
| MEDIUM-001 | MEDIUM | "Receipts cover the stack" was undefined, so partial or failing receipts could silently skip Pass 2. Static checks were dropped, and `reviewed_sha` was used before it was bound. | § Test Budget is now mechanical. `reviewed_sha` is bound first. `targeted` requires a passing receipt, at the reviewed SHA, for every stack test command. A failing receipt forces `full`. The PE `targeted` branch still runs the static checks that no receipt names. |
| MEDIUM-002 | MEDIUM | `targeted` had no cap, and the narrow commands were copy-pasted to every stack. | At most 3 narrow runs, each naming one package or file and never `./...`. Each PE now carries a literal command for its own stack. |
| MEDIUM-003 | MEDIUM | "Cite in YAML" had no field in the schema, and no consumer read it. | New `test_budget` and `pass2_evidence` keys in each PE's Output Format. The report template has a Test Evidence section, and SKILL Phase 6 Step 2 records it. |
| MEDIUM-004 | MEDIUM | The Pass 2 bodies still said "Run test suite first", and pe-aws-infra synthesized each stack. | Pass 2 now says "Run the Test Commands per § Test Budget first". `tdd_and_hygiene` counts a failing receipt. pe-aws-infra reads `cdk.out` from the Test Commands synth and skips the check when no synth ran. |
| MEDIUM-005 | MEDIUM | AC7 (round 2+ reruns only the tests covering the fix) was only partly met. | Round 2+ passes `FIX DIFF`, and the budget defaults to `targeted` with no receipts. PE narrow runs cover only what the FIX DIFF touches. |
| MEDIUM-006 | MEDIUM | `[ -d node_modules ] \|\| npm ci` tested dependency-bump diffs against stale deps. | `npm ci` is skipped only when `node_modules` exists **and** package.json and the lockfile are unchanged. It is grouped so that a failed `cd` stops the command; three cases were exercised in a scratch script. |
| LOW-001 | LOW | Batching ran suite-free PEs before batch 1, had no exit when a batch stalled, and didn't validate the setting. Per-PE prompts were implied. | Suite-free PEs ride the first message. A stalled PE gets one re-ping, then is recorded as MISSING. The setting must be a positive integer, else 2. Each Agent call gets that PE's own dispatch input. |
| LOW-002 | LOW | The key was missing from the template and its location was ambiguous. | `settings.max_parallel_pes`, now in the template. |
| LOW-003 | LOW | "Stage-conditional" had no heuristic. | A literal grep and a single prod synth command. |
| LOW-004 | LOW | A budget was computed for pe-devtools, which ignores it. | pe-devtools gets no TEST BUDGET line, because its Pass 2 is lint-only. The CHANGELOG records this as a deliberate departure from #15. |
| LOW-005 | LOW | § Test Budget was missing from the sync convention. | Added to CONTRIBUTING § Sync convention. |
| LOW-006 | LOW | Justification prose and repetition. | Cut; the round-2 rule was folded into the pseudocode. |
| INFO-001 | INFO | Version bump and CHANGELOG comply. | None. |

## Review Round 2 — CHANGES REQUESTED (`ad87aaa`), fixes applied

Round-1 status: RESOLVED — MEDIUM-001, MEDIUM-002, MEDIUM-004, LOW-002, LOW-004, LOW-005, LOW-006. PARTIAL — MEDIUM-003, MEDIUM-005, MEDIUM-006, LOW-001, LOW-003; all of them are closed by the round-2 fixes below.

| ID | Sev | Finding | Resolution |
| - | - | - | - |
| MEDIUM-001 | MEDIUM | `round` and `prior_sha` were used before they were bound. | Bound at the top of § Test Budget from the review doc: heading count + 1, and the latest Reviewed SHA. |
| MEDIUM-002 | MEDIUM | A MISSING PE was never consumed, so the verdict could be APPROVED with a stack unreviewed. | The first Verdict Logic branch is now `⚠️ INCOMPLETE`, which is never APPROVED. Test Evidence has a MISSING row form. |
| LOW-001 | LOW | The npm guard missed staged bumps, `{target}` was unbound, and the check wasn't idempotent. | The guard is now keyed on npm's hidden lockfile (`node_modules/.package-lock.json -nt package.json / package-lock.json`). Exercised in a scratch script: no node_modules → npm ci; fresh install → skip; bump after install → npm ci. |
| LOW-002 | LOW | The prod-synth grep matched added lines only, and `<stage_context_key>` was unbound. | The grep matches `^[+-]`; the key is read from `tryGetContext` in `bin/*.ts`, default `stage`. |
| LOW-003 | LOW | The cdk.out check tested whether the directory existed, not whether it was fresh. | "No synth this review → skip"; a missing stack template → HIGH. |
| LOW-004 | LOW | pe-governance and pe-devtools don't emit `test_budget` / `pass2_evidence`. | The SKILL line is scoped: those rows read `none` / `lint-only`. |
| INFO-001 | INFO | The failing-receipt branch in `tdd_and_hygiene` could never be reached. | Reverted to `if a test run fails`. |

## Review Round 3 — CHANGES REQUESTED (`44f00ec`), fixed; the round cap has been reached

Round-2 status: MEDIUM-002, LOW-001..004 and INFO-001 are RESOLVED. MEDIUM-001 was STILL_PRESENT, as shown below.

| ID | Sev | Finding | Resolution |
| - | - | - | - |
| MEDIUM-001 | MEDIUM | The round binding is off by one: round 1 is the top-level report, which has no `## Review Round` heading. The same off-by-one already existed in Phase 6 Step 2. | Both sites now read `1 + (highest N in "## Review Round N", else 1)`. Checked against this doc: its highest heading is round 3, so round = 4. |
| LOW-001 | LOW | INCOMPLETE was missing from the template Verdict lines and from the Step 4 PR-review mapping. | Added to both template lines. Step 4 maps `INCOMPLETE → no review posted; re-run the MISSING PE(s)`. |

Round 3 is the cap. These two mechanical fixes were not re-reviewed by a PE; Copilot (Gate 2) covers them.

## Gate 2 — Copilot (round 1), all fixed

| # | Finding | Resolution |
| - | - | - |
| 1 | pe-aws-infra ran its synth under `always`, so it ran under every budget. | Moved into its own `synth:` block. `none` runs no synth. `full` runs the Test Commands synth, plus prod when the stage grep matches. `targeted` synthesizes at most one stack, as a narrow run. |
| 2 | The stage grep used `{target}...HEAD`, which is wrong for Staged Diff reviews. | It now uses the dispatch input's `<DIFF COMMAND>`, which covers both scopes. |
| 3 | The per-stack template check would flag stacks that were deliberately not synthesized. | It now checks only the stacks this review synthesized. |
| 4 | A PE that returned prose or malformed YAML bypassed MISSING. | Any result that is not a parseable YAML block with `expert` and `findings` is re-dispatched once, then recorded as MISSING. |
| 5 | A failing receipt from any stack forced `full` on every PE. | Only a failing receipt for one of this PE's `stack_cmds` forces `full`. |

## Gate 2 — Copilot (round 2), fixed

| # | Finding | Resolution |
| - | - | - |
| 6 | `<DIFF COMMAND>` already carries its `--` path separator, so appending `-- <cdk_subdir>` broke the git command. | The grep now pipes `<DIFF COMMAND>` directly; it is already scoped to this PE's paths. |
| 7 | A suite-running PE could return valid YAML with no `test_budget` or `pass2_evidence`. | `required` keys now include both for suite-running PEs. A result missing them is re-dispatched once, then recorded as MISSING. |

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
