# Finish

`finish(row)` runs once per story, after its PR merged and the base branch's CI at the merge commit is green (or the project's `main_ci` is false). Run the work plan's own `finish(row)` when it defines one, and add the steps below that it lacks.

## Contents

- Order
- Story file ticks
- Issue sync
- Issue close
- Done line
- Plan finish
- Carries
- Usage
- Default without a plan finish

## Order

Each step is logged in Decisions as `finish <KEY> step <n> done` when it completes, so a finish interrupted by a compaction resumes where it stopped. Every step checks its own result first (ticks present, body matches, issue closed, line posted) and skips what is already done.

```text
require: the PR is merged and the base CI is green or main_ci is false (a release workflow, when the story ships one, has finished)
State finishing; write it to the run file now     # a compaction inside finish then resumes it
unproven = Definition of Done items this run cannot prove (a manual deploy step, a human settings change)
for n, step in [1 tick the story file, 2 sync the issue body and verify the readback, 3 close the issue as completed,
                4 post the Done line, 5 run the plan's finish(row), 6 record carries for the next PR of that repo]:
  if Decisions has "finish <KEY> step <n> done": continue
  if unproven and n in (3, 4, 5):
    skip it                                   # the story is not done until the stand-in settles the rest
    continue
  run step
  if the step stopped (sdlc:plan update did not end with its "✅ Done" line free of readback findings, the issue could not be closed as completed, a gh error):
    State parked; Hold "<KEY> finish stopped at step <n>: <reason>"; add it to the "For <stand-in>" list
    escalate to the stand-in once (Escalation message); return
  log "finish <KEY> step <n> done"
if unproven:
  State parked; Hold "<KEY> DoD <items> need <stand-in>"; add each item to the "For <stand-in>" list
else:
  record usage (Usage); State finished; then close the lane (SKILL.md Merge: Close the lane)
```

A parked row with only stand-in items open counts as settled for Done-when. When the stand-in reports the items done, tick them, run steps 3 to 5, record usage (Usage), then State finished and close the lane (SKILL.md Merge: Close the lane).

## Story file ticks

Tick every Definition of Done and Test Plan item that has evidence from the merged PR, its checks, the base CI or the lane's report. Never tick on the lane's say-so alone.

```text
if the story file's repo allows direct pushes (config main_push is direct):
  commit the ticks with the plan's conventional message and push to the base branch
else:                                          # main_push is pr-only
  add the ticked file to Carries for that repo; the next PR of that repo brings it (lane-prompts "carry files")
  if no further PR in that repo is planned: open one small docs PR for the ticks
```

Delegate the edit to a haiku / low subagent; read the diff before committing.

## Issue sync

Skip this step, logging it done, when the row has no issue.

```text
result = sdlc:plan update --file <story file>      # publishes the body, then reads the issue back
if not (result ends with its "✅ Done" line and reports no readback findings):
  the step stopped (Order, failure exit) with sdlc:plan's last line, or "no result", as its reason
```

The story file comes from the base branch (after the merge), so it matches what shipped.

## Issue close

Skip this step, logging it done, when the row has no issue. A merged PR that says `Closes #<n>` may already have closed it.

```text
i = gh issue view <n> -R <repo> --json state,stateReason,labels
if the read fails: the step stopped (Order, failure exit) with gh's first stderr line
if i.state == CLOSED and i.stateReason != COMPLETED:
  the step stopped (Order, failure exit) with "closed as <stateReason>"      # declined; never reopen it
stale = i's status:* labels other than status:done
if status:done is not in i.labels or stale:
  gh issue edit <n> -R <repo> --add-label status:done [--remove-label <stale, comma-separated>]
  if it fails because the label does not exist: gh label create status:done -R <repo>; retry the edit once
if i.state == OPEN: gh issue close <n> -R <repo> --reason completed
read the issue back
if not (state CLOSED, stateReason COMPLETED and labels hold status:done and no other status:*):
  the step stopped (Order, failure exit) with what the readback shows
```

Closing as not planned means declined; it never finishes a story.

## Done line

Post through the plan's `post_progress`, one line: `✅ Done <KEY> — <what it delivered>`.

```text
claims = every factual statement in the line (merged, released version, base CI green)
for claim in claims:
  if no evidence from this run: remove the claim or prove it first
post
```

Keep a posted message's timestamp or URL in Decisions. With no `post_progress` in the plan, skip the post.

## Plan finish

Run the plan's `finish(row)` as written: set the row's status, move interface and milestone rows whose stories are all done, and commit the plan update in the form the plan states.

## Carries

```text
for file in files finish changed but could not commit directly:
  add to Carries: <file> -> <project> next PR
when a lane opens a PR in that project:
  send lane-prompts "carry files" with the Carries for that project
  after the PR merges: delete those Carries
```

## Usage

Run `node <skill-dir>/bin/herd-usage.js` with a `--session` for every session id in the lane's Session cell, and write its numbers to the run file's Usage table beside the rungs the lane ran (`R2`, or `R2→R3` or `R2→opus/xhigh` after a restart at another model). Tokens only, no prices. An error (a transcript missing) goes in the row as the error text; it never stops the finish.

## Default without a plan finish

With no plan `finish(row)`, run Order with step 5 skipped and log "default used for finish" in Decisions.
