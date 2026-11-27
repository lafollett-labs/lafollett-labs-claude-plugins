# import

Loaded by Command Dispatch for `import`. Uses `run_gi` from SKILL.md.

Pulls an epic and its sub-issues from GitHub into a fresh epic folder — the inverse of `create`. Writes `00-Epic-<Title>.md`, one `NN-<Type>-<Title>.md` per child in sub-issue order (type from its `story|task|bug` label, else Story), a fresh `.github-state.json` and the README rollup, so `update` and `status` work on the folder at once.

```text
import(args):
  if not args.epic: ❌ Error — import requires --epic <N>; STOP
  out = run_gi("import", "--epic " + shq(args.epic) + [" --docs-path " + shq(args.docs_path)] + [" --force"])
  if out has "linked by a \"Part of Epic #N\" line":       # an epic issue-manager created
    offer: run `create --docs-path <folder>` to link those children as sub-issues
  if out has "was not part of this import":
    list those files; ask the user whether to delete each one — create would publish it as a new issue
```

| Check (gh-issues.js) | Fails when |
| - | - |
| epic | the issue has no `epic` label and no sub-issues |
| size | more than 99 children (the `NN-` ordinal) |
| target | the folder exists and is not empty, without `--force` |

| flag | required | meaning |
| - | - | - |
| `--epic <N>` | yes | the epic to pull, with all its sub-issues |
| `--docs-path <dir>` | no | target folder; default `docs/epics/<NNN>-<slug>` from the epic title |
| `--force` | no | write into a non-empty folder; files the import did not write are flagged |

An epic with no sub-issues falls back to issues whose body starts `Part of Epic #N` (the issue-manager link); that line is dropped from the imported files.
