# Review Store

Loaded by SKILL.md Phase 6 (§ Persist). `review-file.js` is the single reader (round-state.md § Read the review) and writer of a review file.

| File | Path | Written by |
| - | - | - |
| Gate 1 review | `{session.review_root}/docs/code-reviews/{session.name}-code-review.md`, committed on the author's branch (publish.md Step 3) | `review-file.js render` (Phase 6), `review-file.js override` (round-state.md § Engineer override) |
| Gate 1 findings ledger | `{session.review_root}/docs/code-reviews/{session.name}-findings-ledger.json`, committed with it | `convergence.js record` (Phase 6) |
| Gate 2 review, the reviewer's own | `~/.claude/sdlc/reviews/{owner}/{repo}/{session.name}-pr{N}-code-review.md` (keyed by PR), never committed and outside every worktree; the round's record for others is the PR comment and `gh pr review` | `review-file.js render` (Phase 6) |

## Persist (Phase 6)

```text
round = {
  name: session.name, branch: `git -C "{session.review_root}" rev-parse --abbrev-ref HEAD`, title: session.pr.title or the branch description,
  date: today, pr: {number: session.pr.number, url: session.pr.url, author: session.pr.author.login} if session.pr else null,
  reviewer: session.reviewer_username, head_sha: session.head_sha, gate_status: session.gate_status,
  agents: [{pe: session.by_name[n], model: d.model, tier: d.tier} for n, d in session.pe_dispatch],
  tier: session.tier, tier_source: session.tier_source, model_by_tier: session.model_by_tier,
  model_by_tier_source: session.model_by_tier_source, deep_guard_note: session.deep_guard_note,
  tier_escalations: [{pe, from: old_tier, to: new_tier, justification}], routing_rationale: session.routing_rationale,
  convergence_reasons: (session.convergence.reasons if session.ledger else []),
  files_changed, lines_added, lines_removed, changed_files, gate1_skip_note: session.gate1_skip_note,
  summary: 2–3 sentences — what changed, what was found, overall assessment,
  ac_results: [{ac: "#{r.index} {one-line r.ac}", verdict: r.status, evidence: r.evidence}] if session.ac_conformance == "pending",
  ac_skip_reason: session.ac_conformance otherwise,
  findings: consolidated,                        # severity, in_scope, title, location, locations, domains, category, description, recommendation
  dismissed: [{title, rationale, original_severity, outcome}],   # outcome: "dismissed" | "adjusted → {SEV}"
  receipts: [{claim, title, location, attestation, missing_source}],   # every PE receipt; a demoted finding → claim indeterminate (with missing_source) or below_bar, original description + missing proof in attestation
  category_fallbacks: session.category_fallbacks,
  coverage_gaps: session.coverage_gaps            # PEs whose moves_coverage stayed incomplete after one re-dispatch
}
out = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" render --file "{output_path}" --root "{session.review_root}"` < round
    # creates the file or appends "## Review Round {n}"; advisory LOW/INFO are indexed under § Advisory Findings only: every finding keeps its full entry under § In Scope Findings
if exit != 0:
  ❌ Error — {out.error}
  render every finding in `round` to the terminal so none is lost; session.review_committed = false; return "stopped"
return "persisted"
```
