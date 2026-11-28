---
name: pull-request
description: >-
  Takes a branch with committed code through review-verdict consumption, branch/commit validation, reviewer resolution (settings, then CODEOWNERS, then ask), push, gh pr create (assignee and reviewers set at create time), the head's CI checks, a Copilot code review evaluated locally, the issue's status:in-review label and progress comment, and an optional Slack announcement (when slack.enabled; skippable with --no-slack). Standalone — does not require deliver and never invokes PE agents (the review verdict is read through review-file.js parse). Also nudges an idle PR: a Slack thread reply when Slack is enabled, else a PR comment. This skill should be used when the engineer says "Open the PR", "Create the pull request", "Ship this branch", "/sdlc:pull-request", or "Nudge PR #N", or when invoked by sdlc:deliver.
argument-hint: "[PR#|URL to nudge | --auto for the unattended author path] [--no-slack] [--no-copilot]"
---

# Pull Request (sdlc:pull-request)

Initial input: `$ARGUMENTS`

Takes a committed branch to a pushed branch, a GitHub pull request, a Copilot review, the issue's `status:in-review` label, and an optional Slack announcement.

```text
phases:
  1 — Pre-flight                 gh auth + repo + labels; settings; Slack MCP; author login
  2 — Branch + commit validation  branch pattern, base branch, Conventional Commits
  3 — Review verdict             read the review via review-file.js parse (no PE dispatch)
  4 — Reviewers                  settings → CODEOWNERS → ask
  5 — PR description             render assets/pr-description-template.md
  6 — Push + create PR           gh pr create --assignee @me --reviewer …; CI via pr-checks.js
  7 — Copilot review             request, wait, evaluate locally (sdlc:copilot-review)
  8 — Issue status              status:in-review label + progress comment
  9 — Slack announcement         optional; settings.slack.channel, on the settled head

nudge (separate top-level):
  1 — Warrant check              state OPEN, no activity, age threshold
  2 — Ping                       Slack thread reply (Slack enabled) or a PR comment
```

## Operating Principles

```text
use TaskCreate / TaskUpdate to track every phase:
  mark in_progress when starting; completed when done

blocking gates: Phase 2 (dirty tree, branch name, base branch, commit format), Phase 3 (Gate 1 lock,
  SHA drift), Phase 4 (reviewers), Phase 5 (title/description), Phase 6 (intent; per-step confirms in
  manual mode; CI validation)

review verdict consumption is read-only — never dispatch PE agents

protect user work:
  never push, create the PR, label the issue, comment, or post to Slack without approval
  (one approval in auto mode, per-step in manual)
```

Each phase that lives in a reference reads and writes the same `session.*` state as the body; when the phase starts, read every file in its row (all under `${CLAUDE_PLUGIN_ROOT}`).

| Phase | Load |
| - | - |
| 1 | `references/github-preflight.md`, `references/settings.md` |
| 4 | `skills/pull-request/references/reviewers.md` |
| 5 | `skills/pull-request/references/pr-description.md` |
| 6 | `skills/pull-request/references/push-and-create.md`; plus `references/version-collision-guard.md` when `.claude-plugin/marketplace.json` exists |
| 7 | `skills/pull-request/references/copilot-review.md` |
| 8, 9 | `skills/pull-request/references/announce-and-transition.md`, `references/issue-status-labels.md`, `references/issue-progress-comment.md`, `assets/slack-templates.md` |
| Nudge | `skills/pull-request/references/nudge.md`, `references/settings.md`, `assets/slack-templates.md` |

## User-Facing Output Conventions

| Marker | Meaning |
| - | - |
| 🟡 Waiting on you | paused at an input gate |
| 🤖 Auto-resolved | `--auto` resolved a happy-path gate unattended |
| ⚠️ Warning | advisory, not a pause (commit format, reviewer fallback, no issue to label, field-population mismatch, unvalidated PR head, nudge against recent activity) |
| 🛑 Hard stop | needs out-of-band action (on main, nudge target not `OPEN`, unsafe PR number) |
| ❌ Error | a required step failed (gh missing or unauthenticated, push rejected, `gh pr create` failed) |
| ✅ Done | final summary — exactly one per session (author path OR nudge path) |

Gate rendering — every input gate is presented by INVOKING the AskUserQuestion tool, never as prose:

```text
for each 🟡 / yes-no / choice gate:
  question = gate name + one-line context (branch, PR url, what just happened)
  header   = ≤12-char gate label
  options  = the gate's enumerated choices, each → { label: terse choice, description: trailing clause }
             a stated default/preferred choice is listed FIRST with "(recommended)" appended to its label
  free-text answer (base branch, custom value) → the user's "Other" free-text reply
  the returned selection feeds the existing `match user_response` dispatch UNCHANGED

  if session.auto and the gate is an auto-resolvable happy-path gate:
    skip the tool; resolve per the auto contract; record 🤖
```

Invoke AskUserQuestion only when the user must act, one call per decision; the canonical shape is `AskUserQuestion → "{q}"; options:` then one `({tag}) "label"` per line.

---

## Mode Detection

```text
session.pr_number = null

# Flags are per-invocation; strip them before mode detection.
session.auto       = ("--auto" in tokenize($ARGUMENTS))        # deliver passes it on the author path
session.no_slack   = ("--no-slack" in tokenize($ARGUMENTS))    # skips only the Phase 9 announcement
session.no_copilot = ("--no-copilot" in tokenize($ARGUMENTS))  # skips Phase 7
args = remove "--auto", "--no-slack", "--no-copilot" from $ARGUMENTS, collapse whitespace

if args.lower() in ("", "create", "open"):
  session.mode = "author"
elif re.match(r"^#?(\d+)$", args):
  session.mode      = "nudge"
  session.pr_number = re.match(r"^#?(\d+)$", args).group(1)
elif re.match(r"^https://github\.com/[^/\s]+/[^/\s]+/pull/(\d+)/?$", args):
  session.mode      = "nudge"
  session.pr_number = that group(1)
else:
  ❌ Error — could not interpret '{$ARGUMENTS}'; expected empty (author path) or a PR number / URL (nudge)
  STOP

if session.pr_number is not null AND not re.match(r"^[1-9][0-9]*$", session.pr_number):
  ❌ Error — PR number '{session.pr_number}' is not a positive integer
  STOP

if session.mode == "nudge":
  read ${CLAUDE_PLUGIN_ROOT}/skills/pull-request/references/nudge.md and run it; skip the author path
```

**`--auto` (author path):** auto-resolves the happy-path gates (base → the resolved base, reviewers → accept, title/description → accept, intent → auto), each 🤖-logged. Still HALTS on the version-collision guard, the dirty-tree gate, and a missing Gate 1 lock.

---

## Phase 1 — Pre-flight

```text
run github-preflight.md            # binds session.gh_ok, session.repo, session.status_labels_ok
if not session.gh_ok or session.repo is null:
  ❌ Error — gh cannot call GitHub as a signed-in user, or this checkout has no GitHub remote gh can resolve
  STOP — check `gh auth status`; if PR creation later fails with 403, the token needs the `repo` scope

run settings.md's load_settings()  # binds session.settings
session.slack_on = session.settings.slack.enabled and not session.no_slack
session.author   = `gh api user --jq .login`
```

---

## Phase 2 — Branch + Commit Validation

Branch-name and commit-subject rules come from `git-conventions.js`; the branch name reaches it on stdin through a quoted heredoc, never as a shell argument.

```text
conventions = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js"   # JSON on stdout; exit 0 valid, 1 invalid (carries .error), 2 usage
```

### Branch identity + cleanliness

```text
session.branch   = `git branch --show-current`
session.head_sha = `git rev-parse HEAD`

(v, ec) = `gh pr view --json number,state`              # the current branch's PR, if any
session.existing_pr = v.number if ec == 0 and v.state == "OPEN" else null
(r, ec) = {conventions} base + (" --pr {session.existing_pr}" if session.existing_pr else "")
session.default_base = r.base if ec == 0 else "main"   # PR base > branch.<b>.sdlc-base > origin/HEAD > main
session.base_source  = r.source if ec == 0 else "fallback"
if ec != 0: ⚠️ Warning — cannot resolve the base ({r.error}); defaulting to main

if session.branch == session.default_base or session.branch in ("main", "master"):
  🛑 cannot open a PR from the base branch {session.branch}
  STOP — switch to a feature branch first

if `git status --porcelain` is non-empty:     # never auto-stash — the branch is supposed to be PR-ready
  🟡 Waiting on you — uncommitted changes on `{session.branch}`
  AskUserQuestion → "Uncommitted changes on {session.branch} — how to proceed?"; options:
    (a) "Commit first — exit /pull-request; re-run after"
    (b) "Abort"
  exit                                          # both options exit
```

### Branch-name parse

```text
b = {conventions} branch <<'BRANCH_NAME'
{session.branch}
BRANCH_NAME

if b.ok:
  session.branch_type  = b.type
  session.ticket_key   = b.ticket_key        # "#42" | "LT-02"
  session.key_kind     = b.key_kind          # "issue" | "story"
  session.key_slug     = b.key_slug          # "42" | "LT-02"
  session.issue_number = b.issue_number      # 42 | null
  if session.key_kind == "story":
    session.story_file = the one file under docs/epics/ with a line matching ^\*\*Code:\*\* +{session.ticket_key} *$ (null when none)
    n = `.issues["{basename(session.story_file)}"]` in "{dirname(session.story_file)}/.github-state.json"   # sdlc:plan's file → issue map
    session.issue_number = n if n is a number else null
else:
  ⚠️ Warning — {b.error}
  🟡 Waiting on you — branch name non-conformant on `{session.branch}`
  AskUserQuestion → "Branch {session.branch} doesn't match <type>/<42|LT-02>-<description> — how to proceed?"; options:
    (a) "Rename branch — git branch -m '{session.branch}' '<new-name>', then re-run /pull-request"
    (b) "Proceed anyway — PR opened without an issue label or progress comment"
    (c) "Abort"

  match user_response:
    case (a): exit
    case (b): session.branch_type = session.ticket_key = session.key_kind = session.key_slug = session.issue_number = null
    case (c): exit
```

### Base branch

```text
if session.auto:
  session.base_branch = session.default_base
  🤖 Auto-resolved — base branch → {session.default_base} ({session.base_source}) (auto)
else:
  🟡 Waiting on you — base branch
  AskUserQuestion → "What branch should this PR target? (default: {session.default_base}, from {session.base_source})"; options:
    (default) "{session.default_base} (recommended)"
  free-text "Other" reply → a custom branch name (validated below)

  if user_response is blank or (default):
    session.base_branch = session.default_base
  elif re.match(r"^(?!\.)(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._/-]*$", user_response)
       AND not user_response.endswith((".", "/", ".lock"))
       AND `git check-ref-format --branch '{user_response}'` exits 0:
    session.base_branch = user_response
  else:
    ❌ Error — "{user_response}" is not a valid branch ref
    re-prompt

git fetch origin '{session.base_branch}' --prune

if `git show-ref --verify --quiet 'refs/remotes/origin/{session.base_branch}'` fails:
  ❌ Error — origin/{session.base_branch} not found after fetch
  STOP — ask the user to confirm the base branch name
```

### Branch must be ahead of base

```text
session.commit_count = `git rev-list --count 'origin/{session.base_branch}..HEAD'`

if session.commit_count == 0:
  🛑 branch has no commits ahead of origin/{session.base_branch}
  STOP — nothing to open a PR for

session.file_stats = parse `git diff --shortstat 'origin/{session.base_branch}...HEAD'`   # → {files, added, removed}
session.first_commit_subject = `git log --no-merges 'origin/{session.base_branch}..HEAD' --reverse --format=%s` → first line
```

### Conventional Commits validation

```text
c = `git log --no-merges 'origin/{session.base_branch}..HEAD' --format=%s` | {conventions} commits   # merge commits are not checked

if not c.ok:
  ⚠️ Warning — {c.error}
  list each offender as "{subject} — {error}"
  note: "squash-merge uses the PR title — these subjects won't reach main,
         but the first commit subject is the default PR title"

  🟡 Waiting on you — Conventional Commits violations
  AskUserQuestion → "{len(c.offenders)} commit(s) don't match Conventional Commits — how to proceed?"; options:
    (a) "Rewrite them outside this skill → exit /pull-request"
    (b) "Proceed anyway — squash-merge keeps only the PR title"
    (c) "Abort"

  match user_response:
    case (a): exit
    case (b): continue
    case (c): exit
```

---

## Phase 3 — Review Verdict Consumption

`review-file.js parse` is the one reader of the review file; `sdlc:deliver` reads the same fields from it.

```text
session.name         = session.key_slug if not null else slugify(session.branch)   # one {name}-code-review.md per story; rounds append
session.slack_caveat = null    # ⚠️ risk line(s) for the Slack post and the progress comment; set by Phase 3 and Phase 6; may be multi-line

(r, ec) = node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" parse --root "$(git rev-parse --show-toplevel)" --name '{session.name}'
if ec != 0: ⚠️ Warning — could not read the review (exit {ec}): {r.error}; treating it as having no Gate 1 lock; r = {rounds: []}
session.review_file         = "docs/code-reviews/{session.name}-code-review.md"
session.gate1               = r.gate1 or {state: "none"}   # {state: locked | overridden | open | none, round, sha}: the latest Gate 1 round
g = the round in r.rounds whose n == session.gate1.round, else null   # Gate 1 only: a legacy Gate 2 round in the doc is never read
session.review_present      = (g is not null)
session.review_verdict      = g.verdict      if g else null   # "✅ APPROVED" | "⚠️ CHANGES REQUESTED" | "🚫 BLOCKED"
session.review_round_n      = g.n            if g else null
session.review_advisory     = g.advisory     if g else []     # [{id, severity, title, location}]
session.gate1_closed        = session.gate1.state in ("locked", "overridden")

if session.gate1.state == "overridden":
  session.slack_caveat = "⚠️ Gate 1 closed by an engineer override (round {session.gate1.round}); see {session.review_file}"

# SHA currency matters only once Gate 1 is closed — an open gate is gated below regardless.
# Code-equivalence: exit 0 = only review-doc changes since that round; 1 = code changed; >1 = unknown SHA.
if session.gate1_closed and session.gate1.sha != session.head_sha
   and `git diff --quiet '{session.gate1.sha}' HEAD -- . ':!docs/code-reviews/'` exits non-zero:
  ⚠️ Warning — Gate 1 closed at SHA {session.gate1.sha}; HEAD is now {session.head_sha} with code changes
  🟡 Waiting on you — review SHA drift
  AskUserQuestion → "Gate 1 closed at SHA {session.gate1.sha}; HEAD is now {session.head_sha} — how to proceed?"; options:
    (a) "Re-run sdlc:review first (recommended) — exit"
    (b) "Proceed anyway — the announcement flags the SHA drift"

  match user_response:
    case (a): exit
    case (b): session.slack_caveat = join_nonempty([session.slack_caveat, "⚠️ Gate 1 closed at {short session.gate1.sha}; the code has changed since."], "\n")
```

### Gate 1 completion gate

The committed review file is the author's proof of due diligence; never open a PR without a Gate 1 lock unless the author overrides it on the record.

```text
if not session.gate1_closed:
  🟡 Waiting on you — no Gate 1 lock in {session.review_file}
  restate: {"no recorded review" if session.gate1.state == "none"
            else "the latest Gate 1 round (round {session.gate1.round}) is not LOCKED (verdict {session.review_verdict})"}
           — Gate 2 presupposes a Gate 1 lock (2 consecutive clean self-review rounds)

  if session.auto:                     # unattended: never open a PR without a lock
    🤖 Auto-resolved — no Gate 1 lock; not opening a PR unattended (auto) — exit
    exit

  AskUserQuestion → "No Gate 1 lock for this branch — how to proceed?"; options:
    (a) "Run/finish sdlc:review to lock Gate 1 first (recommended) — exit"
    (b) "Override — open the PR without a Gate 1 lock (records a reason; the caveat rides the announcement)"
    (c) "Abort"
  match user_response:
    case (a): exit
    case (b):
      require an explicit second confirmation + a one-line reason   # mandatory pushback, never one-click
      session.slack_caveat = join_nonempty([session.slack_caveat, "⚠️ No Gate 1 self-review lock — author override: {reason}"], "\n")
    case (c): exit
```

---

## Phase 4 — Reviewers

Run `references/reviewers.md`.

## Phase 5 — PR Description

Run `references/pr-description.md`.

## Phase 6 — Push + Create PR

Run `references/push-and-create.md`; its intent gate is set once and reused by Phases 7–9.

## Phase 7 — Copilot Review

Run `references/copilot-review.md`. It never fails the flow, and Copilot fixes never re-run Gate 1.

## Phase 8 — Issue Status

Run Phase 8 of `references/announce-and-transition.md`.

## Phase 9 — Slack Announcement

Run Phase 9 of `references/announce-and-transition.md`.

## End — Author-path Summary

```text
✅ Done — PR opened
  - Issue:     {session.ticket_key or "—"} → {"status:in-review" if session.status_move.changed else "status unchanged (see the warning above)"}
  - Branch:    {session.branch} → {session.base_branch}
  - PR:        #{session.pr_number} {session.pr_url}
  - Assignee:  @{session.author}
  - Reviewers: {csv of session.reviewers, or "none"}
  - CI:        {session.ci_validation}
  - Copilot:   {session.copilot_line}
  - Slack:     posted to #{channel.name} (ts={session.slack_message_ts})
               OR "copy-paste block printed" OR "skipped (manual intent)"
               OR "skipped (--no-slack)" OR "off (slack.enabled is false)"

next steps:
  - Wait for reviewer activity
  - Nudge with `/sdlc:pull-request #{session.pr_number}` if idle > 2-3 days
  - Reviewers run `/sdlc:review` against this PR (Gate 2)
```
