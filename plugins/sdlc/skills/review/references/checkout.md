# PR Checkout

Loaded by SKILL.md for PR Review only. § Fetch + PR metadata runs first; SKILL.md then asks in-place vs worktree. § In-place checkout runs only for in-place mode — worktree mode checks out via worktree-isolation.md instead.

## Fetch + PR metadata

PR reviews MUST run against fresh remote state. Never diff against stale local refs.

```bash
git fetch origin --prune
```

```text
if fetch fails (network / auth):
  🛑 stop — stale diff produces wrong-scope review
  report error; ask user to resolve
```

```bash
gh pr view <pr_number> --json number,title,url,author,headRefName,baseRefName,headRefOid,headRepositoryOwner,headRepository,isCrossRepository
```

```text
session.pr = parsed JSON      # .number .title .url .author.login .headRefName .baseRefName .headRefOid .isCrossRepository
if exit != 0: ❌ Error — PR #{pr_number} not found in {session.repo}; STOP
for ref in [session.pr.headRefName, session.pr.baseRefName]:     # PR-author-controlled; checked before any checkout, worktree, or push
  if ref does not match ^[A-Za-z0-9._/-]+$ or ref starts with "-":
    ❌ Error — PR #{session.pr.number} branch name "{ref}" is unsafe to pass to a shell; STOP
session.source_branch = session.pr.headRefName
session.remote_ref    = "origin/{session.pr.headRefName}"
if session.pr.isCrossRepository:          # a fork's branch is not on origin, and its name may match one that is
  session.source_branch = "pr-{session.pr.number}"
  session.remote_ref    = "origin/pr/{session.pr.number}"
  `git fetch origin "+refs/pull/{session.pr.number}/head:refs/remotes/{session.remote_ref}"`
```

## In-place checkout

```text
session.orig_ref = `git symbolic-ref --quiet --short HEAD`
if exit != 0:
  🛑 stop — detached HEAD; tell user to check out a branch first
if session.orig_ref does not match ^[A-Za-z0-9._/-]+$ or starts with "-":
  🛑 stop — the current branch name is unsafe to pass to a shell; check out another branch first

if `git status --porcelain` is non-empty:
  if session.auto:                     # reached under --auto when Acquire returns the primary checkout (PR branch already checked out there, or a creation fallback)
    🤖 Auto-resolved — stashing uncommitted changes; Phase 7 Step 6 restores them
    user_response = yes
  else:
    AskUserQuestion → "Stash uncommitted changes as sdlc-review-autostash-<ts> and restore after review?"; options:
      (yes) "Stash and restore after review"
      (no) "Stop — I'll commit or stash manually"
  match user_response:
    case yes:
      ts                    = unix_timestamp()
      session.stash_ref     = "sdlc-review-autostash-" + ts
      git stash push -u -m "{session.stash_ref}"
    case no:
      🛑 stop — ask user to commit or stash manually

gh pr checkout {session.pr.number} --branch "{session.source_branch}"     # fast-forwards an existing local branch
if exit != 0:
  restore_stash()                      # SKILL.md § Shared routines
  🛑 stop — report the gh error (commonly: local branch diverged from the PR head); ask how to proceed
assert `git rev-parse --abbrev-ref HEAD` == session.source_branch
```

scope.js (`--mode pr --range origin/{target_branch}...HEAD`) then binds the diff command over `session.review_root`, so bare HEAD is the reviewed tip in both modes, including local-but-unpushed commits.
