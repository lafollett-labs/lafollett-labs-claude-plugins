# PR Description Template

The pull-request description `sdlc:pull-request` renders (and `sdlc:deliver` through it). Standard GitHub markdown, passed to `gh pr create --body-file`.

## Template

```markdown
## Summary

{summary_bullets}

## Acceptance Criteria

{ac_checklist}

## Code Reviews

{review_line}

{advisory_findings}

## Notes

{notes_bullets}

## Test Plan

{test_plan_items}

{closes_line}

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## Variable Reference

| Variable | Source |
| - | - |
| `{summary_bullets}` | One bullet per logical change, clustered from `git log --no-merges 'origin/{session.base_branch}..HEAD' --format=%s`, where `session.base_branch` is the PR's confirmed base (its default comes from `git-conventions.js base`). Covers the whole branch, not the last commit: a squash merge keeps only the PR title, so the description is where the multi-commit context survives. |
| `{ac_checklist}` | One task-list item per acceptance criterion, in ticket order: the issue body's (`gh issue view {N} --json body`) or the story file's `## Acceptance Criteria` scenarios. Marked from the latest round's AC conformance table in the review doc (`docs/code-reviews/{key_slug}-code-review.md`), per § AC checklist. |
| `{review_line}` | With a recorded review: `Local sdlc:review (round {N}): {verdict} — see [{key_slug}-code-review.md]({review_url})`, where `{review_url}` is the review doc's blob URL on the PR branch. Otherwise: `No local code reviews performed`. |
| `{advisory_findings}` | The latest round's Advisory Findings lines (open in-scope LOW/INFO findings) under the bold lead-in `**Advisory findings (LOW/INFO — non-gating, for the reviewer):**`. |
| `{notes_bullets}` | Optional context: design decisions, trade-offs, dependencies, migration steps. |
| `{test_plan_items}` | The ticket's `## Test Plan` section verbatim, extracted by `skills/pull-request/bin/extract-test-plan.js` from the issue body or story file. Fallback: `- [ ] Verify the changes locally and in the deployed environment` when the ticket has none, there is no ticket key, or the ticket is unreadable. |
| `{closes_line}` | `Closes #{issue_number}` when the ticket is a GitHub issue, or a story code whose file links one. GitHub closes the issue only when the PR merges into the repository's default branch; a PR into another base leaves it open. |

## AC checklist

| Review result for the AC | Item |
| - | - |
| `satisfied` | `- [x] {ac} — {evidence}` |
| `not-satisfied` | `- [ ] {ac} — ❌ not satisfied: {evidence}` |
| `not-verifiable` | `- [ ] {ac} — ⚠️ not verifiable: {evidence}` |
| no review, or the AC is absent from its table | `- [ ] {ac}` |

`{ac}` is the criterion on one line (a scenario's title); `{evidence}` is the table's `file:line` evidence.

## Rules

- The footer line (`🤖 Generated with [Claude Code](https://claude.com/claude-code)`) is verbatim, never templated.
- Omit `## Acceptance Criteria` when the ticket states none, and `## Notes` when `{notes_bullets}` is empty; never leave an empty section.
- Omit the `{advisory_findings}` and `{closes_line}` lines (and their blank lines) when empty.
- `## Test Plan` is always present, with at least the fallback bullet.
- `Closes #N` appears once, on its own line; never a `Closes` line for a story code without an issue.
