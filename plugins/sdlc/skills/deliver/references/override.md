# Engineer Override

Loaded by `sdlc:deliver` Phase 3 when the engineer picks override. Reads `session.review_file`, `session.engineer`, and the round's `gating` findings.

deliver NEVER advances on an override without pushing back first on every open MEDIUM+ finding. Advisory LOW/INFO findings need no override.

```text
restate every open in-scope MEDIUM+ finding:  [{severity}] {title} — {location} — why it genuinely matters
state plainly: "These are legitimate and unresolved. Override and ship with them open?"
require an explicit confirmation + a one-line reason

if not confirmed:
  return to the fix loop (default: remediate)

# confirmed — review-file.js is the single writer of the Overridden Findings block and the Gate Status cell
r = read_review()
(o, ec) = node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" override --file "$(git rev-parse --show-toplevel)/{session.review_file}" <<'OVERRIDE_JSON'
{"round": {r.gate1.round}, "reviewer": {session.engineer as a JSON string}, "reason": {reason as a JSON string},
 "findings": [{"id": f.id, "title": f.title} for f in gating]}
OVERRIDE_JSON
if ec != 0:                                           # 2: unknown / Gate 2 / already-overridden round, or an id not in scope there
  ❌ Error — could not record the override (exit {ec}): {o.error}; the review file is unchanged
  return to the fix loop
commit the review-file update (an ordinary commit; CI runs on it)
goto Phase 6.5                                        # Gate 1 closed by recorded override
```
