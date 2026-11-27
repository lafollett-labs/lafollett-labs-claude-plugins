# sdlc:pull-request

Takes a branch with committed code to a pushed branch and a GitHub pull request with an assignee and reviewers set, runs a Copilot code review and judges it locally, labels the issue `status:in-review`, and (when Slack is enabled) announces the PR. It reads the review verdict from disk and never runs PE agents itself. It also nudges PRs that have gone quiet.

> This README is the human usage guide. The model-facing contract lives in [`SKILL.md`](./SKILL.md).

## When to use it

- Your branch is committed and reviewed, and you want the PR opened with reviewers, CI status and the issue label handled.
- You want the PR title and description generated from the branch history and the review verdict, with the Test Plan and acceptance criteria pulled from the issue.
- A PR has been sitting unreviewed and you want to nudge its reviewers.

**Triggers:** `Open the PR` · `Ship this branch` · `/sdlc:pull-request` · `Nudge PR #46`

## How it works

1. **Validate**: checks the branch name and commit conventions, and runs the version-collision guard in plugin repos.
2. **Read the review verdict**: reads `docs/code-reviews/<key>-code-review.md` through `review-file.js parse`. Without a Gate 1 lock it offers to run `sdlc:review` first.
3. **Pick reviewers**: `pullRequest.reviewers` from settings, else the CODEOWNERS owners of the changed files, else it asks. Under `--auto` with none, it opens the PR without reviewers and says so.
4. **Push and create**: `gh pr create` with `--assignee @me` and `--reviewer`, then reads the head's checks with `bin/pr-checks.js`.
5. **Copilot review**: requests a Copilot review and evaluates it with [`sdlc:copilot-review`](../copilot-review/README.md). An exhausted Copilot quota is reported, not fatal. `--no-copilot` skips this step.
6. **Status and announce**: labels the issue `status:in-review`, updates its progress comment, and posts to `slack.channel` when `slack.enabled` is true (`--no-slack` skips it).

## Usage examples

```text
open the PR
```

```text
Nudge PR #46
```

With Slack enabled the nudge replies on the original announcement thread; otherwise it comments on the PR and mentions the requested reviewers.

## Output

| What | Where |
| - | - |
| Pull request (assignee + reviewers) | GitHub, via `gh pr create` |
| Copilot review | Copilot's threads judged locally; fixes pushed and threads replied to and resolved after one confirmation |
| Issue status | `status:in-review` label and the issue's progress comment |
| Announcement (optional) | `slack.channel` from `.claude/sdlc.json` |

## Related skills

- [`sdlc:implement`](../implement/README.md): get to committed code first
- [`sdlc:review`](../review/README.md): produce the review verdict this skill reads
- [`sdlc:deliver`](../deliver/README.md): run implement → review → pull-request in one flow
- [`sdlc:copilot-review`](../copilot-review/README.md): the Copilot step this skill runs before the label and the announcement

---

*Part of the [sdlc plugin](../../README.md)*
