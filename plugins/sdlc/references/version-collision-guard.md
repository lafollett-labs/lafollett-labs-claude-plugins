# Version-Collision Guard

Loaded on demand by `sdlc:pull-request` before the push, when `.claude-plugin/marketplace.json` exists. It applies only to a marketplace whose release workflow stamps versions after merge (detected below): there a branch never edits an existing version, and a new plugin authors its own debut version. It detects a hand edit and halts; it never edits or commits version files. A marketplace that bumps versions by hand is left alone.

Inputs from the caller: `session.base_branch`.

```text
MARKETPLACE = ".claude-plugin/marketplace.json"
stamped = directory "changelog.d" exists at the repo root
          and a file matching ".github/workflows/release*.yml" or ".github/workflows/release*.yaml" exists
if not stamped: return                         # versions are bumped by hand here; nothing to guard

`git fetch origin '{session.base_branch}'`
if it exits non-zero:
  ⚠️ Warning — could not fetch origin/{session.base_branch}; check that no existing version changed before pushing
  return
branch_cut = `git merge-base 'origin/{session.base_branch}' HEAD`
changed    = `git diff --name-only --no-renames '{branch_cut}' HEAD`

json_at(ref, path):           # the parsed file at ref, or null when it is absent there
  raw = `git show '{ref}:{path}'`
  return null if it exits non-zero else json(raw)
market_version(m):            # metadata.version, else the top-level version
  return m.metadata.version if m.metadata has "version" else m.version
plugin_json(p):               # the plugin.json path of a marketplace entry, or null for a remote source
  if p.source is not a string starting with "./": return null
  dir = p.source without the leading "./" and any trailing "/"
  return (dir + "/" if dir else "") + ".claude-plugin/plugin.json"

edits = []
compare(where, old, new):     # a debut (old null) keeps its authored version; a removal (new null) has none
  if old is not null and new is not null and old != new: edits += [{where, old, new}]

base_m = json_at(branch_cut, MARKETPLACE) or {plugins: []}
head_m = json_at("HEAD", MARKETPLACE) or {plugins: []}
compare(MARKETPLACE, market_version(base_m), market_version(head_m))
for p in head_m.plugins:
  q = the entry in base_m.plugins with q.name == p.name, else null
  if q: compare("{MARKETPLACE} plugins[{p.name}].version", q.version, p.version)
  path = plugin_json(p)
  if path and path in changed:
    compare(path, (json_at(branch_cut, path) or {}).version, (json_at("HEAD", path) or {}).version)

if edits is empty: return                     # no hand edit → the release workflow owns the bump

🛑 Hard stop — this branch hand-edited a version the release workflow stamps after merge
  Restore each version below to its merge-base value, commit, then re-run /sdlc:pull-request.
  Never bump it further: the release workflow bumps it again on merge.
  for e in edits:
    "- {e.where}: {e.old} → {e.new}; restore {e.old}"
  STOP
```
