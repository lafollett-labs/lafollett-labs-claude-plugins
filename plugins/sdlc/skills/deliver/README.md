# sdlc:deliver

The one-command path from a GitHub issue (or a local story code) to an open pull request. `deliver` is a thin orchestrator that chains `sdlc:implement` → `sdlc:review` → `sdlc:pull-request`, driving the review to a clean Gate 1 lock and pausing for a human verification gate before it ever opens the PR.

> This README is the human usage guide. The model-facing contract lives in [`SKILL.md`](./SKILL.md).

## When to use it

- You have an issue and want to take it all the way to a reviewed, open PR in one flow.
- You want the review fix loop handled automatically: remediate findings, re-review, repeat until Gate 1 locks.
- You want an unattended run (`--auto`) that only stops for the decisions a human must make.

**Triggers:** `Deliver this issue` · `Take #42 end-to-end` · `Deliver LT-02` · `/sdlc:deliver`

## How it works

1. **Resume detection**: inspects prior progress (branch, commits, review rounds, the issue's `status:*` label) and offers a resume menu rather than restarting.
2. **Implement**: delegates to `sdlc:implement`, which reads the issue, plans behind a hard-stop approval gate, then implements test-first on a properly named branch.
3. **Review + fix loop**: delegates to `sdlc:review` and remediates every in-scope MEDIUM+ finding until Gate 1 locks (two consecutive clean rounds). LOW/INFO findings are advisory and listed in the PR; a `HUMAN_GATE` escalation hands back to you. An override requires the agent to push back first.
4. **Verification gate**: a mandatory human checkpoint before anything ships.
5. **Pull request**: delegates to `sdlc:pull-request`: push, PR, Copilot review, `status:in-review`, and the Slack announcement when enabled.

`deliver` never dispatches PE agents itself. Spike tickets short-circuit cleanly (findings doc, no PR).

## Usage examples

```text
Deliver #42
```

```text
/sdlc:deliver LT-02 --auto
```

Re-running `Deliver #42` later resumes where you left off.

## Options

- **`--auto`**: collapses the happy path to one human interaction (the plan approval), plus one Copilot confirm at the end when a Copilot thread needs a decision. It halts and hands back on anything a pre-approval can't answer (spike, unresolvable finding, override, fix-loop guard, dirty tree, version collision) and logs every auto-resolved gate.
- **`--incident`**: passed to `sdlc:implement`, whose plan gate is then answered by the `plan-reviewer` agent; anything a person must decide is escalated back to you.
- **`--no-slack`**: passed to `sdlc:pull-request`, which then skips only the Slack announcement.
- **`--model-by-review-tier` / `--no-model-by-review-tier`**, **`--builds worktree|checkout|off`**: passed to every `sdlc:review` run.

## Related skills

- [`sdlc:implement`](../implement/README.md): the implementation phase, usable on its own
- [`sdlc:review`](../review/README.md): the review phase, usable on its own
- [`sdlc:pull-request`](../pull-request/README.md): the PR phase, usable on its own

---

*Part of the [sdlc plugin](../../README.md)*
