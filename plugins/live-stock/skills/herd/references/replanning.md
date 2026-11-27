# Replanning

herd may change the plan inside the epic's intent and its ADRs. Anything beyond that goes up.

## Contents

- Guardrails with examples
- File a follow-up story
- Rescope
- Park
- Decisions log

## Guardrails with examples

| Action | Side | Example |
| - | - | - |
| Narrow a story's scope | herd decides | A lane proves a criterion needs a second repo; the story keeps the first repo and the rest becomes a follow-up |
| Split out a follow-up | herd decides | Review finds a gap that is real but outside the story |
| File a story for a gap a lane found | herd decides | A lane's audit shows an unhandled input type the epic did not list |
| Reorder rows | herd decides | A lane's release unblocks a row that was listed later |
| Park on an outside blocker | herd decides | A staging service the story tests against is unreachable; the lane parks at the step that needs it |
| Drop a hold herd set itself | herd decides | The `After` PR merged and the base CI at its merge commit is green |
| Change a design, interface or ADR | escalate to the reviewer | A lane proposes a different list format between two components |
| Drop an acceptance criterion | escalate to the reviewer | A criterion is too costly for the estimate |
| Anything cross-team | escalate to the reviewer | A change needs another team's repo or release |
| Open a new epic | escalate to the reviewer | A set of follow-ups grows into its own theme |
| Credentials, settings, production access | park for the stand-in | A registry token, a required-check setting, a service-account grant |
| Merge conflict in someone else's work | escalate to the reviewer | A rebase would rewrite another engineer's commits |

```text
for any change:
  if it fits the left column and stays inside the story's intent and its ADRs: do it, log it
  else: escalate or park per the right column; the affected lane waits on that item only
```

## File a follow-up story

```text
write the story file from the epic's story template: intent and acceptance criteria, no implementation steps
for step in [create-standalone --file <file>,                  # prepares the file, creates the issue, reads it back
             reparent --key <new issue number> --parent <the story's epic issue number>]:
  result = sdlc:plan <step>
  if not (result ends with its "✅ Done" line and reports no readback findings):
    park the source row (Park) with sdlc:plan's last line, or "no result", as the Hold reason; stop here
link it in the work plan per the plan's "on a finding while working":
  new hard dependency -> add the new key (#<n>) to the row's Hard deps
  new outside blocker -> add a P row with an Owner and the rows it blocks
  open question       -> add a Q row with one Owner
add the key to Candidates when the plan lacks next_work
log it in Decisions; add it to the end-of-run summary's Follow-ups
```

The story file rides in a PR of its repo (Carries) when that repo is `pr-only`.

## Rescope

```text
edit the story file: change only the affected criteria and scope lines
result = sdlc:plan update --file <story file>      # prepares, publishes, reads the issue back; skip it when the row has no issue
if not (result ends with its "✅ Done" line and reports no readback findings):
  park the row (Park) with sdlc:plan's last line, or "no result", as the Hold reason; stop here
update the work plan row's cells you changed
tell the owning lane in one prompt: what changed and which commit state to keep
log it in Decisions with the evidence that forced it
```

A rescope never removes an acceptance criterion; moving one to a follow-up story is a split.

## Park

```text
set the lane row State to parked
add a Hold: <reason> | owner | what unparks it
leave the worktree and session in place unless the lane is wedged
note it on the PR or issue, and in the "For <stand-in>" list
```

## Decisions log

One line per decision, in the run file, in time order. The end-of-run summary groups these lines.

```text
- <HH:MM> | <kind> | <KEY or PR> | <what> | <why> | <evidence>
```

| Field | Value |
| - | - |
| time | Local time of the decision |
| kind | `preflight`, `gate`, `merge`, `rerequest`, `reviewer-changes`, `finish`, `replan`, `park`, `escalate`, `reconcile`, `default`, `start`, `rung`, `red-flag`, `for-stand-in`, `merge-refused`, `watch-error`, `reconcile-skip`, `unrouted` |
| key | The row's key (`#42`, `LT-02`), or `<project>#<n>` for a PR |
| what | The action taken, in one clause |
| why | The reason, in one clause |
| evidence | A commit sha, PR comment or review id, workflow run id, Slack ts or a pane excerpt reference |

Example: `- 14:05 | replan | #42 | split the export to a follow-up | the second repo is outside the story | lane report, commit abc1234`

SKILL.md and finish.md quote each line they log without its `- <HH:MM> | ` prefix; write the prefix on every line.
