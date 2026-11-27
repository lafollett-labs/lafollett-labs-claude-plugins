# create and create-standalone

Loaded by Command Dispatch for `create` and `create-standalone`, with `references/publish.md`. Uses `run_gi` and § validate from SKILL.md.

## quality_gate — before the first publish

```text
quality_gate(files):
  findings = []
  for f in files:
    run § validate on f, collecting its ✗ errors and quality findings instead of stopping
    findings += each, tagged with f
  if findings is empty: return
  list them
  if args.yes: return
  AskUserQuestion → "{len(findings)} problem(s) found before publishing (listed above) — how to proceed?"
    (stop)    "Stop to fix the file(s), then re-run (recommended)" -> STOP; nothing published
    (publish) "Publish anyway"                                      -> return
```

## create — Epic + Children

Creates the epic from `00-Epic-*.md` and every `NN-Story|Task|Bug-*.md` child, links each child under the epic as a sub-issue, then merges `- [ ] #N — <title>` lines into the epic's `## Story Breakdown`. Idempotent: state is written after every issue, so a re-run skips what is tracked, links any tracked child that lost its link, and resumes the rest.

```text
create(args):
  if not args.docs_path: ❌ Error — create requires --docs-path <dir>; STOP
  state   = read {args.docs_path}/.github-state.json (empty when absent)
  pending = the epic file (when state.epic is null) + each child file not in state.issues
  quality_gate(pending)
  out = run_gi("create", "--docs-path " + shq(args.docs_path) + [" --yes" if args.yes])

  if out has "Could not update the epic's Story Breakdown":
    run_gi("create", same flags) once; if that line prints again: STOP and report the gh error
  if out has "✓ Updated epic #{E} Story Breakdown":
    reconcile_breakdown(epic file)
```

```text
reconcile_breakdown(epic_file):                  # create appended "- [ ] #N — <title>" lines at the end of the section
  for each appended line:
    if the section has "### Phase …" subheadings: move the line under its phase
    delete any hand-written line for the same child (one without #N)
  if the file changed: run_gi("update", "--docs-path " + shq(args.docs_path) + " --file " + shq(basename(epic_file)))
```

| flag | required | meaning |
| - | - | - |
| `--docs-path <dir>` | yes | the epic folder |
| `--yes` | no | publish past `prepare` problems and quality findings without asking |

## create-standalone — One Tracked Issue, No Parent

Creates one Story, Task or Bug from `--file`, tracked in `.github-state.json` under the file's path relative to the state folder; `epic` stays null. Add it under an epic later with `reparent`.

```text
create_standalone(args):
  if not args.file: ❌ Error — create-standalone requires --file <md>; STOP
  quality_gate([args.file])
  run_gi("create-standalone", "--file " + shq(args.file) + [" --type " + shq(args.type)] + [" --docs-path " + shq(args.docs_path)] + [" --yes" if args.yes])
```

| flag | required | meaning |
| - | - | - |
| `--file <md>` | yes | the issue file |
| `--type <Story\|Task\|Bug>` | no | default: the `NN-<Type>-` file name, else Story |
| `--docs-path <dir>` | no | the state folder; default: the file's folder |
| `--yes` | no | as for `create` |

An already tracked file is a no-op warning: use `update`.
