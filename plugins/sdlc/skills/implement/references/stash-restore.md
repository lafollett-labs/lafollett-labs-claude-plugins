# Stash Restore

Loaded by End when `session.stashed_changes_ref` exists (the engineer chose stash at the Phase 2 dirty-tree
gate). Runs before the completion summary.

Pre-stash-pop dirty-tree check:

```text
if session.stashed_changes_ref exists:
  if `git status --porcelain` produces output (working tree is dirty with
     skill's partial / uncommitted work):
    🟡 Waiting on you — uncommitted skill changes detected before stash restore
    AskUserQuestion → "Uncommitted skill changes before stash restore — how to proceed?"; options:
      (a) "Commit the uncommitted changes — engineer reviews + commits"
      (b) "Discard them — git checkout -- . + git clean -fd"
      (c) "Leave them; skip the stash pop — engineer reconciles later; stash stays as session.stashed_changes_ref"
    do NOT pop on top of dirty state — guaranteed conflict + entanglement
```

Resolve stash message → revision (NEVER pass the message string to `git stash pop`):

```text
if session.stashed_changes_ref exists AND dirty check above resolved cleanly:
  stash_rev = $(git stash list --format='%gd %s' \
                | grep -F " {session.stashed_changes_ref}" \
                | head -1 | awk '{print $1}')

  if stash_rev is empty:
    ❌ Error — stash '{session.stashed_changes_ref}' not found in `git stash list`
    list the current stashes; ask user how to proceed
    do NOT pop topmost (would silently restore wrong content)

  git stash pop '{stash_rev}'

  if pop fails (conflicts):
    ❌ Error — stash '{session.stashed_changes_ref}' could not be restored cleanly
    tell user:
      stash is still in `git stash list` as '{session.stashed_changes_ref}' (ref {stash_rev})
      to recover, pick one:
        (a) `git stash branch <new-branch> '{stash_rev}'` — apply stash to a fresh
            branch and resolve conflicts there
        (b) edit conflicted files, `git add`, then `git stash drop '{stash_rev}'`
        (c) abandon the stash: `git stash drop '{stash_rev}'` (user work is lost)
```
