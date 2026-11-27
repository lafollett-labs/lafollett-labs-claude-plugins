# Worktree Isolation

Loaded on demand by `sdlc:review` Phase 1 for a **PR Review** in worktree mode: chosen by the engineer, or always under `--auto`. An interactive run defaults to in-place and never loads this file.

Worktree mode runs the review in a dedicated `git worktree` checked out to the PR's branch, leaving the primary checkout's HEAD, index, and working tree untouched, so concurrent reviews of different branches in one repo never collide.

Inputs from the caller: `session.source_branch`, `session.remote_ref` (checkout.md § Fetch + PR metadata, which refuses an unsafe PR branch name before this runs) and `session.name` (the key_slug). All commands here are pure `git`.

## Contents

- Location convention
- Acquire — bind `session.review_root`
- Operate
- Teardown — Phase 7, after a Gate 2 round or a pushed Gate 1 doc
- Cleanup — after the PR is merged or closed

## Location convention

A hidden sibling directory **outside** the repo working tree, so the worktree never lands in the IDE workspace and is predictable for reuse and manual attachment.

```text
source_branch = session.source_branch
repo_root    = `git rev-parse --show-toplevel`
primary_root = the path on the first "worktree " line of `git worktree list --porcelain`
               # the primary checkout — even when run from a linked worktree, where show-toplevel names
               # the linked one. bin/worktree-cleanup.js derives the same base, so cleanup finds every review worktree (non-bare repos;
               #   a bare primary makes cleanup stop with an error and remove nothing).
repo_name    = basename(primary_root)
parent       = dirname(primary_root)
branch_slug  = source_branch with every char not in [A-Za-z0-9._-] replaced by "-"
wt_base      = "{parent}/.sdlc-worktrees/{repo_name}"
wt_path      = "{wt_base}/{session.name}"            # the key_slug
if session.name was not taken from a ticket key (it is the branch slug), or
   wt_path holds a worktree on another branch:
  wt_path    = "{wt_base}/{branch_slug}"
```

Worktree state needs no separate tracking file — `git worktree list --porcelain` is the authoritative record (path + checked-out branch), used directly by the reuse check.

## Acquire — bind `session.review_root`

Reuse an existing worktree if one is checked out to the branch; otherwise create one. On any failure, fall back to in-place rather than aborting silently.

```text
git fetch origin --prune                                # fresh remote state for the sync below
if session.pr.isCrossRepository:
  git fetch origin "+refs/pull/{session.pr.number}/head:refs/remotes/{session.remote_ref}"
else:
  git fetch origin '{session.source_branch}'
if a fetch exited non-zero:
  ⚠️ Warning — could not fetch {session.remote_ref}; proceeding against existing local refs.

# Reuse detection — git worktree list is the source of truth; no separate state file.
# --porcelain emits one record per worktree (lines "worktree <path>" / "HEAD <sha>" /
# "branch refs/heads/<name>"), records separated by blank lines.
records  = split `git worktree list --porcelain` on blank lines
existing = first record having a line "branch refs/heads/{source_branch}", else null
if existing != null:
  wt_path = the "worktree <path>" line of that record
else:
  # Create a NEW worktree — never touches the primary checkout's HEAD/index/working tree.
  `mkdir -p '{wt_base}'`
  if `git show-ref --verify --quiet refs/heads/{source_branch}` exits 0:   # local branch exists
    create = `git worktree add '{wt_path}' '{source_branch}'`
  else:                                                                    # only on the remote
    create = `git worktree add --track -b '{source_branch}' '{wt_path}' '{session.remote_ref}'`

  if create exited non-zero:                              # e.g. branch already checked out elsewhere
    🛑 Explain the exact git error (commonly: "'{source_branch}' is already checked out at '{other_path}'").
    AskUserQuestion → "Worktree creation failed: {git error}. How to proceed?"; options:
      (a) "in-place (recommended) — run the review on the primary checkout"
      (b) "abort — stop the review"
    match user_response (empty → a):
      case (a): session.review_root = repo_root ; return "in-place (worktree unavailable)"
      case (b): exit the review

# Sync to current remote state — idempotent; safe for both reuse and fresh-from-local-branch.
sync = `git -C '{wt_path}' merge --ff-only '{session.remote_ref}'`
if sync exited non-zero:                                 # diverged — e.g. unpushed review-doc commit + author pushed
  ⚠️ Warning — worktree at {wt_path} has local commits diverging from {session.remote_ref};
                reviewing against its current state. Do NOT reset; reconcile manually if that is wrong.

session.review_root = wt_path
return "worktree" + (" (reused)" if existing != null else " (new)")
```

## Operate

```text
session.review_root is the review's working tree — but the skill process NEVER chdir's into it;
every skill-side git op is rooted explicitly with `git -C "{session.review_root}"`:
  - the branch checkout (this Acquire step replaces checkout.md § In-place checkout)
  - the dispatch prompt's WORKTREE: field  → set to session.review_root (PEs already `cd <worktree>`)
  - Gate 1 output path   → "{session.review_root}/docs/code-reviews/{session.name}-code-review.md" (a Gate 2 doc stays outside the worktree; review-store.md)
  - Gate 1 commit + push → `git -C '{session.review_root}' ...`
Ref-to-ref ops (origin/x...origin/y) ARE worktree-agnostic (all worktrees share the object DB + refs).
HEAD-/index-relative ops are NOT: bare `HEAD` resolves against the process cwd's worktree, so any diff /
rev-parse / merge-base against HEAD MUST be `git -C "{session.review_root}"`-rooted (diff_cmd + banner SHAs do).
```

## Teardown — Phase 7, after a Gate 2 round or a pushed Gate 1 doc

Fired after a Gate 2 round (it writes nothing into the worktree) or once publish.md Step 3 confirms the Gate 1 doc is pushed. Removal is never automatic; the prompt defaults to KEEP.

```text
if session.review_root == repo_root:                     # in-place run — nothing to tear down
  return

if session.auto:
  🤖 Auto-resolved — keeping worktree {session.review_root} for the next round
  user_response = keep
else:
  AskUserQuestion → "Round {session.round_n} on {source_branch} is done in worktree {session.review_root}. The PR may still be open — a later round can reuse this worktree. Remove it now?"; options:
    (keep) "keep (recommended) — leave the worktree for the next round"
    (remove) "remove — delete the worktree now"

match user_response (empty → keep):
  case keep:
    leave the worktree; print "reuse on next round, or clean up later: `git worktree list`".
  case remove:
    rm = `git worktree remove '{session.review_root}'`   # refuses if dirty/locked — intended safety
    if rm exited non-zero:
      ⚠️ Warning — worktree is dirty or locked; NOT force-removing. Commit/clean it, then
                    `git worktree remove '{session.review_root}'` (or add --force) manually.
```

## Cleanup — after the PR is merged or closed

`/sdlc:review cleanup` classifies each worktree under this file's `wt_base` with `bin/worktree-cleanup.js` (from the PR's state and final head on GitHub) and removes the safe ones only after the engineer confirms — never `--force`; the local branch is deleted (`-D`) only for a worktree classified safe. A review that starts with safe-to-remove worktrees prints a one-line notice. Mechanics: `worktree-cleanup.md`.
