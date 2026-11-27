# Disposition rules for Copilot findings

## Contents

- Severity and category
- Choosing a disposition
- Evidence bar
- Reply templates

## Severity and category

Rate the impact yourself after reading the cited code at HEAD; Copilot's wording is an input, not a rating. Use `sdlc:review`'s scale and gating: CRITICAL/HIGH block the merge, MEDIUM must be fixed before the work is done, LOW/INFO are advisory. Findings in data-integrity, migration, auth or secrets are never below MEDIUM.

Category is one of: data-integrity, migration, auth, secrets, security, correctness, concurrency, error-handling, performance, test-coverage, maintainability, docs, general.

## Choosing a disposition

| Disposition | Choose it when |
| - | - |
| `fix` | The claim holds at HEAD and the finding is MEDIUM or worse |
| `advisory` | The finding is LOW/INFO and Copilot is not provably wrong; it is below the fix threshold, so it is never fixed or deferred, however cheap the fix |
| `defer` | The claim holds, the finding is MEDIUM or worse, it concerns code this PR does not change, and the fix is outside this issue's acceptance criteria. A MEDIUM-or-worse finding on changed code is `fix`, or `needs-human` when its fix is genuinely out of scope |
| `already-fixed` | The thread is outdated or on an older commit (`current_head: false`) and the problem is gone at HEAD |
| `copilot-wrong` | The claim does not hold for the actual code, and you can prove it (below) |
| `needs-human` | A MEDIUM-or-worse claim you cannot prove either way from the repo, the diff and the issue, or one on changed code that holds but whose fix is outside this issue |

Split a partly right comment: give the valid part its own disposition and rebut only the wrong part. Prefer the issue's intent over generic style advice. A suggestion that contradicts an acceptance criterion is `copilot-wrong`, with the AC quoted as evidence.

## Evidence bar

`copilot-wrong` needs both a file:line and a command with its output, or a test name and its result, that shows the claim is false. Run the command; never paraphrase what it would print. Without that proof the disposition is `needs-human`, and the evidence field says what you checked and what remains open. For a confirmed claim whose fix is out of scope, the evidence field states the confirmed claim and why the fix is out of scope. `already-fixed` cites the commit and the line where the problem is gone.

## Reply templates

Replies are brief pointers. Fill the placeholders and post nothing else.

| Disposition | Reply |
| - | - |
| `fix` | `Fixed in {short_sha}.` |
| `already-fixed` | `Already fixed in {short_sha} ({path}:{line}).` |
| `advisory` | `Leaving as is ({severity}, below the fix threshold): {reason}.` |
| `defer` | `Valid, out of scope here: tracked in #{issue}.` |
| `copilot-wrong` | `I don't think this applies: {reason}.` then a blank line and the evidence in a fenced block |
| `needs-human` | Unproven: `Not settled from the code: {reason}. Leaving this for the reviewer.` Confirmed but out of scope: `Valid, but the fix is out of scope for this issue: {reason}. Leaving this for the reviewer.` |
