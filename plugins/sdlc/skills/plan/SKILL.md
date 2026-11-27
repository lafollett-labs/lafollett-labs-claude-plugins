---
name: plan
description: >-
  Authors and maintains GitHub issues — Epics, Stories, Tasks, Bugs — from local Markdown under docs/epics/, an epic's children linked to it as GitHub sub-issues. Scaffolds an epic folder (from scratch or from an ADR), then creates, updates, imports, status-checks and reparents issues, round-tripping a .github-state.json, and checks issue quality: intent over implementation (issues say WHAT and WHY, never HOW) and BDD scenarios. Replaces issue-manager. Use when the user says "create epic", "create story", "import epic", "update issue from markdown", "are these issues too implementation-heavy", "turn this ADR into an epic", or invokes "/sdlc:plan".
argument-hint: "[command] [--docs-path PATH] [--file PATH] [--key N] [--epic N] [--parent N] [--issue N] [--type TYPE] [--name NAME] [--from PATH] [--force] [--yes]"
---

# Plan (sdlc:plan)

Initial input: `$ARGUMENTS`

## Operating Principles

```text
track every command's phases with TaskCreate / TaskUpdate: in_progress on start, completed on finish
never discard / stash / commit / overwrite uncommitted user work without explicit approval
intent over implementation: every issue file follows references/bdd-conventions.md
post-write stop: after a command's GitHub writes, STOP — no branches, no implementation, no status moves beyond status:todo
```

The Markdown file is the issue: its first H1 is the title and everything after it is the body. Change an issue by editing its file and running `update`; `update` overwrites the body on GitHub, so pull edits made on GitHub down with `import` first.

## Layout and state

```text
docs/epics/<NNN>-<slug>/                 # NNN = next free 3-digit ordinal under docs/epics/
  00-Epic-<Title>.md
  NN-<Story|Task|Bug>-<Title>.md         # NN from 01; the epic's children, in working order
  .github-state.json                     # file name → issue number; the round-trip anchor
  README.md                              # generated rollup — never edit by hand
docs/epics/standalone/                   # create-standalone files with no epic
```

```json
{ "epic": 41, "issues": { "00-Epic-Book-Search.md": 41, "01-Story-Search-By-Title.md": 42 } }
```

`epic` is null for a standalone folder. A story worked without a GitHub issue carries a `**Code:** LT-02` line under its H1 (`[A-Z]{2,5}-[0-9]+`); `sdlc:implement` and `sdlc:review` resolve it from `docs/epics/`. Relative paths resolve from the repo root.

## Pre-flight

```text
GI = node "${CLAUDE_PLUGIN_ROOT}/skills/plan/bin/gh-issues.js"
VS = node "${CLAUDE_PLUGIN_ROOT}/skills/plan/bin/validate-story.js"

if command in ("init", "bdd") or (command == "validate" and not args.issue):
  skip                                          # filesystem only
else:
  read ${CLAUDE_PLUGIN_ROOT}/references/github-preflight.md and run it
  if not session.gh_ok or session.repo is null: ❌ Error — '{command}' needs gh and a GitHub remote; STOP
```

## Command Dispatch

```text
dispatch(command, args):
  run Pre-flight
  match command:
    "init"              -> run § init
    "create"            -> read references/create.md and references/publish.md; run create
    "create-standalone" -> read references/create.md and references/publish.md; run create-standalone
    "update"            -> read references/publish.md; run § update
    "import"            -> read references/import.md; run import
    "status"            -> read references/status-and-reparent.md; run status
    "reparent"          -> read references/status-and-reparent.md; run reparent
    "bdd"               -> run § bdd
    "validate"          -> read references/bdd-conventions.md; run § validate
    default             -> ❌ Error — unknown command '{command}'; valid: init | create | create-standalone | update | import | status | reparent | bdd | validate
```

## run_gi — every GitHub write goes through gh-issues.js

```text
shq(v) = "'" + v.replace("'", "'\\''") + "'"           # every flag value is passed through shq

run_gi(cmd, flags) → (out, code):
  (out, code) = run: {GI} {cmd} {flags}
  surface out verbatim
  match code:
    0 | 1 -> return (out, code)                   # 0: last line "✅ Done — …" (or a ⚠️ no-op); 1: the 🛑/❌ line says what failed
    3   -> if args.yes: return run_gi(cmd, flags + " --yes")
           🟡 Waiting on you — AskUserQuestion "{n} problem(s) found before publishing (listed above) — how to proceed?"
             (stop)    "Stop to edit the file(s), then re-run (recommended)" -> STOP; nothing published
             (publish) "Publish as-is — the problems above ship unchanged"  -> return run_gi(cmd, flags + " --yes")
    2   -> ❌ Error — usage error (above); fix the flags; STOP
    127 -> ❌ Error — gh-issues.js needs Node on PATH; STOP
    else-> ❌ Error — gh-issues.js exited {code}; STOP
```

A caller with no branch for code 1 STOPs after it; state is saved, so re-running the command resumes.

End every command's reply with the script's last line, verbatim. `--yes` on `create`, `create-standalone` or `update` publishes past `prepare` problems and quality findings without asking; unattended callers pass it.

| gh-issues.js exit | Meaning |
| - | - |
| 0 | done |
| 1 | failed, or done with errors; progress so far is tracked in state |
| 2 | usage |
| 3 | `prepare` found problems; nothing published |

## init — Scaffold Epic Folder

```text
init(args):
  name = args.name or prompt("Epic name?")
  run_gi("init", "--name " + shq(name) + [" --docs-path " + shq(args.docs_path)] + [" --force"])
  D = the folder the ✅ line names
  if args.from:                                   # an ADR, spec or notes to turn into an epic
    read args.from
    fill D/00-Epic-*.md from it; write one D/NN-<Type>-<Title-Case-Slug>.md per child from assets/bdd-<type>-template.md
    follow references/bdd-conventions.md; architecture constraints cite the decision in args.from
    run § validate on each Story file; fix what fails
  STOP — the user reviews the files, then runs create
```

## update — Re-Sync Tracked Issue(s)

Edit-only: an untracked file or unknown number is skipped, never created.

```text
update(args):
  if args.file:      flags = "--file " + shq(args.file) + [" --key " + shq(args.key)] + [" --docs-path " + shq(args.docs_path)]
  elif args.docs_path: flags = "--docs-path " + shq(args.docs_path)
  else: ❌ Error — update requires --docs-path <dir> (batch) or --file <md> [--key N] (single); STOP
  run_gi("update", flags)
```

| flag | required | meaning |
| - | - | - |
| `--docs-path <dir>` | batch mode | re-syncs every file in its `.github-state.json` |
| `--file <md>` | single mode | one file; its number comes from state (`--docs-path`, else the file's folder) |
| `--key <N>` | no | the issue for an untracked `--file`; refused when the file is tracked as another number |

## bdd — Scaffold an Issue Template

Filesystem only. A scaffolded story validates clean.

```text
bdd(args):
  if not args.file: ❌ Error — bdd requires --file <path>; STOP
  kind = args.type or "story"
  if kind not in ("story", "epic", "task", "bug"): ❌ Error — --type must be story|epic|task|bug; STOP
  if exists(args.file) and not args.force: ❌ Error — {args.file} exists; pass --force to overwrite; STOP
  copy "${CLAUDE_PLUGIN_ROOT}/skills/plan/assets/bdd-{kind}-template.md" → args.file
  ✅ Done — scaffolded {kind} template → {args.file}; next: fill it in, then `validate --file {args.file}`
```

Name a file inside an epic folder `NN-<Type>-<Title-Case-Slug>.md`, or `create` does not pick it up.

## validate — Check Issue Quality

```text
validate(args):
  if args.issue:
    i = gh issue view {N} --json title,body,labels
    type = Epic|Story|Task|Bug from its epic|story|task|bug label, else Story
    f = temp file "issue-{N}.md" = "# {type}: {i.title}\n\n{i.body}"
  elif args.file:
    if args.file matches /['"$`;|&()<>\\\n]/: ❌ Error — unsafe characters in filename '{args.file}'; STOP
    f = args.file; type = from the NN-<Type>- file name, else its "# <Type>:" H1, else Story
  else: ❌ Error — validate requires --file <path> or --issue <N>; STOP

  errors = []
  if type == "Story":
    run: {VS} --file '{f}'; surface the report verbatim
    match exit_code: 0 -> pass;  1 -> errors += the ✗ lines;  else -> ❌ Error — validate could not run (node on PATH?); STOP
  findings = review f against references/bdd-conventions.md § Quality checklist and § Anti-patterns
  for each finding: print "⚠️ {rule}: \"{quoted line}\" — {why}; rewrite: {intent-level rewrite}"
  if args.issue and findings:
    offer: write the rewritten issue to a local file, then `update --file <it> --key {N}`   # never edit the issue on GitHub directly
  if errors: 🛑 Fail — fix the ✗ errors before publishing; STOP
  ✅ Pass — {len(findings)} quality finding(s) to review
```

## Test Plan Authoring

Before publishing a Story, Task or Bug with no `## Test Plan` heading, `prepare` writes one into the file, so it is published and re-synced with the file. A file that has one is never regenerated: edit it by hand. `sdlc:pull-request` reads the section verbatim into the PR description, so the heading stays `## Test Plan`. Items are the `### Scenario:` titles under `## Acceptance Criteria`, else that section's unordered bullets; numbered lists are never harvested. Epics get no Test Plan.

## Labels

| Issue | Labels at create |
| - | - |
| Epic | `epic` |
| Story / Task / Bug | `story` / `task` / `bug`, plus `status:todo` |

Missing labels are created. Later `status:*` moves belong to `${CLAUDE_PLUGIN_ROOT}/references/issue-status-labels.md`.

## Failure Handling

| Situation | Action |
| - | - |
| `.github-state.json` malformed | gh-issues.js stops before any write and never overwrites it; show the error, fix the file with the user |
| A create failed mid-run | everything created before it is tracked; re-run `create` to resume |
| An issue was edited on GitHub and the file is stale | `import` the epic (or copy the body into the file) before `update` |

## Bundled References

| Reference | Load when |
| - | - |
| `references/create.md` | `create`, `create-standalone` |
| `references/publish.md` | `create`, `create-standalone`, `update` |
| `references/import.md` | `import` |
| `references/status-and-reparent.md` | `status`, `reparent` |
| `references/bdd-conventions.md` | `validate`, `init --from`, or writing any issue file |
| `${CLAUDE_PLUGIN_ROOT}/references/github-preflight.md` | Pre-flight |
