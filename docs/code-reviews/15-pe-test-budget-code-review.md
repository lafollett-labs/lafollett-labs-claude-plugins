# Code Review: plugins#15 (PE test budget and capped parallel dispatch)

**Verdict:** 🔄 Round 1 CHANGES REQUESTED. The fixes are applied, and round 2 is pending.

| | |
| - | - |
| **Branch** | `feat/pe-test-budget` |
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

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
