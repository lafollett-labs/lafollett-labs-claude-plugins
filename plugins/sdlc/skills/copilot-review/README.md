# sdlc:copilot-review

Requests a GitHub Copilot code review on a pull request, waits for Copilot to review the current head, and judges each Copilot comment locally against the code and the issue. After one confirmation it fixes what needs fixing, files out-of-scope work as GitHub issues, replies to each thread, and resolves it.

> This README is the human usage guide. The model-facing contract lives in [`SKILL.md`](./SKILL.md).

## When to use it

- You opened a PR and want Copilot's review triaged rather than read comment by comment.
- Copilot left threads and you want each one fixed, deferred, or answered with evidence.

**Triggers:** `Run a Copilot review` · `Check Copilot's review on #46` · `/sdlc:copilot-review`

`sdlc:pull-request` runs this skill after it opens the PR.

## How it works

1. **Request**: asks Copilot to review the PR, unless Copilot already reviewed the current head or a request is already pending. When the Copilot review quota is exhausted it says so and stops; nothing else is affected. A rate limit (HTTP 429) or an outage (HTTP 503) is reported as an error to retry later.
2. **Wait**: polls until Copilot's review of the current head commit appears (up to about 12 minutes).
3. **Judge**: rates each open Copilot thread with the `sdlc:review` severity scale and picks a disposition: `fix`, `advisory`, `defer`, `already-fixed`, `copilot-wrong` (only with a command or test that proves it), or `needs-human`.
4. **Act**: after one confirmation it commits and pushes fixes, opens a `status:todo` issue for each deferral, replies to each thread, and resolves it. A `needs-human` thread is left open for the reviewer.

Under `--auto`, LOW/INFO threads are answered and resolved without asking, and the confirmation appears only when a MEDIUM-or-worse thread needs a decision.

## Usage examples

```text
/sdlc:copilot-review #46
```

## Requirements

- `gh`, signed in, with Copilot code review available on the repository.
- Run it from a checkout of the PR's branch at the PR's head; elsewhere it only reports.

## Script

`bin/copilot-review.js` holds the mechanics (`request`, `wait`, `threads`, `reply`, `resolve`, `pushed`), prints JSON, and exits 0 on success, 1 when it stopped cleanly (quota exhausted, wait timed out), 2 on an error. Its offline suite is `bin/test/run-copilot-review-tests.sh`.

The Copilot reviewer login and the coverage wording it parses are marked unverified in the script until they are checked against a live Copilot review.

## Related skills

- [`sdlc:pull-request`](../pull-request/README.md): opens the PR and runs this skill
- [`sdlc:review`](../review/README.md): the severity scale these dispositions use

---

*Part of the [sdlc plugin](../../README.md)*
