# sdlc

The delivery loop on GitHub: plan the work as issues, implement a ticket test-first,
review it with principal-engineer agents, open the pull request, triage Copilot's
review, or run the whole thing with `deliver`.

```
/plugin install sdlc
```

Needs `gh` (authenticated, recent enough for `gh api --slurp`), `node` and `git`.
Slack is optional and off by default.

## Skills

| Skill | What it does |
| - | - |
| `/sdlc:plan` | Write epics and stories as Markdown in `docs/epics/`, publish them as GitHub issues with stories as sub-issues, and keep both in sync. Replaces `issue-manager` |
| `/sdlc:implement` | Take `#42` (or a local story code such as `LT-02`), plan behind an approval gate, then build it test-first on a conventional branch |
| `/sdlc:review` | Review the branch or a PR with the principal-engineer agent for each stack, five passes each, and keep the review doc in the repo |
| `/sdlc:pull-request` | Push, open the PR from the issue's acceptance criteria, request reviewers, gate on its checks, hand off to Copilot |
| `/sdlc:copilot-review` | Request a Copilot review, wait for it, then fix, defer or answer each thread and resolve it |
| `/sdlc:deliver` | Chain implement → review (until it locks) → a human verification gate → pull-request |

```text
/sdlc:plan init --name "Book Search"
/sdlc:plan create --docs-path docs/epics/004-book-search
/sdlc:deliver #42
/sdlc:review
/sdlc:pull-request
/sdlc:copilot-review #7
```

## Review agents

`review` dispatches one agent per stack the diff touches: `pe-go`, `pe-rust`, `pe-vue`, `pe-angular`,
`pe-csharp`, `pe-sql-server`, `pe-aws-infra`, `pe-github-actions`, `pe-governance`, `pe-devtools`
(local dev scripts and hooks, under a single-operator threat model), and
`pe-general-purpose` for anything no specialist owns. `plan-reviewer` answers
`implement`'s plan gate under `--incident`.

## Tickets, branches and status

| | |
| - | - |
| Ticket | `#42` (a GitHub issue) or a story code like `LT-02` (`**Code:** LT-02` in `docs/epics/`) |
| Branch | `<type>/42-<slug>` or `<type>/LT-02-<slug>`, e.g. `feat/42-add-login` |
| Commits | Conventional Commits; acceptance criteria referenced as `AC: 1, 3` |
| Status | One `status:*` label per issue: `todo` → `in-progress` → `in-review` → `done`. The skills set the first three; `done` is yours or your automation's, and a closed issue counts as done. Missing labels are created on first use |
| Base | The PR's base, else the base `implement` recorded for the branch, else `origin/HEAD`, else `main` |
| Progress | One issue comment, edited in place as the work moves |

## Settings

Optional. `.claude/sdlc.json` in the repo (committed) wins over `~/.claude/sdlc.json`.

```json
{
  "pullRequest": { "reviewers": ["octocat"], "draft": false },
  "slack": { "enabled": false, "channel": "#eng" },
  "review": { "searchRoots": [], "modelByTier": true }
}
```

Without `pullRequest.reviewers`, reviewers come from `CODEOWNERS`, or you are asked.

## Tips

- Reviews are committed to the PR branch as ordinary commits, never `[skip ci]`, so
  required checks always report on the head.
- GitHub won't let you approve your own PR, so on your own PR the review verdict is
  posted as a comment.
- Copilot review needs Copilot code review quota; when it runs out, `copilot-review`
  says so and stops.
