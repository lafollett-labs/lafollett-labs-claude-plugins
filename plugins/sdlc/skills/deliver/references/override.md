# Engineer Override

Loaded by `sdlc:deliver` Phase 3 when the engineer picks override. Reads `session.review_file`, `session.engineer`, and the round's `gating` findings.

deliver NEVER advances on an override without pushing back first on every open MEDIUM+ finding. Advisory LOW/INFO findings need no override.

```text
restate every open in-scope MEDIUM+ finding:  [{severity}] {title} — {location} — why it genuinely matters
state plainly: "These are legitimate and unresolved. Override and ship with them open?"
require an explicit confirmation + a one-line reason

if not confirmed:
  return to the fix loop (default: remediate)

# confirmed — record it using sdlc:review's § Overridden Findings format, AND set the latest round's
# Gate Status so deliver's own loop (gate_status check) and Phase 6.5 read OVERRIDDEN
latest_round_N = max N over `## Review Round {N}` headers in session.review_file
                 # initial block only (no round headers yet) → read the `| **Review Round** | {n} |` metadata row
append to session.review_file under the latest round:
  ### Overridden Findings (round {latest_round_N})   # review-round number, NOT session.fix_round — matches sdlc:review's format
  - [{severity}] {title} — {location} — overridden by @{session.engineer}: "{reason}"
set the latest round's `| **Gate Status** | {…} |` cell to:
  "OVERRIDDEN — engineer accepted {open_count} open finding(s); see Overridden Findings"   # open_count = len(gating)
commit the review-file update (an ordinary commit; CI runs on it)
goto Phase 6.5                                        # Gate 1 closed by recorded override
```
