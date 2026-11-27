# sdlc:implement

Takes a ticket from "read" to working, tested, committed code on a properly named branch. The ticket is a GitHub issue (`#42`) or a local story code (`LT-02`, a `**Code:** LT-02` line in a `docs/epics/` story file). `implement` reads the ticket, cuts the branch, plans behind a gate you must approve, and implements test-first with conventional commits, then stops. It does not review, open the PR, or post to Slack.

> This README is the human usage guide. The model-facing contract lives in [`SKILL.md`](./SKILL.md).

## When to use it

- You have an issue or story and want to drive it to committed code, but review and open the PR separately.
- You want a plan you approve *before* any code is written.
- You're working a spike: `implement` writes a findings doc instead of code.

**Triggers:** `Implement #42` · `Start work on LT-02` · `/sdlc:implement`

## How it works

1. **Read** — `gh issue view`, or the story file under `docs/epics/`. A story that `sdlc:plan` published is linked to its issue.
2. **Branch** — `<type>/<42 | LT-02>-<slug>` from the base you pick (`feat/`, `fix/`, `chore/`, …; a spike gets `chore/`). If the ticket already has a branch, it asks whether to resume on it or start over.
3. **Mark it started** — the issue gets `status:in-progress` and a progress comment naming the branch. A story with no issue skips this.
4. **Plan** — a scope scout plus explorer and architect agents produce a plan, then **hard-stop for your approval**. With `--incident`, the `plan-reviewer` agent answers this gate instead (see Options).
5. **Implement (TDD)** — Red → Green → Refactor, with conventional commits.
6. **Stop** — hands back once the work is committed.

## Usage examples

```text
Implement #42
```

Then review and ship as separate steps:

```text
review my branch
```

```text
open the PR
```

## Options

- **`--auto`** — auto-resolves the low-judgment happy-path gates (ticket confirm, spike confirm, resume on the ticket's existing branch, base branch). The plan gate stays yours.
- **`--resume`** / **`--start-over`** — answer the existing-branch question up front (`sdlc:deliver` passes one). Resume checks the branch out and keeps its base; start over asks whether to rename or delete it, and stops under `--auto`.
- **`--incident`** — for incident fixes. The read-only `plan-reviewer` agent answers the plan gate in place of you. It approves only the narrowest change that resolves the incident, with numbered adjustments, and lists everything broader (refactors, clean-ups, same-pattern fixes elsewhere, prevention work) as **proposed follow-ups that are never filed automatically**. It requires parity tests for business rules, a failing test first and a named rollback. A plan that needs revising gets at most two review rounds. When a person must decide on business-rule semantics (pricing, entitlements, permissions), a schema, a contract, security, data or production access, or the review doesn't converge, it **escalates** and you get the normal plan gate with its concern. The verdict and follow-ups are printed and written into the issue's progress comment. It combines with `--auto` but doesn't imply it, and nothing is persisted between runs.

```text
/sdlc:implement #42 --auto --incident
```

## Output

| What | Where |
| - | - |
| Working, tested code | conventional commits on a `<type>/<42 \| LT-02>-<slug>` branch |
| Spike findings (spike tickets) | `docs/spikes/<42 \| LT-02>-<slug>.md` instead of code |
| Issue status | `status:in-progress` label and the progress comment |

## Related skills

- [`sdlc:plan`](../plan/README.md) — write the issues and stories this skill picks up
- [`sdlc:review`](../review/README.md) — review the branch once it's committed
- [`sdlc:pull-request`](../pull-request/README.md) — open the PR after review passes
- [`sdlc:deliver`](../deliver/README.md) — run implement → review → pull-request in one flow

---

*Part of the [sdlc plugin](../../README.md)*
