# Worktree Cleanup

Loaded on demand by `sdlc:review` in two places, and never otherwise:

- the **`cleanup` entry point** (`/sdlc:review cleanup`) — runs **Cleanup** below, then exits; no review runs.
- the **stale-worktree notice** at review start — runs **Stale notice** below, only when
  `worktree-cleanup.js list` already returned at least one review worktree.

Review worktrees are the ones `worktree-isolation.md` creates at `{parent}/.sdlc-worktrees/{repo}/{key_slug}`
(see its § Location convention). Nothing returns to one after its PR is merged or closed; this file finds
those and removes them with the engineer's confirmation.

Safety contract:

- Only direct children of `.sdlc-worktrees/{repo}/` for THIS repo are ever considered — `list` enforces it,
  and `classify` refuses any other path.
- Removal is never automatic, never `--force`. A local branch is deleted (`-D`) only after its worktree was
  classified **safe** and removed.
- The safe/keep decision is `bin/worktree-cleanup.js` — never model judgment. Its exit 2 means **keep**.

Inputs from the caller: `session.auto`.

```text
CTL = node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/worktree-cleanup.js"
```

## Contents

- Gather — classify every review worktree
- Cleanup — the `cleanup` entry point
- Remove
- Stale notice — review start

## Gather — classify every review worktree

```text
wt = `{CTL} list`        # → {repo_root, wt_base, wt_base_shell_safe, worktrees: [{path, branch, head, shell_safe, current, ...}]}
if wt exited non-zero: ⚠️ Warning — {wt.reason}; stop
if wt.worktrees is empty: print "No review worktrees under {wt.wt_base}."; stop

for w in wt.worktrees:
  if not w.shell_safe:                                   # a ' or control character would break the quoting below
    w.result = {verdict: keep, class: error, reason: "path not shell-safe — inspect manually"}; continue
  if w.current:                                          # removing the session's own directory breaks every later git call
    w.result = {verdict: keep, class: error, reason: "current worktree — run cleanup from another checkout"}; continue
  # 1. local checks first — locked, missing, dirty or untracked are kept without any API call
  r = `{CTL} classify --worktree '{w.path}'`
  if r.verdict != "pending": w.result = r; continue
  if w.branch is null:
    w.result = `{CTL} classify --worktree '{w.path}' --pr-state none`; continue
  if w.branch does not match ^[A-Za-z0-9._/-]+$ or starts with "-":   # git allows quotes in ref names — never shell-interpolate one
    w.result = {verdict: keep, class: error, reason: "branch name not shell-safe — inspect manually"}; continue

  # 2. PR facts from GitHub — never remote-tracking refs, which vanish when the head branch is deleted.
  #    A fork PR's worktree branch is pr-<N> (checkout.md); look it up by number instead of by head.
  if w.branch matches ^pr-([0-9]+)$:
    prs = [`gh pr view {N} --json number,state,headRefOid`]
  else:
    prs = `gh pr list --head '{w.branch}' --state all --json number,state,headRefOid`   # → [{number, state, headRefOid}]
  on failure: w.result = {verdict: keep, class: error, reason: "PR lookup failed: {error}"}; continue
  if prs is empty: w.result = `{CTL} classify --worktree '{w.path}' --pr-state none`; continue
  pr = the first OPEN PR in prs, else prs[0]           # an open PR always wins — it may need another round

  # 3. for a finished PR: its commits, and its final head fetched by PR ref (works after branch deletion)
  commits = ""
  if pr.state is MERGED or CLOSED:
    commits = `gh pr view {pr.number} --json commits --jq '[.commits[].oid] | join(",")'`   # empty on failure — the content check below still applies
    git fetch origin "refs/pull/{pr.number}/head"      # a failure is fine — classify reports head-unavailable unless HEAD is in commits

  w.result = `{CTL} classify --worktree '{w.path}' --pr-state '{pr.state}' --pr-ref '#{pr.number}' --pr-head '{pr.headRefOid}' --pr-commits '{commits}'`
```

`classify` takes gh's `OPEN` / `MERGED` / `CLOSED` as-is. When HEAD is not among the PR's commits,
`classify` falls back to a content check against the fetched final head, then to an exact per-commit
patch comparison, which together cover squash and rebase merges.

Classes (`w.result.class`):

| Class | Verdict | Meaning |
| - | - | - |
| `locked` / `prunable` / `dirty` | keep | locked, directory missing, or uncommitted / untracked changes or edits hidden by skip-worktree / assume-unchanged, or an operation in progress |
| `no-pr` | keep | no PR for the branch (or detached HEAD) |
| `pr-open` | keep | the PR is still open |
| `head-unavailable` | keep | the PR's final head could not be fetched |
| `not-landed` | keep | commits not in the PR's final head — listed in `unlanded` |
| `safe` | safe | PR merged/closed and HEAD is one of its commits, or the content landed (squash/rebase), or every commit's exact (whitespace-sensitive) patch is in the final head's history with no merge commit in between; the content check is skipped when merge-tree could use anything but the built-in text merge — a `merge=` attribute naming a driver on a path the worktree changed or the final head added, or `merge.default` / `merge.renormalize` in git config — so such a worktree is decided by the patch comparison alone; the reason discloses any git-ignored paths removal will delete |
| `error` | keep | classifier error (exit 2), PR lookup failure, the worktree cleanup is running in, or a path / branch name that is not shell-safe — the reason says which |

## Cleanup — the `cleanup` entry point

```text
run Gather
print one line per worktree:  "{basename(path)} — {class}: {reason}"
  for not-landed, under it:    "    {sha[:8]} {subject}"   for each entry in unlanded
safe = [w for w in worktrees if w.result.verdict == "safe"]
if safe is empty: print "Nothing safe to remove."; stop
if session.auto:  print "--auto: report only — re-run interactively to remove."; stop   # never removes unattended

# Confirm — the engineer sees the safe set and ticks what to remove. Fails closed: anything not
# ticked — no reply, an "Other" free-text reply, or a label that matches no worktree — is kept.
if len(safe) == 1:
  AskUserQuestion → "Remove review worktree {safe[0].path} (branch {safe[0].branch})?"; options:
    (keep) "keep (recommended) — leave it in place"
    (remove) "remove — delete the worktree and its local branch"
  match user_response (empty → keep):
    case remove: selected = safe
    case keep:   selected = []
else:
  # multiSelect takes 2–4 options per question and 4 questions per call: split the safe set into
  # ceil(len(safe) / 4) batches of near-equal size (every batch 2–4), in the order printed above.
  batches = split safe into ceil(len(safe) / 4) contiguous groups whose sizes differ by at most 1
  selected = []
  for each run of up to 4 consecutive batches:
    AskUserQuestion → one multiSelect question per batch:
      "Select the review worktrees to remove (batch {k} of {len(batches)}; unticked are kept)."; options:
        one per worktree in the batch: label = basename(path), description = "{branch} — {reason}"
    for each question: selected += [w for w in its batch if basename(w.path) is a ticked label]
if selected is empty: print "Kept all review worktrees."; stop

run Remove on selected
```

## Remove

```text
for w in selected:
  again = re-run the final classify for w with the same PR facts      # state may have changed since Gather
  if again.verdict != "safe": report "{w.path} — kept: {again.reason}"; continue
  # every git call is rooted at the primary checkout (-C) — never the caller's cwd
  rm = `git -C '{wt.repo_root}' worktree remove '{w.path}'`           # never --force
  if rm exited non-zero:
    ⚠️ Warning — git refused to remove {w.path}: {stderr}. Kept; branch untouched.
    continue
  if w.branch is not null and `git -C '{wt.repo_root}' rev-parse --verify --quiet 'refs/heads/{w.branch}'` == again.head:
    `git -C '{wt.repo_root}' branch -D '{w.branch}'`                   # -d refuses after a squash merge
    record "deleted branch {w.branch} (was {again.head[:8]}) — restore: git branch '{w.branch}' {again.head}"
  elif w.branch is not null:
    record "kept branch {w.branch} — its tip moved since classification"
  record "removed {w.path}"

if wt.wt_base_shell_safe:
  `rmdir '{wt_base}'` then `rmdir '{dirname(wt_base)}'`               # only if empty — never rm -r; ignore failures
print the record: one line per worktree — removed, kept (with reason), or refused (with git's error)
```

## Stale notice — review start

One line or nothing. Never a question, never a removal, never blocks the review.

```text
run Gather, skipping the commits call (the content check covers it)
n = count of worktrees with verdict "safe"
if n >= 1: print "ℹ️ {n} review worktree(s) look safe to remove — run /sdlc:review cleanup"
on any error: print nothing and continue the review
```
