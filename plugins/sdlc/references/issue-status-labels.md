# Issue Status Labels

Loaded on demand to move an issue to a lifecycle stage. An issue carries exactly one `status:*` label; github-preflight.md creates the labels. Never blocks the caller.

| `target` | Label | Set when |
| - | - | - |
| `todo` | `status:todo` | the issue is planned |
| `in-progress` | `status:in-progress` | implement starts |
| `in-review` | `status:in-review` | the PR is opened |
| `done` | `status:done` | the PR is merged |

Inputs from the caller: `ticket_key`, `issue_number` (git-conventions.js `issue_number`, or the issue a story code's file links; null when there is none), `target`, and `session.gh_ok`, `session.status_labels_ok` from github-preflight.md.

```text
set_status(ticket_key, issue_number, target) → {from, to, changed}:
  unchanged = {from: null, to: null, changed: false}
  if issue_number is null:
    log "no GitHub issue for {ticket_key}; status unchanged"; return unchanged
  if not (session.gh_ok and session.status_labels_ok):
    ⚠️ Warning — status labels unavailable; set status:{target} on #{issue_number} by hand
    print_manual_command(); return unchanged

  cur = `gh issue view {issue_number} --json state,labels`
  if that exits non-zero:
    ⚠️ Warning — cannot read #{issue_number}; status unchanged
    print_manual_command(); return unchanged
  present = [l.name for l in cur.labels if l.name starts with "status:"]
  from    = the latest stage among present in table order, else null

  if target == "todo" and present is non-empty:
    return unchanged                                   # planning never resets a started issue
  if from == "done" or (cur.state == "CLOSED" and target != "done"):
    log "#{issue_number} is already done; status unchanged"; return unchanged
  if present == ["status:{target}"]:
    log "#{issue_number} is already status:{target}"; return unchanged

  stale = [l for l in present if l != "status:{target}"]
  `gh issue edit {issue_number} --add-label 'status:{target}'` + (` --remove-label '{join(stale, ",")}'` if stale)
  if it exits non-zero:
    ⚠️ Warning — could not set status:{target} on #{issue_number}
    print stderr; print_manual_command(); return unchanged
  return {from, to: target, changed: true}             # changed = the move landed this run

print_manual_command():
  print: gh issue edit {issue_number} --add-label 'status:{target}' --remove-label '<any other status:* label>'
```
