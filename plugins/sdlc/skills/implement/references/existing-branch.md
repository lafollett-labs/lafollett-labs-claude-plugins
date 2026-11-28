# Existing Branch

Loaded by SKILL.md Phase 2 when `found` (this ticket's branches, local first, else origin's) is not empty. It
returns `resume`, with the branch checked out and `session.branch_name`, `branch_type`, `slug` and `base_branch`
set, or `fresh`, and Phase 2 goes on to the base prompt and cuts a new branch.

```text
current = `git branch --show-current`
b = current if current in found else found[0]

if len(found) > 1 and current not in found:
  if session.auto:
    🤖 Auto-resolved — HALT: {len(found)} branches match {session.ticket_key}; auto cannot pick one
    session.auto = false
  🟡 Waiting on you — AskUserQuestion → "{len(found)} branches match {session.ticket_key} — which one?"; options:
    one option per branch in found, labelled with its name
    (abort) "Abort"                                            → STOP
  b = the chosen branch

if session.start_over:
  choice = "start-over"
elif session.resume or session.auto:
  choice = "resume"
else:
  🟡 Waiting on you — AskUserQuestion → "{b} already exists for {session.ticket_key} — how to proceed?"; options:
    (resume)     "Resume on {b} (recommended)"
    (start-over) "Start over — set {b} aside and cut a fresh branch"
    (abort)      "Abort"                                       → STOP
  choice = user_response

if choice == "resume":
  if b is only on origin: git checkout --track 'origin/{b}'
  else:                   git checkout '{b}'
  if the checkout fails: ❌ Error — cannot check out {b}: {git's message}; STOP
  p    = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" branch <<'BRANCH'
{b}
BRANCH
  base = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" base --branch '{b}'  # its recorded base, else origin/HEAD, else main
  if base exits != 0: ❌ Error — cannot resolve the base of {b}: {base.error}; STOP
  session.branch_name = b; session.branch_type = p.type; session.slug = p.slug; session.base_branch = base.base
  return resume

# start over: never rename or delete a branch unattended
if session.auto:
  🛑 Hard stop — starting over sets {b} aside; re-run without --auto to choose how; STOP
if `git show-ref --verify --quiet 'refs/remotes/origin/{b}'` exits 0:
  🟡 Waiting on you — AskUserQuestion → "origin/{b} exists; a fresh branch of that name will not push over it — how to proceed?"; options:
    (resume) "Resume on {b} instead (recommended)"             → choice = "resume"; run the resume block above
    (abort)  "Abort — delete or rename origin/{b} yourself"    → STOP
ts = `date +%Y%m%d-%H%M%S`
🟡 Waiting on you — AskUserQuestion → "Start over on {session.ticket_key} — what happens to {b}?"; options:
  (rename) "Rename it to backup/{b}-{ts} (recommended)"        → git branch -m '{b}' 'backup/{b}-{ts}'
  (delete) "Delete it — its commits are lost"                  → git checkout --quiet --detach; git branch -D '{b}'
  (abort)  "Abort"                                             → STOP
return fresh
```
