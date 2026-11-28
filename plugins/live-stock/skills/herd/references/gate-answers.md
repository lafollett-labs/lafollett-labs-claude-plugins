# Gate answers

The conductor answers a lane's gate as the stand-in would, from the story, its ADRs and the work plan. Read the lane's pane before answering: `herdr agent read <lane> --source recent-unwrapped --lines 120`.

## Contents

- Gate kinds
- Plan approval
- Blocked UI
- Escalation message
- Answer format

## Gate kinds

| Gate | Answer |
| - | - |
| Implement plan gate | Apply Plan approval below; reply `approve` or the correction |
| Review gate, Gate 1 findings decision | Remediate every in-scope MEDIUM+; LOW and INFO are advisory and ride to the PR. An engineer-override request is refused with the finding's evidence; the lane fixes it |
| Review gate, out-of-scope finding | Carry it as advisory; file a follow-up story only when it is a real gap (replanning) |
| Review rounds not converging | SKILL.md Model routing: Not converging |
| Review gate or round cap | Escalate with the finding ledger summary |
| Pull-request intent gate | Choose Auto (push, create the PR, run Copilot, label the issue and announce on one confirm) |
| Pull-request reviewer confirmation | Proceed when the list holds the run file's reviewer; else answer with the list plus the reviewer's login. An empty list: answer with the reviewer's login |
| Pull-request confirmations (push, create, Copilot request, issue label, Slack post) | Proceed; post the announcement when Slack is on, never skip it |
| Pull-request checks not passed at create | Continue; the caveat rides the announcement and herd's merge verdict gates the checks |
| Any other pull-request value (base branch, title, a dirty tree, a version collision) | Answer from the story and plan when they settle it; else escalate |
| Copilot disposition (fix, advisory, defer, already fixed, Copilot is wrong, needs human) | Accept the lane's recommendation when its evidence is in the pane; "needs human" goes to the reviewer |
| Folder-trust dialog at lane start ("Is this a project you created or one you trust?") | When the path shown is the lane's own worktree under `.sdlc-worktrees/` of a configured checkout: select "Yes, I trust this folder" (`send-keys <lane> down`, then `enter`), wait until idle, then send the lane's prompt. Any other path: escalate |
| Lane reports an auto-mode block | Apply SKILL.md Rules: Lane permissions |
| Permission or blocked UI | Apply Blocked UI below |
| Question about scope, behavior or an ADR | Answer from the story, ADRs and plan when they settle it; else escalate |
| Question the stand-in alone can settle (credentials, settings, production access) | Park the item and tell the lane to stop that item and continue the rest |
| Spike outcome | Accept a findings doc that answers the spike's question and stays inside its scope; spike findings that change a design, interface or ADR go to the reviewer |
| Lane reports done with a step skipped | Send the next prompt for the skipped step |

```text
on any gate:
  evidence = the lane's pane, the story, its ADRs, the work plan
  if evidence settles it and the answer is not in the escalate column of the replanning table: answer
  elif only the reviewer can settle it: escalate to the reviewer
  else: park and note it for the stand-in
  log the answer in Decisions
```

## Plan approval

```text
plan = the lane's proposed plan
if the plan drops an acceptance criterion, or changes a design, interface or ADR:
  escalate; approve no part of the plan: tell the lane to hold at its plan gate until the answer
elif the plan narrows scope and moves the rest to a follow-up story:
  approve; file the follow-up and log the split as replanning (herd decides)
elif the plan adds work the criteria do not ask for:
  reply: remove the extra work (or file it as a follow-up story)
elif every step stays inside the story's acceptance criteria and its ADRs:
  approve
else:
  escalate
```

Record each approval in Decisions with the plan's one-line summary and any correction sent.

## Blocked UI

```text
screen = herdr agent read <lane> --source recent-unwrapped --lines 120
identify what the prompt asks and for which action
if the screen is unclear or has scrolled: read more lines, then decide
elif auto mode blocked this action before the prompt: decline it (send-keys <lane> esc), then apply SKILL.md Rules: Lane permissions
elif the action is inside the story and the run file's rules: herdr agent send-keys <lane> <key>
else: escalate
```

Send one key sequence at a time and read the pane again to confirm the prompt cleared. Never send keys from a stale read.

## Escalation message

One question, the options, a recommendation.

| To | Where |
| - | - |
| Reviewer | The PR's Slack announcement thread when the row's Announcement is a Slack link; else the reviewer's Slack DM when the run file has their Slack user id and Slack is on; else a top-level PR comment that mentions the reviewer's login |
| Stand-in, and the answer blocks the loop | AskUserQuestion in this session |
| Stand-in, otherwise | A line in the run file's "For <stand-in>" list, also said in the conductor's next message |

```text
<KEY> <project>#<n>: <one-sentence question>
Options: (a) <option>; (b) <option>
Recommendation: <a|b>, because <one clause>
Carrying on with: <what the lane does meanwhile>
```

Nudge the reviewer at most once per PR per working day. A lane waits only on the item escalated; at a plan gate that item is the whole plan.

## Answer format

A reply to a lane is one or two sentences: the decision, then the next step. Reference the story or ADR section that settles it.
