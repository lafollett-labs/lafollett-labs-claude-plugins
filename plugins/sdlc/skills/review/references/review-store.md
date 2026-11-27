# Review Store

Loaded by SKILL.md Phase 6 (§ Persist). Reviews live in the repo only; `review-file.js` is the single reader (round-state.md § Read the review) and writer of the review file.

| File | Path under `{session.review_root}` | Written by |
| - | - | - |
| Review | `docs/code-reviews/{session.name}-code-review.md` | `review-file.js render` (Phase 6) |
| Findings ledger | `docs/code-reviews/{session.name}-findings-ledger.json` | `convergence.js record` (Phase 6) |

Both are committed on the reviewed branch with an ordinary commit in Phase 7 (`publish.md` Step 3); CI runs on that commit like any other.

## Persist (Phase 6)

```text
out = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" render --file "{output_path}"` < round
if exit != 0:
  ❌ Error — {out.error}
  render every finding in `round` to the terminal so none is lost; session.review_committed = false; return "stopped"
return "persisted"
```
