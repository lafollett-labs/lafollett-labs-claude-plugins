# Settings

Every sdlc skill reads one merged settings object, bound once per session by `load_settings()`. A skill flag that names a setting overrides it for that run.

| Layer (later wins) | Path | Committed |
| - | - | - |
| defaults | below | — |
| user | `~/.claude/sdlc.json` | no |
| repo | `{repo_root}/.claude/sdlc.json` (`repo_root` = `git rev-parse --show-toplevel`) | yes |

## Defaults

```json
{
  "pullRequest": { "reviewers": [], "draft": false },
  "slack": { "enabled": false, "channel": "" },
  "review": { "searchRoots": [], "modelByTier": true, "maxParallelPes": 2 }
}
```

| Key | Type | Meaning |
| - | - | - |
| `pullRequest.reviewers` | string[] | GitHub logins or `org/team` slugs requested on a new PR; empty → CODEOWNERS, then ask |
| `pullRequest.draft` | bool | open new PRs as drafts |
| `slack.enabled` | bool | false → every Slack step is a no-op |
| `slack.channel` | string | the channel name (`#eng`) every Slack post goes to |
| `review.searchRoots` | string[] | sibling repo paths, relative to `repo_root`, that PEs may read below DEEP |
| `review.modelByTier` | bool | run each PE on the model its review tier warrants |
| `review.maxParallelPes` | positive integer | suite-running PEs dispatched at once (default 2); pe-governance and domain PEs are never capped |

## load_settings

```text
load_settings():
  s = copy(DEFAULTS)
  for path in ["~/.claude/sdlc.json", "{repo_root}/.claude/sdlc.json"]:
    if Read(path) fails: continue                     # a missing file adds nothing
    if its content is not a JSON object:
      ⚠️ Warning — {path} is not a JSON object; ignoring it
      continue
    merge(s, parsed, path, "")
  session.settings = s

merge(base, over, path, prefix):                      # the later layer wins key by key
  for key, value in over:
    name = prefix + key
    if key not in base: continue                      # unknown keys are ignored
    if base[key] is an object:
      if value is an object: merge(base[key], value, path, name + ".")
      else: ⚠️ Warning — {path}: {name} must be an object; ignoring it
    elif type(value) == type(base[key]) and (value is not an array or every item is a string):
      base[key] = value                               # an array replaces the lower layer's array whole
    else:
      ⚠️ Warning — {path}: {name} must be {type(base[key])}; keeping {base[key]}
```
