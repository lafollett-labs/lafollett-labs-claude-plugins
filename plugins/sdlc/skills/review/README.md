# sdlc:review

Stack-specialized code review with a two-gate model and a severity-gated verdict. Instead of one generalist pass, `review` dispatches the Principal Engineer (PE) agents whose file patterns match your diff — each runs a mandatory five-pass protocol, then seven review moves (ripple, lifecycle, inputs, attack the guard, failure path, falsify the test, fact check) whose coverage it must account for, and tags each finding with its siblings and, from round 2, the prior finding that introduced it — then consolidates their findings into a single verdict and an append-only review document.

> This README is the human usage guide. The model-facing contract lives in [`SKILL.md`](./SKILL.md).

## When to use it

- You want a rigorous review of your branch before opening a PR (**Gate 1** — author self-review).
- You're the requested reviewer on someone else's PR (**Gate 2** — independent peer review).
- You want a focused review of specific files, a folder, or staged changes.

**Triggers:** `review my branch` · `review PR #7` · `code review` · `review the src/auth folder` · `/sdlc:review`

## How it works

1. **Scope** — detects the review type (branch diff, PR, staged, files, folder), checks out the PR branch if needed, and classifies a depth tier (TRIVIAL / STANDARD / DEEP) from the diff size and risk.
2. **Route** — matches each changed file to its specialist PE (`pe-go`, `pe-vue`, `pe-github-actions`, `pe-governance`, …), falling back to `pe-general-purpose` for anything unclaimed. A domain PE (`pe-audio` on audio and DSP paths) reviews its files beside their specialist and runs no suites. A judgment pass refines routing by what the change *does*, not just the filename.
3. **Dispatch** — one agent per matched PE, in parallel. Each runs all five passes (Architecture → Quality+Tests → Security → Adversarial Re-read → Self-Adversarial).
4. **Consolidate** — de-dupes findings, validates proof of each actual problem against the code, keeps unproven "cannot happen" claims as non-gating receipts, checks the change against the ticket's acceptance criteria, and computes a severity-gated verdict.
5. **Record** — Gate 1 appends the round to `docs/code-reviews/` and commits only the review files on your branch (never on the default branch, a detached HEAD, or for pasted code). Gate 2 never commits or pushes to the author's branch: it posts the round as a PR comment plus an approve or request-changes review, and keeps your own running notes in `~/.claude/sdlc/reviews/<owner>/<repo>/`.

The mechanical steps are tested scripts in `bin/`, not model judgment: `scope.js` picks the reviewed files, the depth tier, and the PE for each file; `findings.js` validates and de-dupes PE output; `review-file.js` computes the verdict and Gate 2 status, records overrides, and owns the review-file format; `build-plan.js` places front-end builds. Reviews of staged changes, specific files, a folder, or pasted code never touch the branch's findings ledger.

**Verdict:** any in-scope CRITICAL/HIGH → 🚫 BLOCKED · any MEDIUM → ⚠️ CHANGES REQUESTED · only LOW/INFO or none → ✅ APPROVED. Every MEDIUM+ finding must be addressed; LOW/INFO are advisory. Whether Gate 1 locks is decided by `bin/convergence.js`: it records each round to a findings ledger and locks after two consecutive clean rounds. If MEDIUM+ findings are still open at round 8 of a cycle, or one finding keeps re-opening, it stops for a human (`HUMAN_GATE`). Findings in data-integrity, migration, auth, and secrets are never recorded below MEDIUM.

**Acceptance criteria:** read from the linked GitHub issue (`#42` in the branch name), or from the story file in `docs/epics/` whose `**Code:**` line matches the branch's story code. The check is skipped when the issue is closed or the story is already checked off on the target branch. Unmet criteria become HIGH findings.

**Gate 2 status:** the PR is MERGEABLE when every Gate 2 reviewer's latest GitHub review is an approval on code identical to the PR head (a commit that only touches `docs/code-reviews/` does not count as a change) and the head's checks passed or none are reported.

**Gate 2 CI gate:** Gate 2 reads the checks on the PR head (`../../bin/pr-checks.js`). A failed check adds a CRITICAL finding with the failed-step log tail; checks still running, cancelled, or unreadable hold the round open and withhold the approval; a PR with no checks is not blocked (when the repo has any workflow under `.github/workflows/`, `pr-checks.js --settle 30` first polls for up to 30 seconds, since fresh checks take a moment to register, then reads the head's workflow runs, so a workflow that failed to start counts as failed rather than as no CI; a passing head's runs are read too, so a run that failed to start beside green checks still fails).

## Usage examples

```text
review my branch                 # Gate 1, before you open the PR
review PR #7                     # Gate 2, as the peer reviewer
review these files: internal/auth/limiter.go, internal/auth/limiter_test.go
/sdlc:review cleanup             # remove review worktrees whose PR is finished
```

Re-run after fixing findings — each invocation is one round; two clean rounds in a row locks Gate 1.

To accept open findings rather than fix them, choose **engineer override** at the round prompt: the review pushes back on each one, then records them with your reason under **Overridden Findings** and marks the round `OVERRIDDEN`.

## Options

- **Worktree isolation (PR reviews)** — check the PR branch out in an isolated `git worktree` under `../.sdlc-worktrees/<repo>/<key>` so reviewing several PRs at once never moves your primary checkout's HEAD. In-place is the default for interactive runs; `--auto` always takes the worktree path and keeps it.
- **`cleanup`** — classifies each review worktree from its PR's state on GitHub: dirty, locked, open-PR, no-PR and not-landed worktrees are kept; a worktree whose PR is merged or closed with its content in the PR's final head (squash and rebase included) is offered for removal. Nothing is removed without your confirmation or with `--force`.
- **`--auto`** — for unattended runs (`sdlc:deliver`). Happy-path prompts resolve without asking and print a `🤖` line; failure prompts still stop for a human.
- **`--model-by-review-tier` / `--no-model-by-review-tier`** — TRIVIAL → Haiku, STANDARD → Sonnet, DEEP → your session model. On by default; set `"review": { "modelByTier": false }` in `.claude/sdlc.json` (repo) or `~/.claude/sdlc.json` (you) to turn it off.
- **`--builds worktree|checkout|off`** — where front-end PEs install, build, and test: a disposable worktree (default under `--auto`), your checkout without installing, or nowhere. Never a production configuration. Remembered per branch.
- **Test budget** — a PE reuses your test receipts for its own commands (`<command> → pass @ <sha>` lines in the invocation or a hand-off, at HEAD's SHA; never the PR body or a Gate 2 round) instead of rerunning those suites, and from round 2, while the prior round's SHA is still in the branch history, runs tests only for what the fix touched and its dependents. A failing receipt means a full run.
- **Parallel PEs** — at most `"review": { "maxParallelPes": 2 }` suite-running PEs run at once; the rest start as slots free.
- **Search roots** — below DEEP, PEs read only inside the reviewed repo plus sibling repos listed in `"review": { "searchRoots": ["../other-repo"] }`.
- **Slack** — with `"slack": { "enabled": true, "channel": "#eng" }`, the verdict is posted as a reply to the PR's announcement thread.

## Output

| What | Where |
| - | - |
| Gate 1 review document (append-only, committed) | `docs/code-reviews/<key>-code-review.md` |
| Findings ledger (Gate 1 convergence state, committed) | `docs/code-reviews/<key>-findings-ledger.json` |
| Gate 2 reviewer notes (never committed, one per PR) | `~/.claude/sdlc/reviews/<owner>/<repo>/<key>-pr<N>-code-review.md` |
| PR verdict | PR comment, plus approve / request changes when you are not the author |
| Issue progress | the AC-conformance (and, for bugs, root-cause) section of the issue's progress comment |
| Slack verdict | `slack.channel`, when enabled |

## Related skills

- [`sdlc:implement`](../implement/README.md) — get to committed code before you review it
- [`sdlc:pull-request`](../pull-request/README.md) — open the PR once the review passes
- [`sdlc:deliver`](../deliver/README.md) — orchestrates implement → review → pull-request end to end
