# Lane prompts

Send each prompt to a lane verbatim after substituting the placeholders. Pass it on stdin through a quoted heredoc. A prompt never starts with `!`, never asks a lane to approve or merge a PR, never passes `--no-slack` or `--no-copilot` or stops `/sdlc:pull-request` before its Slack announcement, and carries no context-usage instruction.

| Placeholder | Value |
| - | - |
| `<lane>` | Lane name, such as `lane-42` |
| `<KEY>` | The row's key, such as `#42` or `LT-02` |
| `<reviewer>` | The run file's reviewer GitHub login |
| `<PR>` | `<project>#<n>` and its URL |
| `<n>` | The PR's number |
| `<branch>` | The lane's branch |
| `<base>` | The PR's base branch, else the base `sdlc:implement` recorded for the branch |
| `<reviewers-flag>` | `--model-by-review-tier` when the row's Model/effort cell ends `reviewers by tier`, else `--no-model-by-review-tier` |
| `<files>` | Paths to carry, one per line |
| `<note>` | A pasted review comment or review with its author |

## start

```text
You are <lane>. You are already on branch <branch> in a dedicated worktree. Implement <KEY> here: /sdlc:implement <KEY>; at its branch step keep <branch> (do not check out the base branch or cut another branch), then /sdlc:review --auto <reviewers-flag> to a Gate 1 lock (remediate every in-scope MEDIUM+), then /sdlc:pull-request with <reviewer> among its reviewers, through its Copilot review and, when Slack is enabled, its Slack PR announcement, and report the PR and the announcement's Slack link. Read the story in full first; stay inside its scope. Stop and report at each gate. If auto mode blocks an action, do not work around it or skip the step; stop and report the action and the block reason.
```

## fresh restart

Sent to a new session in the lane's pane. The session has no memory; it rebuilds from git state, the story and the PR.

```text
You are <lane>, restarted in a fresh session. Work on <KEY> in this worktree, on branch <branch>; never check out the base branch or cut another branch. Rebuild your position before acting: read the story in full, run git status and git log origin/<base>..HEAD, and read the PR if one exists (<PR>). Continue from the first step of /sdlc:implement, /sdlc:review --auto <reviewers-flag> (to a Gate 1 lock, remediating every in-scope MEDIUM+; once the PR is open, re-lock with /sdlc:review <reviewers-flag> as Branch Diff, without --auto) and /sdlc:pull-request (reviewer <reviewer>, through its Copilot review and, when Slack is enabled, its Slack PR announcement) that is not yet done; report the PR and the announcement's Slack link. Stay inside the story's scope. Stop and report at each gate, starting with a one-paragraph statement of where you found the work. If auto mode blocks an action, do not work around it or skip the step; stop and report the action and the block reason.
```

## resume

Sent to the same session after a crash or pane reset.

```text
You are <lane>; your session was interrupted. Check git status and the last commit, confirm the worktree is intact, and continue <KEY> from where you stopped. Stop and report at the next gate. If auto mode blocks an action, do not work around it or skip the step; stop and report the action and the block reason.
```

## post announcement

Sent when the lane's project is Slack on and its PR has no announcement link in its row.

```text
<lane>: <PR> needs its Slack PR announcement. If one for <PR> is already in the channel sdlc's settings name (slack.channel), report that message's Slack link and post nothing. Otherwise post one top-level message as /sdlc:pull-request's Phase 9 builds it (its PR Announcement template and its channel resolution), binding each input from this existing PR: number, title, URL, branch and base come from gh pr view <n>; file stats come from git diff --shortstat origin/<base>...HEAD; the caveat line comes from the review file's Gate 1 status for the PR's head (SHA drift or an override) and from checks at the head that have not passed, else leave it out; the Copilot line comes from Copilot's current review of the PR, else leave it out. Create no PR, change no reviewer, set no issue label, and run no Copilot review. Stop and report the announcement's Slack link, or why it could not be posted.
```

## fix findings

```text
<lane>: <PR> has new review comments.

<note>

Fix each finding that is in scope for <KEY>, test first, and push. For Copilot threads, run /sdlc:copilot-review #<n> and follow its dispositions (it replies in the thread and resolves only what it may). For a human reviewer's comment, answer with a new top-level PR comment that names the thread's file:line and states what changed (commit) or why not; do not reply inside the thread and do not resolve it. If the code changed, re-lock Gate 1 before reporting: run /sdlc:review <reviewers-flag> as Branch Diff, without --auto. A finding that needs a change to the story's scope, a design, an interface or an ADR: do not act on it; report it with one question, options and your recommendation. Stop and report when done.
```

## fix checks

```text
<lane>: the checks at the head of <PR> are <failed|incomplete|none>. List them with gh pr checks <n>, read each failed run's log with gh run view <run id> --log-failed, find the root cause, fix it test first, and push. A failure that comes from the base branch or another repo, or checks that are incomplete or none with no failure to fix: report it with the check name and log excerpt instead of working around it. Never add a CI skip token. Stop and report when the checks pass.
```

## merge main

```text
<lane>: <branch> needs <base>'s changes (<reason>). Run git fetch, then git merge origin/<base> into the branch; do not rebase and do not force-push. Resolve a conflict only inside your own change; a conflict in someone else's work: stop and report the files. Re-run the story's tests and the build, then push. Stop and report when the merge is pushed and the tests pass.
```

## carry files

```text
<lane>: bring these files into <PR> as one commit, then push:

<files>

Copy each from the path or branch the conductor names; change nothing in them. If the PR's Gate 1 lock covers the head, commit them as a docs-only change, run /sdlc:review <reviewers-flag> once as Branch Diff, without --auto, to re-lock, and report. Stop and report when pushed.
```
