# Version-Collision Guard

Loaded on demand by `sdlc:pull-request` before the push, ONLY when `.claude-plugin/marketplace.json` exists. In a plugin marketplace the release workflow stamps every version after merge: a branch never edits an existing `version` (a plugin's `plugin.json`, or the marketplace's `metadata.version`, else its top-level `version`), and a new plugin authors its own debut version. This guard detects a hand edit and halts; it never edits or commits version files.

Inputs from the caller: `session.base_branch`.

```text
`git fetch origin '{session.base_branch}'`
if it exits non-zero:
  ⚠️ Warning — could not fetch origin/{session.base_branch}; check that no existing version changed before pushing
  return
branch_cut = `git merge-base 'origin/{session.base_branch}' HEAD`
changed    = `git diff --name-only --no-renames '{branch_cut}' HEAD`

read_version(ref, path):      # the version string at ref, or null when the file or its version is absent there
  raw = `git show '{ref}:{path}'`
  if it exits non-zero: return null
  j = json(raw)
  if path == ".claude-plugin/marketplace.json" and j.plugins is a list and j.metadata has "version":
    return j.metadata.version
  return j.version

edits = []
for path in changed:
  if path != ".claude-plugin/marketplace.json" and path does not match glob "plugins/*/.claude-plugin/plugin.json":
    continue
  old = read_version(branch_cut, path)
  new = read_version("HEAD", path)
  if old is null or new is null: continue     # a debut (new plugin) keeps its authored version; a removal has none
  if new != old: edits += [{path, old, new}]

if edits is empty: return                     # no hand edit → the release workflow owns the bump

🛑 Hard stop — this branch hand-edited a version the release workflow stamps after merge
  Restore each version below to its merge-base value, commit, then re-run /sdlc:pull-request.
  Never bump it further: the release workflow bumps it again on merge.
  for e in edits:
    "- {e.path}: {e.old} → {e.new}; restore {e.old}"
  STOP
```
