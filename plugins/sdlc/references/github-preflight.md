# GitHub Preflight

Binds the GitHub state every sdlc skill reads. Run it once per session, before the first `gh` call; later steps read these bindings instead of probing again.

```text
session.gh_ok            = (`gh auth status` exits 0)          # verifies authentication
session.repo             = null                                 # "octo-org/octo-repo"
session.status_labels_ok = false
if not session.gh_ok:
  ⚠️ Warning — gh is not authenticated (run `gh auth login`); GitHub steps are skipped this session
  return

r = `gh repo view --json nameWithOwner --jq .nameWithOwner`
if r exits non-zero or prints nothing:
  ⚠️ Warning — this checkout has no GitHub remote gh can resolve; GitHub steps are skipped this session
  return
session.repo = r

existing = `gh label list --limit 1000 --json name --jq '.[].name'`
if that exits non-zero:
  ⚠️ Warning — cannot list labels; status labels are skipped this session
  return
session.status_labels_ok = true
for (label, color) in STATUS_LABELS:
  if label in existing: continue
  `gh label create '{label}' --color '{color}' --description 'sdlc issue status' --force`
  if it exits non-zero:
    ⚠️ Warning — cannot create {label} ({first stderr line}); status labels are skipped this session
    session.status_labels_ok = false
    break
```

| `STATUS_LABELS` label | color |
| - | - |
| `status:todo` | `ededed` |
| `status:in-progress` | `fbca04` |
| `status:in-review` | `1d76db` |
| `status:done` | `0e8a16` |
