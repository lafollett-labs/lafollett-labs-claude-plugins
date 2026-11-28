# live-stock:herd

A goal-driven conductor for a project's work plan. herd runs the plan's stories, GitHub issues (`#42`) or local story codes (`LT-02`), as parallel lanes (one Claude Code session per story, each in its own herdr pane and git worktree), answers lane gates as the engineer would within replanning guardrails, merges approved pull requests behind a head-SHA guard, finishes each story (issue closed as completed, optional Slack, work plan), and stops when the run file's Done-when holds.

> This README is the human usage guide. The model-facing contract lives in [`SKILL.md`](./SKILL.md).

**Status:** v0.1. It drives the [sdlc plugin](../../../sdlc/README.md) from this marketplace, so install sdlc too.

Runtime needs: the sdlc plugin, herdr 0.9.5 or later (run inside herdr, `HERDR_ENV=1`), `gh` (authenticated), `git`, `node`, and `~/.claude/herd/config.json`. Slack is optional and off by default: herd needs the Slack MCP server only when sdlc's settings turn Slack on (`slack.enabled` in `~/.claude/sdlc.json` or a repo's `.claude/sdlc.json`) or the run file names a Slack channel or user.

Run the herd session on a model that is good at deciding and judging. herd places each story on a rung before it starts the lane — 1 mechanical (sonnet / medium), 2 small and fully specified by its tests (sonnet / high), 3 normal (opus / high), 4 subtle semantics or design (opus / xhigh) — and logs the rung and its reason. A run file's Lane ceiling, such as `opus/high`, caps every rung's model and effort. A model, effort or rung you name for a story wins over both. A lane whose review rounds stop converging is parked and raised to you as a question, with its rounds, open findings and token usage so far: restart one rung up, restart at a model and effort you name, run one more review round, or keep it parked for you. A lane's review agents run on the lane's model (lanes pass `--no-model-by-review-tier` to `sdlc:review`) unless you choose reviewers by tier for a story: then lanes pass `--model-by-review-tier`, which runs TRIVIAL reviewers on haiku, STANDARD on sonnet and DEEP on the lane's model, and the row's Model/effort cell reads, for example, `R3 opus/high, reviewers by tier`. A restart keeps the choice.

Lanes start in [auto mode](https://code.claude.com/docs/en/permission-modes), which trusts the lane's worktree and its remotes until you name more in `~/.claude/settings.json`. Auto mode alone allows a push to the repo's default branch, so `herd-lane.js` gives each lane its own deny rules that guard the usual forms of a push to `main` and a force push (flags in any position, a full ref, a `+` refspec). They are guards, not a security boundary: GitHub branch protection or a ruleset on `main` is the hard limit, so protect `main` on every repo herd runs. The rules never reach the herd session, which may push story-file ticks to `main` for a `direct` project. Put only rules that hold for every session in your settings:

```json
{
  "autoMode": {
    "environment": ["$defaults", "Source control: github.com/octo-org and all repos under it"]
  },
  "permissions": { "deny": ["Read(./.env)"] }
}
```

## When to use it

- A work plan lists several stories and you want them in flight in parallel, not one issue at a time.
- You want something to answer routine lane gates and react to PR, checks and review events while you do other work.
- You want approved PRs merged and each story finished (issue closed, optional Slack, work plan) without hand-holding.

**Triggers:** `herd this work plan` · `run the lanes` · `conduct the plan` · `/live-stock:herd <run-file>` · `/live-stock:herd new <work-plan>`

## How it works

1. **Preflight** — `herd-env.js check` verifies tools, `HERDR_ENV`, your GitHub login and config; the work plan's "How Agents Use This Plan" operations are read, with defaults for any it lacks. herd stops only when Slack is configured and its tools do not load. herd prints the run file's Done-when as a `/goal` for you to set.
2. **Reconcile** — on entry and after every compaction, herd compares each run-file lane with live lane, PR and issue state and corrects the file.
3. **Loop** — while lanes are under `max_lanes`, herd starts the next work-plan row as a lane (only rows in the run file's Scope whose issue is open, carries no `status:in-progress`, `status:in-review` or `status:done` label, and is unassigned or assigned to you; anything else is reported and skipped, and herd asks the plan again past it), then waits for events and routes them: lane gates, PR changes, check results, the base branch's CI after a merge, review requests.
4. **Merge** — a PR merges only when `herd-pr.js ready` says so, its Slack announcement link is in the lane's row (when Slack is on), and the merge is pinned to the head SHA that was checked. A repo that requires a merge queue gets the PR queued instead. When the reviewer requests changes a second time on the same PR, herd sends no further fix round: it parks the row and asks you, with the reviewer's rounds and the findings still open. herd never approves.
5. **Finish** — after the base branch's CI passes at the merge commit (at once when `main_ci` is false), herd ticks the story, syncs the issue body through `sdlc:plan update`, labels it `status:done` and closes it as completed, posts the Done line when the plan has a `post_progress`, runs the plan's finish step, records the lane's token usage beside its rung, and closes the lane. A Definition of Done item only you can do, a finish step that stops, a failed or missing base CI run, or a lane worktree that cleanup keeps parks the row or holds the lane and lands on your list instead.

Each lane does its own work through `sdlc:implement` → `sdlc:review --auto` → `sdlc:pull-request`, which runs the Copilot review. herd may narrow, split, reorder or park work inside the epic's intent; design, interface or ADR changes, dropped acceptance criteria and cross-team matters are escalated. Every decision is logged in the run file. When the run is done, herd re-checks what it still lists for you against the work plan, git and GitHub, then writes an end-of-run summary into the run file and ends its session with the same text.

## Usage examples

Draft a run file from a work plan, then review it:

```text
/live-stock:herd new ~/repos/example/work-plan.md
```

Run the lanes until Done-when holds:

```text
/live-stock:herd ~/.claude/plans/herd-example.md
```

One pass: reconcile and handle one batch of events (merges and finishes included), report the rows it would start, and start none:

```text
/live-stock:herd ~/.claude/plans/herd-example.md --once
```

## Options

| Form | Does |
| - | - |
| `/live-stock:herd <run-file>` | Preflight, reconcile, then loop until Done-when |
| `/live-stock:herd <run-file> --once` | Preflight, reconcile, handle one batch of events (it acts on them: merges, finishes, lane prompts), report the rows it would start, stop. Starts no lane |
| `/live-stock:herd new <work-plan>` | Draft a run file from `assets/herd-run-template.md` (default `~/.claude/plans/herd-<plan-name>.md`) and stop for review |

## Scripts

Every script prints one JSON object; exit 2 means `{error}`.

| Script | Use |
| - | - |
| `bin/herd-env.js` | `check`: preflight of sdlc scripts, tools (`gh`, `git`, `node`, `herdr`), `HERDR_ENV`, GitHub login, run directory and config |
| `bin/herd-watch.js` | `snapshot`: live lane, agent, PR and review-request state. `wait`: block until an event needs the conductor, including a lane's review round finishing (its own `<key slug>-findings-ledger.json` gains a round), a PR's head checks finishing, and the base branch's CI finishing at a pinned merge commit. It backs off its GitHub polls when gh reports a rate limit |
| `bin/herd-pr.js` | `ready`: merge verdict (`ready`, `wait`, `hold`, `blocked`). `merge`: head-SHA-guarded merge with the project's `merge_method`, or a queued auto-merge where a merge queue is required. `rerequest`: re-request a reviewer, keeping the current ones |
| `bin/herd-lane.js` | `start`: worktree, session and first prompt; adopts the story's existing branch, its worktree, or a clean worktree elsewhere (moved to the lane path). `restart`: fresh or resumed session in a lane's pane. `close`: exit and remove the worktree only when cleanup classifies it safe |
| `bin/herd-usage.js` | A lane's input, cache-write, cache-read and output tokens and assistant turns, in total and by model, from its Claude Code transcripts and their subagents. Tokens only, no prices |

Other files: `references/` (lane prompts, gate answers, finish, replanning) and `assets/herd-run-template.md` (run-file template).

Tests:

```bash
bash bin/test/run-herd-env-tests.sh
bash bin/test/run-herd-pr-tests.sh
bash bin/test/run-herd-watch-tests.sh
bash bin/test/run-herd-lane-tests.sh
bash bin/test/run-herd-usage-tests.sh
```

## Config

`~/.claude/herd/config.json` (or the path in `HERD_CONFIG`):

```json
{
  "projects": {
    "<short>": {
      "repo": "octo-org/octo-repo",
      "checkout": "<absolute path to the local checkout>",
      "main_push": "pr-only",
      "merge_method": "squash",
      "main_ci": true
    }
  },
  "review_request_authors": ["octocat"],
  "defaults": { "max_lanes": 3, "lane_model": "opus", "lane_effort": "high", "lane_compact_window": 277778 }
}
```

| Key | Meaning |
| - | - |
| `projects.<short>.repo`, `checkout` | The GitHub repository (`owner/name`) and the local checkout lane worktrees are cut from |
| `projects.<short>.main_push` | `pr-only`, or `direct` when your account may push story-file ticks straight to `main` |
| `projects.<short>.merge_method` | `squash`, `merge` or `rebase` |
| `projects.<short>.main_ci` | Optional, default `true`. `false` when the base branch runs no CI: a merge finishes the story at once instead of waiting for a CI run. With `true`, a merge whose commit has no CI run 15 minutes later parks the row for you |
| `review_request_authors` | GitHub logins whose review requests herd adds to the stand-in's list |
| `defaults.max_lanes`, `lane_model`, `lane_effort` | Lane cap, and the model and effort a lane gets when herd passes none. Leave the model or effort out to let lanes follow your Claude Code settings |
| `defaults.lane_compact_window` | Optional token count each lane gets as `CLAUDE_CODE_AUTO_COMPACT_WINDOW` through its `--settings`, overriding your own value for lanes only. Absent: lanes follow your settings |

## Related skills

- [`sdlc:deliver`](../../../sdlc/skills/deliver/README.md) — takes one issue through implement, review and pull-request in one session; herd is the standing dispatcher above it, running many lanes from a work plan
- [`sdlc:review`](../../../sdlc/skills/review/README.md) — each lane runs `review --auto` to a Gate 1 lock before its PR
- [`sdlc:pull-request`](../../../sdlc/skills/pull-request/README.md) — each lane opens its PR through it; herd takes over at the approved PR and merges
- [`sdlc:plan`](../../../sdlc/skills/plan/README.md) — herd files gap and follow-up stories through it and syncs issue bodies only through it
- [`sdlc:copilot-review`](../../../sdlc/skills/copilot-review/README.md) — runs inside each lane's `pull-request`, and again when a lane fixes Copilot findings; herd does not call it directly

---

*Part of the [live-stock plugin](../../README.md)*
