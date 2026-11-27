---
name: implement
description: >-
  Takes one ticket, a GitHub issue (#42) or a local story code (LT-02) from docs/epics, from read to tested, committed code on a conventionally named branch: reads the ticket (gh issue view, or the story file), cuts the branch, labels the issue status:in-progress and writes its progress comment, plans with a scope scout and architect agents behind a hard-stop approval gate, then implements test-first with conventional commits. For a spike it writes and commits a findings doc instead of code. Stops at committed code; review, the PR, and Slack belong to sdlc:review, sdlc:pull-request, and sdlc:deliver. This skill should be used when the engineer says "Implement #42", "Start work on #42", "Implement LT-02", "Pick up this issue and build it", invokes "/sdlc:implement", or when invoked by sdlc:deliver.
argument-hint: "[#ISSUE | STORY-CODE] [--auto] [--incident] [--resume | --start-over]"
---

# Implement

Initial input: `$ARGUMENTS`

## Operating Principles

```text
use TaskCreate / TaskUpdate to track every phase:
  mark in_progress when starting; completed when done

phases 1, 2, 3 have blocking gates:
  Phase 1 — ticket confirmation
  Phase 2 — base branch + dirty tree check
  Phase 3 — plan approval (non-negotiable; under --incident the plan reviewer answers it)

work type carried through every phase:
  feat | fix | chore | docs | refactor | test | spike

spike == true:
  Phase 4 writes docs/spikes/<key_slug>-<slug>.md
  skip code implementation

protect user work:
  never discard / stash / commit / switch / overwrite uncommitted changes
  without explicit user approval

never silently expand scope:
  if Phase 4 work exceeds the approved plan → STOP, surface to user

auto mode (--auto, opt-in, per-invocation):
  auto-resolve the low-judgment happy-path gates (ticket confirm, spike confirm, existing branch → resume, base → ticket target or the default branch), each 🤖-logged.
  the Phase 3 PLAN gate STAYS interactive — the single retained human stop (--incident: see incident mode).
  every EXCEPTION gate HALTS (flip auto off, present the normal gate): closed issue, dirty tree, several ticket branches,
    multi-area gap, scope expansion, flake, AC-coverage gap, warnings, stash-pop conflict.
  --start-over STOPs: a branch is never renamed or deleted unattended.
  WITHOUT --auto: byte-for-byte unchanged.

incident mode (--incident, opt-in, per-invocation; combines with --auto, never implies it):
  sdlc:plan-reviewer answers the Phase 3 PLAN gate; escalate returns it to a person. WITHOUT --incident: byte-for-byte unchanged.

user-input gates are visually marked (see User-Facing Output Conventions below)
```

## User-Facing Output Conventions

```text
🟡 Waiting on you — paused at an input gate (existing branch, base branch, dirty tree, plan approval, flake, AC gap, spike deviation)
🤖 Auto-resolved   — --auto resolved a happy-path gate unattended (never the plan gate; exceptions HALT)
⚠️  Warning        — advisory gate; needs a choice but not necessarily a pause (multi-area gap, user-provided spec)
🛑 Hard stop       — cannot proceed without out-of-band action (empty scope scout, scope expansion, retry limits)
❌ Error           — required step failed (gh unauthenticated, pull --ff-only, invalid base / work_type, stash pop)
✅ Done            — the completion summary (exactly one per session; spike OR standard, never both)
```

Gate rendering — every input gate is presented by INVOKING the AskUserQuestion tool, never as prose:

```text
for each 🟡 / yes-no / choice gate:
  question = gate name + one-line context (branch, verdict, what just happened)
  header   = ≤12-char gate label
  options  = the gate's enumerated choices, each → { label: terse choice, description: trailing clause }
             a stated default/preferred choice is listed FIRST with "(recommended)" appended to its label
  free-text answer (base branch, ticket key, plan-revision feedback, rationale) → the user's "Other"
             free-text reply on the AskUserQuestion prompt
  the returned selection feeds the existing `match user_response` dispatch UNCHANGED —
             only the surface changes, never the gate's options, default, or downstream behavior

  if session.auto and the gate is an auto-resolvable happy-path gate:
    skip the tool; resolve per the auto contract; record 🤖 (never the plan gate; exceptions HALT)
```

```text
rules:
  - invoke AskUserQuestion ONLY when the user must act; never wrap normal status prose
  - canonical shape: `AskUserQuestion → "{q}"; options:` then one `({tag}) "label"` per line (default first + "(recommended)")
  - don't double-up: TaskCreate already shows phase progress
  - one AskUserQuestion per pause; a new decision → a new tool call
```

## Phase 1 — Establish the Ticket

Goal: a known ticket key with ticket context loaded.

```text
# Flags are opt-in and per-invocation; strip them before the key match. Order-independent; NEVER persisted.
session.auto       = ("--auto" in tokenize($ARGUMENTS))
session.incident   = ("--incident" in tokenize($ARGUMENTS))
session.resume     = ("--resume" in tokenize($ARGUMENTS))       # Phase 2: continue on this ticket's branch
session.start_over = ("--start-over" in tokenize($ARGUMENTS))   # Phase 2: set that branch aside
if session.resume and session.start_over: ❌ Error — --resume and --start-over exclude each other; STOP
arg = $ARGUMENTS without those four flags, trimmed
if arg matches /^\d+$/: arg = "#" + arg                      # a bare issue number

if arg is empty:
  ask user for the ticket (#42, or a story code such as LT-02)
  goto Phase 1 start

k = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" key --anchored <<'TICKET_ARG'
{arg}
TICKET_ARG
if exit != 0:
  ❌ Error — "{arg}" is not a ticket key (#42 or LT-02); ask again; goto Phase 1 start

session.ticket_key   = k.ticket_key      # "#42" | "LT-02" — validated, safe to interpolate
session.key_kind     = k.key_kind        # "issue" | "story"
session.key_slug     = k.key_slug        # "42" | "LT-02" — file and stash names
session.issue_number = k.issue_number    # 42 | null
```

Read the ticket:

```text
match session.key_kind:
  case "issue":
    ticket = read_issue(session.issue_number)
  case "story":
    matches = `grep -rlE '^\*\*Code:\*\* +{session.ticket_key} *$' docs/epics --include='*.md'`
    matches = [m for m in matches if m matches ^[A-Za-z0-9._/-]+$ and has no ".."]
    if matches is empty:
      ticket = null
    else:
      if len(matches) > 1:
        🟡 Waiting on you — story code in more than one file
        AskUserQuestion → "{session.ticket_key} appears in several story files — which one?"; options: one per path
      session.story_file = the chosen match
      md = read(session.story_file)
      ticket = { title: first "# " heading without a leading "Story:" | "Task:" | "Bug:" label,
                 body:  md,
                 type:  the file-name type ("NN-<Type>-…": Story | Task | Bug) or the heading label,
                 state: "OPEN" }
      n = `.issues["{basename(session.story_file)}"]` in "{dirname(session.story_file)}/.github-state.json"   # sdlc:plan's file → issue map
      if n is a number:
        if preflight_ok():
          session.issue_number = n       # a published story: label and comment its issue; the file stays the ticket
        else:
          ⚠️ Warning — gh unavailable; {session.ticket_key} proceeds without labelling or commenting on #{n}

preflight_ok():                          # runs once; later calls return the first result
  read ${CLAUDE_PLUGIN_ROOT}/references/github-preflight.md and run it   # binds session.gh_ok, session.repo, session.status_labels_ok
  return session.gh_ok and session.repo is not null

read_issue(n):
  if not preflight_ok():
    ❌ Error — gh is unavailable or unauthenticated; tell the user to run `gh auth login`; STOP
  t = gh issue view {n} --json number,title,body,labels,state
  if exit != 0: return null
  labels = [lower(l.name) for l in t.labels]
  return { title: t.title, body: t.body, state: t.state, type: TYPE_FROM_LABELS(labels) }

TYPE_FROM_LABELS(labels):                # first hit in this order; none → null
  "epic" → "Epic" · "spike" → "Spike" · "bug" → "Bug" · "story" | "enhancement" | "feature" → "Story"
  "documentation" → "Docs" · "task" → "Task"
```

Present a 3–5 line summary (key, title, type, state, ACs, key context). Confirm with user before continuing.

```text
if no ticket found:
  STOP — ask user to create a ticket (offer sdlc:plan) and re-run    # error, not a happy-path confirm
if ticket.type == "Epic":
  ❌ Error — {session.ticket_key} is an epic; implement one of its sub-issues
     (`gh api repos/{session.repo}/issues/{session.issue_number}/sub_issues`); STOP
if ticket.state == "CLOSED":
  ⚠️ Warning — {session.ticket_key} is closed; confirm you mean to reopen the work
  session.auto = false                                                # exception gate — HALT to interactive
if session.auto:
  🤖 Auto-resolved — ticket {session.ticket_key} accepted (auto)       # happy-path confirm auto-resolved
elif user does not confirm:
  STOP — ask user to create a ticket (offer sdlc:plan) and re-run
```

Spike detection (must run BEFORE work_type derivation so the Story+spike case can override):

```text
if ticket.type == "Spike" OR ticket.ACs describe research not code:
  spike = true
  if session.auto:
    🤖 Auto-resolved — spike classification accepted (auto); spike path writes a findings doc, no PR
  else:
    confirm with user before continuing
```

Derive `work_type` from `ticket.type`:

```text
VALID_WORK_TYPES = ["feat", "fix", "chore", "docs", "refactor", "test"]

match ticket.type:
  case "Story":
    work_type = "feat"
    if spike == true:                        # Story flagged as spike-by-ACs → chore
      work_type = "chore"
  case "Bug":     work_type = "fix"
  case "Spike":   work_type = "chore"        # spike == true already set above
  case "Docs":    work_type = "docs"
  case "Task" | null:                        # null = no type label
    inspect ticket.ACs and pick the dominant intent:
      new behavior                              → work_type = "feat"
      refactoring / cleanup / no new behavior  → work_type = "refactor"
      tests only                                → work_type = "test"
      docs only                                 → work_type = "docs"
      deps / config / build only                → work_type = "chore"
      anything else / mixed                     → prompt_for_work_type()

prompt_for_work_type(context = ""):
  session.work_type_prompts = (session.work_type_prompts or 0) + 1

  if session.work_type_prompts > 3:
    🛑 Hard stop — work_type prompt reached after 3 attempts
    ask user to either pick a valid value or abort /implement
    do NOT loop further

  🟡 Waiting on you — work type
  AskUserQuestion → "{context} — pick the work type"; options:
    (feat) "new consumer-facing functionality"
    (fix) "bug fix"
    (chore) "maintenance / deps / build / config"
    (docs) "documentation only"
    (refactor) "code improvement, no behavior change"
    (test) "adding or modifying tests"
  if user_response.lower().strip() in VALID_WORK_TYPES:
    work_type = user_response.lower().strip()
  else:
    ❌ Error — "{user_response}" is not a valid work_type
    re-prompt with the canonical list
```

Carry to session state — single `session.` namespace throughout the skill:

```text
session.ticket_title    = ticket.title
session.ticket_body     = ticket.body                               # the incident evidence under --incident
session.work_type       = <derived above>
session.spike           = <bool>
session.ticket_acs      = items under the body's "## Acceptance Criteria": each "### Scenario:" title,
                          else each list item                       # used by Phase 4 AC tracking
```

## Phase 2 — Create the Branch

Goal: a properly named local branch from the correct base.

Pre-flight:

```text
git status --short
git branch --show-current
git remote -v

dirty = (`git status --short` produces any output)

if dirty: load references/stash-restore.md and run its § Dirty-tree gate
```

Existing branch — this ticket's branch, local first, else origin's:

```text
git fetch --quiet origin                                    # a failure is fine; local refs still count
found = `git for-each-ref --format='%(refname:short)' 'refs/heads/*/{session.key_slug}-*' 'refs/heads/*/{session.key_slug}'`
if found is empty:
  found = `git for-each-ref --format='%(refname:lstrip=3)' 'refs/remotes/origin/*/{session.key_slug}-*' 'refs/remotes/origin/*/{session.key_slug}'`
keep each b in found whose `node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" branch` (b on stdin via a quoted heredoc)
  reports on_feature and key_slug == session.key_slug
if found is not empty:
  load references/existing-branch.md; it returns resume | fresh
  if resume: goto Branch cut
elif session.resume:
  ℹ️ no branch for {session.ticket_key} yet — cutting a fresh one
```

Base branch prompt:

```text
default_base = `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` without "origin/", else "main"
if ticket body names a target branch (e.g., release/X.Y):
  recommended_base = that target          # compute BEFORE the prompt so it is offered (aligns with the --auto branch)
else:
  recommended_base = default_base

if session.auto:                                    # happy-path gate — resolve without prompting
  session.base_branch = recommended_base
  🤖 Auto-resolved — base branch → {session.base_branch} (auto)
  goto Update base
🟡 Waiting on you — base branch
AskUserQuestion → "What branch should this target? (default: {recommended_base})"; options:
  ({recommended_base}) "{recommended_base} (recommended) — default base"
free-text "Other" reply → a custom branch name (validated below)

if user_response is blank:
  session.base_branch = recommended_base
elif re.match(r"^(?!\.)(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._/-]*$", user_response)
     AND not user_response.endswith((".", "/", ".lock"))
     AND `git check-ref-format --branch '{user_response}'` exits 0
     AND (
       `git show-ref --verify --quiet refs/heads/'{user_response}'` exits 0
       OR `git show-ref --verify --quiet refs/remotes/origin/'{user_response}'` exits 0
     ):
  session.base_branch = user_response
  if only the remote ref exists (local missing):
    git fetch origin '{user_response}'              # ensure local tracking ref is fresh
else:
  ❌ Error — "{user_response}" is not a valid branch (local or origin/*)
  re-prompt
```

Update base:

```text
git checkout '{session.base_branch}'
git pull --ff-only origin '{session.base_branch}'

if `git pull --ff-only` fails:
  ❌ Error — {session.base_branch} has diverged
  STOP — do NOT force-reset; ask user how to proceed
```

Create the branch — the script derives the slug and maps a spike to `chore/` (GitHub has no `spike/`
prefix); `session.spike` stays true for Phase 4. The ticket title reaches it on stdin through a quoted
heredoc, never as a shell argument:

```text
b = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" new --type '{"spike" if session.spike else session.work_type}' --key '{session.ticket_key}' <<'TICKET_TITLE'
{session.ticket_title}
TICKET_TITLE
if exit != 0:
  ❌ Error — cannot build a branch name: {b.error}; STOP
session.branch_type = b.type
session.slug        = b.slug
session.branch_name = b.branch               # <type>/<42 | LT-02>-<slug>, e.g. feat/42-add-title-search

if `git checkout -b '{session.branch_name}'` fails:
  ❌ Error — cannot create {session.branch_name}: {git's message}; STOP
git config 'branch.{session.branch_name}.sdlc-base' '{session.base_branch}'   # git-conventions.js base reads it

Branch cut:                                  # Phase 4's warnings gate diffs against this; set once, never moved
session.branch_cut = `git merge-base 'origin/{session.base_branch}' HEAD`
```

---

## Phase 2.5 — Issue Status + Progress Comment

Goal: the issue shows active work before the engineer hits the planning gate. `sdlc:pull-request` moves it to `status:in-review`.

```text
if session.issue_number is null:
  skip Phase 2.5                                   # story code with no issue: no label, no comment

read ${CLAUDE_PLUGIN_ROOT}/references/issue-status-labels.md and run
  set_status(session.ticket_key, session.issue_number, target = "in-progress")

read ${CLAUDE_PLUGIN_ROOT}/references/issue-progress-comment.md and run
  post_comment(session.ticket_key,
               comment_body = "### 🛠️ Work started — `{session.branch_name}`\n\n{session.ticket_title}\n",
               comment_kind = "work-started",
               auto         = session.auto,
               issue_number = session.issue_number)

neither call blocks (each warns on its own failure); continue to Phase 3
```

The section is edited in place on a re-run, so a resumed ticket never gets a second comment.

---

## Phase 3 — Plan (HARD STOP)

Goal: an approved implementation plan.

Load **`references/planning-playbook.md`** for the full procedure: scope scout, multi-area verification gate, size classification, explorer/architect dispatch, consolidation format, approval gate.

```text
hard rule:
  do NOT start implementation until the user replies with one of:
    approved | approve | go | lgtm | proceed | ship it
  under --incident, references/incident-plan-review.md answers Step 6 instead → d; then
    if session.issue_number:
      post_comment(session.ticket_key, comment_body = d.comment, comment_kind = "plan-review",
                   auto = session.auto, issue_number = session.issue_number)   # issue-progress-comment.md
    d.decision approve → Phase 4 on the adjusted plan; escalate → Step 6 as written, its question led by d.concern
```

Plan output must end with the PE-domain hint per `planning-playbook.md` Step 5 — informational only, actual PE dispatch happens in `sdlc:review`.

---

## Phase 4 — Implementation

Goal: working, tested code committed to the branch (or, for spikes, a findings doc committed).

```text
if session.spike == true:
  read references/spike.md and run it        # findings doc + commit; its escape hatch may return here
                                             # with session.spike = false to take the Standard path
```

Standard path — read `references/tdd-and-commits.md` (TDD, test quality, code comments, commit
subjects and footers, scope expansion) and `references/verification-gate.md` (pre-commit checks, warnings lifecycle, flake handling,
AC progress tracking) before the first test.

Implement sequentially in the primary session, regardless of `session.plan_size`: one ticket, one branch,
one primary agent. Parallel writers on one working tree race on files, build artifacts, and
`.git/index.lock`. Genuinely parallel work is one implement run per story, each in its own worktree;
forming an Agent Team for a single story is the engineer's call, never automatic.

---

## Pre-End — AC Coverage Gate

Runs ONCE, after the engineer says implementation is complete (not per commit): read `references/verification-gate.md` § Pre-End AC coverage gate and run it. Never reach End with a silently uncovered AC.

---

## End

Goal: cleanly restore any stashed work, compute completion stats, then print exactly ONE summary (spike OR standard, never both).

```text
if session.stashed_changes_ref exists:
  read references/stash-restore.md and run its § Restore   # dirty-tree check, then pop by revision
```

Compute completion stats inline from git:

```text
session.commit_count        = `git rev-list --count '{session.branch_cut}..HEAD'`
session.file_stats          = `git diff --shortstat '{session.branch_cut}..HEAD'`
                              # parse: "{files} files changed, +{added}/-{removed}"
session.matched_pes_display = (session.matched_pes from Phase 3
                               or empty → "(none — sdlc:pe-general-purpose)")
```

Print exactly ONE completion summary:

```text
if session.spike == true:
  print ✅ Done — spike completion summary:
    - Ticket:      {session.ticket_key} {session.ticket_title}
    - Branch:      {session.branch_name}
    - Spike doc:   docs/spikes/{session.key_slug}-{session.slug}.md
    - Commits:     {session.commit_count}

  next steps:
    - Share docs/spikes/{session.key_slug}-{session.slug}.md with the team (link it from the issue)
    - If spike concludes "build it" → create a follow-up issue (sdlc:plan create-standalone)
    - Optional: `git push -u origin '{session.branch_name}'` for branch-level review

else:
  print ✅ Done — completion summary:
    - Ticket:      {session.ticket_key} {session.ticket_title}
    - Branch:      {session.branch_name}
    - Commits:     {session.commit_count}
    - Type:        {session.work_type}
    - Files:       {session.file_stats}
    - PE-domains:  {session.matched_pes_display}

  next steps:
    - Run sdlc:review on this branch to verify
    - Run sdlc:pull-request when ready to open the PR
    - Or run sdlc:deliver to chain implement → review → PR
```

---

## Failure Handling

Each gate above states its own stop; these cases have no inline home:

| Situation | Action |
| - | - |
| Status label or progress comment fails in Phase 2.5 | Warn with the gh error; continue to Phase 3 — the plan gate, not the issue status, is the load-bearing gate. |
| User rejects plan in Phase 3 | Loop back through the planning playbook with the feedback; never loop to Phase 2. |
| `git-conventions.js` exits non-zero | ❌ Error with its `error`; never hand-build a branch name or a key. |
| Skill aborted mid-Phase-4 with uncommitted skill work | Before any stash restore, surface the work (commit-as-WIP / discard / leave-and-skip-pop). Never auto-discard or stash a second time. |

## Bundled References

| Reference | Load when |
| - | - |
| `references/existing-branch.md` | Phase 2, when this ticket already has a branch |
| `references/planning-playbook.md` | Entering Phase 3 |
| `references/incident-plan-review.md` | Phase 3, `session.incident`, after playbook Step 5 |
| `references/spike.md` | Phase 4, `session.spike == true` |
| `references/tdd-and-commits.md` | Phase 4 Standard path, before the first test |
| `references/verification-gate.md` | Phase 4 Standard path, before the first test; Pre-End |
| `references/stash-restore.md` | Phase 2, when the tree is dirty; End, when `session.stashed_changes_ref` exists |
| `${CLAUDE_PLUGIN_ROOT}/references/github-preflight.md` | Phase 1, when the ticket has an issue |
| `${CLAUDE_PLUGIN_ROOT}/references/issue-status-labels.md` | Phase 2.5 |
| `${CLAUDE_PLUGIN_ROOT}/references/issue-progress-comment.md` | Phase 2.5; Phase 3 under `--incident` |
| `${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js` | Phase 1 `key`; Phase 2 `branch`, `base`, `new`; Phase 4 `commits`; spike path `retype`, `sanitize` |
