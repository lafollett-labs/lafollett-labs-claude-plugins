# status and reparent

Loaded by Command Dispatch for `status` and `reparent`. Uses `run_gi` from SKILL.md.

## status — Live Status of an Epic Folder

Read-only. Prints one line per tracked issue (the epic first), local files not yet created, tracked files missing locally, and a done/total rollup.

```text
status(args):
  if not args.docs_path: ❌ Error — status requires --docs-path <dir>; STOP
  (out, code) = run_gi("status", "--docs-path " + shq(args.docs_path))
  if code == 1: STOP                                                     # an issue is unreadable
  if out has "not linked to #{E}": offer `create --docs-path {args.docs_path}` to link them
```

| Stage | Glyph | When |
| - | - | - |
| done | ✅ | the issue is closed and not dropped, or labelled `status:done` |
| dropped | ⛔ | closed as not planned or as a duplicate (`stateReason` `NOT_PLANNED`, `DUPLICATE`); left out of done/total |
| in-review | 🔍 | `status:in-review` |
| in-progress | 🟡 | `status:in-progress` |
| todo | 🔵 | `status:todo` |
| open | ⚪ | open with no `status:*` label |
| not found | ❓ | the issue cannot be read; the run ends 🛑, exit 1 |

A child that is not a sub-issue of the folder's epic is marked `⚠️ not a sub-issue of #E`; sub-issues in other repositories never count as linked.

## reparent — Move or Clear the Parent

Moves an issue under another epic, or clears its parent when `--parent` is omitted. GitHub holds the hierarchy; local state does not change.

```text
reparent(args):
  if not args.key: ❌ Error — reparent requires --key <N>; STOP
  run_gi("reparent", "--key " + shq(args.key) + [" --parent " + shq(args.parent)])
```

gh-issues.js checks before any write that the issue exists and that the new parent carries the `epic` label. It then looks up the current parent, removes the issue from it, and adds it under the new one. A parent in another repository is never the same as `--parent`; it is removed through its own repository:

| Step | Call |
| - | - |
| id | `gh api repos/{o}/{r}/issues/<N>` → `.id` |
| current parent | `gh api repos/{o}/{r}/issues/<N>/parent` (404 = none) |
| remove | `gh api -X DELETE repos/<old parent's owner/repo>/issues/<old>/sub_issue -F sub_issue_id=<id>` |
| add | `gh api -X POST repos/{o}/{r}/issues/<new>/sub_issues -F sub_issue_id=<id>` |

An add that fails after the remove leaves the issue standalone and says so; re-running `reparent` finishes the move.

| flag | required | meaning |
| - | - | - |
| `--key <N>` | yes | the issue to move |
| `--parent <N>` | no | the new epic. Omitted → the parent is cleared |
