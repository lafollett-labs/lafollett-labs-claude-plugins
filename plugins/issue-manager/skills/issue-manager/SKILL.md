---
name: issue-manager
description: Use when creating GitHub Issues (Epics, Stories, Tasks, Bugs), reviewing issue quality, or converting ADRs into Epics. Enforces intent-over-implementation — issues define WHAT and WHY, never HOW.
---

# Issue Manager

Create and manage GitHub Issues with intent-focused templates. All issues follow the Intent Officer model: define intent and outcomes, engineers decide implementation.

## Core Principle: Intent Over Implementation

Every issue defines **outcomes and behaviors**, not implementation steps. The implementing agent (CTO, engineer) decides the approach. Stories describe what the system should do from the user's or operator's perspective — never how to build it internally.

## When to Use This Skill

- Creating a new Epic with child Stories/Tasks
- Creating standalone Stories, Tasks, or Bugs
- Importing existing GitHub Epics to local markdown for rework
- Reviewing existing issues for quality (too implementation-heavy?)
- Converting ADR decisions into Epics with proper story breakdown
- Rewriting implementation-focused issues into intent-focused ones

## Issue Types

| Type | When | Template |
|------|------|----------|
| Epic | Business goal spanning multiple stories | `references/epic-template.md` |
| Story | User-facing feature or capability | `references/story-template.md` |
| Task | Technical work that isn't user-facing | `references/task-template.md` |
| Bug | Defect report with repro steps | `references/bug-template.md` |

## Script Location

The CLI script is at `scripts/gh-issues.js` relative to this SKILL.md file. When invoking it, use the absolute path to the installed plugin location.

The plugin cache at `~/.claude/plugins/cache/` keeps **multiple versions** side-by-side. `~/.claude/plugins/installed_plugins.json` records each install under the `installPath` field. Use it to resolve the script:

```bash
# First installed_plugins.json entry for this plugin whose script exists on disk,
# preferring this marketplace when the registry holds more than one.
GH_ISSUES=$(python3 -c "
import json, pathlib, sys
reg = pathlib.Path.home() / '.claude/plugins/installed_plugins.json'
rel = 'skills/issue-manager/scripts/gh-issues.js'
market = 'lafollett-labs-claude-plugins'
try:
    plugins = json.loads(reg.read_text()).get('plugins', {})
    if not isinstance(plugins, dict):
        plugins = {}
except Exception:
    plugins = {}
found = []
for key, entries in plugins.items():
    name, _, mkt = key.partition('@')
    if name != 'issue-manager':
        continue
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        install = entry.get('installPath')
        if not install:
            continue
        script = pathlib.Path(install) / rel
        if script.is_absolute() and script.is_file():
            found.append((mkt != market, str(script)))
if found:
    print(sorted(found)[0][1])
    sys.exit(0)
sys.exit(1)
" || true)

# Fallback for manual install (no version ambiguity)
# `|| true` is load-bearing: find exits 1 with no ~/.claude/skills, killing `set -e` callers.
[ -z "$GH_ISSUES" ] && GH_ISSUES=$(find ~/.claude/skills -path "*/issue-manager/scripts/gh-issues.js" -print -quit 2>/dev/null || true)

if [ -z "$GH_ISSUES" ]; then
  echo "issue-manager: cannot resolve gh-issues.js — checked installed_plugins.json and ~/.claude/skills" >&2
  exit 1
fi
```

All file operations (epic folders, docs) are created in the **current working directory's project root** (detected via `git rev-parse --show-toplevel`), NOT in the plugin's install directory.

## Workflow

### Create a New Epic + Stories

1. Locate the script using the discovery command above
2. `node "$GH_ISSUES" init --name "Epic Title"`
3. Edit the generated markdown files using the reference templates
4. Add Story/Task/Bug files: `01-Story-Title.md`, `02-Task-Title.md`, etc.
5. `node "$GH_ISSUES" create --docs-path docs/epics/<slug>`
6. Script creates GitHub Issues, links children to Epic, saves state

### Import Existing Epic for Rework

1. `node "$GH_ISSUES" import --epic 582`
2. Downloads Epic + all child issues to `docs/epics/582-<slug>/`
3. Edit the local markdown files (rework to intent-over-implementation)
4. `node "$GH_ISSUES" update --docs-path docs/epics/582-<slug>`
5. Pushes edits to existing GitHub Issues by mapped ID (no duplicates)

### Check Sync Status

1. `node "$GH_ISSUES" status --docs-path docs/epics/<slug>`

### Quality Gate

Before creating any issue, verify against `references/quality-checklist.md`:
- [ ] Description focuses on WHAT and WHY, not HOW
- [ ] Acceptance criteria are observable outcomes, not implementation checkpoints
- [ ] No code snippets, file paths, or library choices (unless Epic-level architectural constraint)
- [ ] Domain language used, not technical jargon
- [ ] Stories are INVEST: Independent, Negotiable, Valuable, Estimable, Small, Testable

### Labels

Use GitHub labels for type identification:
- `epic` — Epic issues
- `story` — User stories
- `task` — Technical tasks
- `bug` — Defect reports

## CLI Script

**Location:** `scripts/gh-issues.js` (relative to this skill's install directory)

| Command | Purpose |
|---------|---------|
| `init --name "Title" [--epic 582]` | Initialize new epic folder with template |
| `create --docs-path docs/epics/<slug>` | Create GitHub Issues from local markdown |
| `update --docs-path <path> [--file <file>]` | Update existing Issues from edited markdown |
| `import --epic 582 [--docs-path <path>]` | Import Epic + children to local markdown |
| `status --docs-path <path>` | Show sync status (local vs GitHub) |

**State tracking:** `.github-state.json` in each epic directory maps filenames to GitHub issue numbers. The script is idempotent — re-running `create` skips already-created issues.

**Epic folder naming:** `###-slug` where `###` is a 3-digit ordinal (e.g., `001-db-reset`, `004-slack-integration`).

**File naming:** `##-Type-Title-With-Dashes.md` where `00` = Epic, `01+` = children. Types: Epic, Story, Task, Bug.

## References (load on demand)

| Reference | When to Load |
|-----------|-------------|
| `references/epic-template.md` | Creating an Epic |
| `references/story-template.md` | Creating a Story |
| `references/task-template.md` | Creating a Task |
| `references/bug-template.md` | Creating a Bug |
| `references/quality-checklist.md` | Reviewing issue quality |

## IMPORTANT: Post-Creation Gate

After creating an Epic and its Stories, STOP. Do NOT proceed to implementation, create branches, or start coding. The CEO dispatches implementation work separately.
