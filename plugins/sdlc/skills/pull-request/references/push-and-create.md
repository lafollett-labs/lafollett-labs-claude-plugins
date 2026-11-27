# Push + Create PR

Loaded by `sdlc:pull-request` Phase 6. Binds `session.intent_gate` (reused by Phases 7–9), `session.pr_url`, `session.pr_number`, and `session.ci_validation`.

## Contents

- Pre-push — version-collision guard
- Intent gate
- Push
- Create the PR
- Post-create verification
- CI validation gate

## Pre-push — version-collision guard

```text
if file_exists(".claude-plugin/marketplace.json"):     # marketplaces only; the guard returns early unless versions are stamped after merge
  run version-collision-guard.md now (SKILL.md loads it with this phase)
  # it 🛑 STOPs the run on a hand-edited version; otherwise Phase 6 continues
```

## Intent gate

```text
write session.pr_description to a temp file <desc_tmpfile>   # both the executed and the skip-mode command read it

if session.intent_gate not set:
  if session.auto:
    session.intent_gate = "(a) auto"
    🤖 Auto-resolved — PR intent → auto (push + create PR + Copilot + label + Slack when enabled, unattended)
  else:
    🟡 Waiting on you — PR creation intent
    AskUserQuestion → "How should the PR be opened for {session.branch}?"; options:
      (a) "Auto — push, create the PR, run Copilot, label the issue and announce on one confirm"
      (b) "Manual — confirm at EACH downstream step"
      (c) "Skip — print the prepared commands; I run them"
    session.intent_gate = (a) | (b) | (c)

if session.intent_gate == "(c) skip":
  print, paste-runnable from bash:
    - git push -u origin '{session.branch}'
    - the gh pr create command (built below) with <desc_tmpfile> resolved to its real path
    - gh issue edit {session.issue_number} --add-label status:in-review --remove-label status:in-progress   (when session.issue_number)
    - the rendered Slack PR Announcement, when session.slack_on
  ✅ Done — skip mode; exit
```

## Push

```text
if session.intent_gate == "(b) manual":
  🟡 Waiting on you — push to origin?
  AskUserQuestion → "Push {session.branch} to origin?"; options:
    (yes) "Push now (recommended)"
    (no) "Skip the push"
  if no: exit

git push -u origin '{session.branch}'
if push fails:
  ❌ Error — git push -u origin {session.branch} rejected
  STOP — print stderr; ask the user to resolve (likely an upstream rewrite or permissions)
```

## Create the PR

```text
if session.existing_pr:                                  # bound in SKILL.md Phase 2
  ⚠️ Warning — PR #{session.existing_pr} is already open for {session.branch}; using it
  session.pr_number = session.existing_pr; session.pr_url = `gh pr view {session.existing_pr} --json url --jq .url`
  skip to Post-create verification

if session.intent_gate == "(b) manual":
  🟡 Waiting on you — create the PR?
  AskUserQuestion → "Run gh pr create for {session.branch}?"; options:
    (yes) "Create now (recommended)"
    (no) "Skip — exit"
  if no: exit
```

The title reaches gh through a quoted heredoc, never as an interpolated shell argument:

```bash
title="$(cat <<'PR_TITLE'
{session.pr_title}
PR_TITLE
)"
gh pr create --base '{session.base_branch}' --head '{session.branch}' \
  --title "$title" --body-file '<desc_tmpfile>' --assignee @me \
  [--reviewer '{csv of session.reviewers}'] [--draft]     # --reviewer when session.reviewers; --draft when settings.pullRequest.draft
```

```text
run it, capturing stdout + stderr + exit code
if exit == 0:
  session.pr_url    = the https://github.com/<owner>/<repo>/pull/<N> line of stdout
  session.pr_number = its trailing integer
elif session.reviewers and stderr names a reviewer (not found, not a collaborator, cannot request):
  ⚠️ Warning — a reviewer could not be requested; creating the PR without --reviewer
  re-run the command without --reviewer; exit != 0 → ❌ Error — gh pr create failed; STOP, print stderr
  parse session.pr_url + session.pr_number as above
  for r in session.reviewers:
    `gh pr edit {session.pr_number} --add-reviewer '{r}'`; on failure ⚠️ Warning — could not request {r}: {stderr}
else:
  ❌ Error — gh pr create failed (exit {exit})
  STOP — print stderr verbatim
```

## Post-create verification

```text
v = `gh pr view {session.pr_number} --json assignees,reviewRequests`
requested = {r.login for user requests} ∪ {r.slug for team requests}   # gh returns a team's slug as org/team

if session.author not in v.assignees[].login or set(session.reviewers) != requested:
  ⚠️ Warning — PR opened but assignee/reviewers differ from the selection
              show expected vs actual; point to {session.pr_url} to fix by hand
```

## CI validation gate

Surface an unvalidated or red head before anyone is pinged; checks run on every commit, so `none` means CI has not reported yet or the repo has no CI.

```text
session.ci_validation = "unvalidated"                       # fail closed
(c, ec) = `node "${CLAUDE_PLUGIN_ROOT}/bin/pr-checks.js" check --pr {session.pr_number} --head {session.head_sha}`
if ec == 0 and c.state == "none":
  wait ~20 s (checks register shortly after a push), then run it once more
status = c.state if ec == 0 else "unreadable: " + c.error

match status:
  "passed":  session.ci_validation = "ok"
  "pending": session.ci_validation = "running"             # real checks cover HEAD
  "failed":  session.ci_validation = "failed"              # red — reviewers must not merge
  else:      session.ci_validation = "unvalidated"         # none | incomplete | unreadable

if session.ci_validation in ("failed", "unvalidated"):
  if session.ci_validation == "failed":
    ci_caveat = "⚠️ CI FAILED on this PR head ({csv of c.failed_checks[].name}) — do not merge red ({session.pr_url}/checks)."
  else:
    ci_caveat = "⚠️ CI has not validated this PR head ({status}) — do not merge until checks pass."
  session.slack_caveat = (session.slack_caveat + "\n" + ci_caveat) if session.slack_caveat else ci_caveat   # APPEND; a Phase 3 caveat may already be set
  ⚠️ Warning — PR head checks are "{status}"; the caveat rides the announcement and the progress comment
  if not session.auto:
    AskUserQuestion → "PR #{session.pr_number} head is {status}. Proceed?"; options:
      (a) "Continue — the caveat rides the announcement; I'll validate before merge"
      (b) "Abort — stop before Copilot, the label and Slack so I can fix CI first"
    if (b): STOP
```
