# PR Description

Loaded by `sdlc:pull-request` Phase 5. Binds `session.pr_description`, `session.pr_title`, `session.pr_test_plan`, and `session.summary_bullets`.

```text
read ${CLAUDE_PLUGIN_ROOT}/assets/pr-description-template.md
render its Template per its Variable Reference, § AC checklist and § Rules, binding:

  {summary_bullets}   ← clustered from `git log --no-merges 'origin/{session.base_branch}..HEAD' --format=%s`;
                        also session.summary_bullets (Phase 8 reuses it)
  {ac_checklist}      ← body_md's `## Acceptance Criteria`, marked from {session.review_file}'s latest AC conformance table
  {review_line}       ← session.review_present, session.review_round_n, session.review_verdict;
                        review_url = https://github.com/{session.repo}/blob/{session.branch}/{session.review_file}
  {advisory_findings} ← session.review_advisory, one "- [{f.severity}] {f.id}: {f.title} — `{f.location}`" line each
  {closes_line}       ← session.issue_number
  ({test_plan_items}, session.pr_test_plan) = build_test_plan()

session.pr_description = the rendered template
session.pr_title       = session.first_commit_subject     # squash-merge uses the PR title as the commit on main
```

## Issue body and Test Plan

The issue (or story file) is the single source of truth: `build_test_plan()` emits its authored `## Test Plan` section verbatim (written by `sdlc:plan`'s `render-test-plan.js`, never re-derived from the ACs).

```text
body_md = fetch_ticket_body_md()                   # fetched once; {ac_checklist} reads it too

fetch_ticket_body_md() -> markdown or null:
  if session.issue_number:
    (t, ec) = `gh issue view {session.issue_number} --json title,body`
    if ec != 0:
      ⚠️ Warning — could not read #{session.issue_number}; using the generic test plan
      return null
    return t.body
  if session.story_file:
    return the contents of session.story_file
  return null

generic_test_plan = "- [ ] Verify the changes locally and in the deployed environment"

build_test_plan() -> ({test_plan_items}, session.pr_test_plan):
  if body_md is null or empty:
    return (generic_test_plan, null)

  write body_md to a temp file {tp_file}
  (tp, ec) = node "${CLAUDE_PLUGIN_ROOT}/skills/pull-request/bin/extract-test-plan.js" --file '{tp_file}'
  if ec == 127:
    ⚠️ Warning — extract-test-plan.js needs Node on PATH; using the generic test plan
    return (generic_test_plan, null)
  elif ec != 0:
    ⚠️ Warning — Test Plan extract failed for {session.ticket_key}; using the generic test plan
    return (generic_test_plan, null)

  if tp is non-empty:
    ℹ️ Test Plan pulled from {session.ticket_key}
    return (tp, tp)
  ℹ️ No `## Test Plan` on {session.ticket_key} — using the generic bullet
  return (generic_test_plan, null)
```

## Confirm

```text
if session.auto:
  🤖 Auto-resolved — PR title + description accepted (auto): "{session.pr_title}"
  proceed to Phase 6

🟡 Waiting on you — PR title + description

  Title: {session.pr_title}
  ────
  {session.pr_description}
  ────

AskUserQuestion → "PR title + description for {session.branch} — how to proceed?"; options:
  (a) "Accept and proceed (recommended)"
  (b) "Edit title — will re-prompt"
  (c) "Edit description — write to a temp file, re-prompt after $EDITOR"
  (d) "Abort"
```
