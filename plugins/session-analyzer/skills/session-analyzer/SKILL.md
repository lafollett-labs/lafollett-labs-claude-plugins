---
name: session-analyzer
description: Analyze and extract conversations from Claude Code session JSONL files. Use when the user asks to review, analyze, search, or extract transcripts from Claude Code sessions.
---

# Session Analyzer

Parse, extract, and analyze Claude Code session JSONL files. Zero dependencies — Python 3.10+ only.

## When to Use

- User asks to analyze a Claude Code session (token usage, tool stats, duration)
- User wants a readable conversation transcript from a session
- User asks to find or list their sessions
- User wants to review what happened in a prior session
- User asks about cache hit rates, model usage, or session efficiency
- User asks "find the session where we discussed X"

## Session File Locations

Claude Code stores sessions as JSONL files:

- **Project sessions:** `~/.claude/projects/{project-hash}/{session-id}.jsonl`
- **Project hash format:** absolute repo path with `/` replaced by `-` (e.g., `/Users/foo/repo` → `-Users-foo-repo`)

## Script Location

The CLI script is at `scripts/session-analyzer.py` relative to this SKILL.md file.

The plugin cache at `~/.claude/plugins/cache/` keeps **multiple versions** side-by-side. `~/.claude/plugins/installed_plugins.json` records each install under the `installPath` field. Use it to resolve the script:

```bash
# First installed_plugins.json entry for this plugin whose script exists on disk,
# preferring this marketplace when the registry holds more than one.
SA=$(python3 -c "
import json, pathlib, sys
reg = pathlib.Path.home() / '.claude/plugins/installed_plugins.json'
rel = 'skills/session-analyzer/scripts/session-analyzer.py'
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
    if name != 'session-analyzer':
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
[ -z "$SA" ] && SA=$(find ~/.claude/skills -path "*/session-analyzer/scripts/session-analyzer.py" -print -quit 2>/dev/null || true)

if [ -z "$SA" ]; then
  echo "session-analyzer: cannot resolve session-analyzer.py — checked installed_plugins.json and ~/.claude/skills" >&2
  exit 1
fi
```

## Argument Hints — User Intent to Flags

When the user asks something fuzzy, map their intent to the right command and flags:

| User says | Command |
|-----------|---------|
| "analyze my last session" | `list --latest -p <cwd>` → pipe path to `analyze` |
| "show yesterday's sessions" | `list --since yesterday -p <cwd>` |
| "the big session" / "longest session" | `list --min-size 5M -p <cwd>` |
| "sessions this week" | `list --since 7d -p <cwd>` |
| "find where we discussed CREW" | `search "CREW" -p <cwd>` |
| "what did we talk about on Monday?" | `list --since 2026-04-21 --before 2026-04-22 -p <cwd>` |
| "extract the full conversation" | `extract <path>` (saves to temp, prints clickable path) |
| "export to my docs folder" | `extract <path> -o ~/Documents/` |
| "show me the beginning" | `extract <path> --head 10` (stdout preview) |
| "what was the last thing?" | `extract <path> --tail 5` (stdout preview) |
| "show me with tool calls" | `extract <path> --tools --timestamps` |
| "how many tokens did we use?" | `analyze <path>` |
| "give me the JSON" | `list --json` / `analyze --format json` |

## Session Selection Workflow

When the user doesn't specify a session file directly:

1. Detect the current project from cwd (use `git rev-parse --show-toplevel`)
2. If user said "last" / "latest" / "most recent": run `list --latest -p <project>` to get the path directly
3. If user gave a date or description: use `list` filters or `search` to narrow candidates
4. If multiple matches: present a numbered list with dates and sizes, ask the user to pick
5. Once a session is selected: run `extract` or `analyze` on the full path

## Commands

### list — Find sessions

```bash
# All projects
python3 "$SA" list

# Sessions for a specific project
python3 "$SA" list --project /path/to/repo

# Filter by date (YYYY-MM-DD, today, yesterday, Nd, Nw, Nh)
python3 "$SA" list -p /path/to/repo --since yesterday
python3 "$SA" list -p /path/to/repo --since 7d --before today

# Filter by size
python3 "$SA" list -p /path/to/repo --min-size 1M

# Get just the most recent session's full path
python3 "$SA" list -p /path/to/repo --latest

# JSON output with full paths (for scripting / piping)
python3 "$SA" list -p /path/to/repo --json
```

**Date formats:** `YYYY-MM-DD`, `today`, `yesterday`, `3d` (3 days ago), `2w` (2 weeks ago), `6h` (6 hours ago)

**Size formats:** `500K`, `1M`, `5M`, `1G`

### search — Find sessions by content

```bash
# Search across all sessions for a project
python3 "$SA" search "CREW prototype" --project /path/to/repo

# Limit results
python3 "$SA" search "migration" -p /path/to/repo -n 5

# More context around matches
python3 "$SA" search "budget" -p /path/to/repo --context 150

# JSON output
python3 "$SA" search "Rembrandt" -p /path/to/repo --json
```

### extract — Conversation transcript

By default, `extract` saves to a temp file and prints the path (clickable in terminal).
The filename is auto-generated: `transcript-{date}-{session-name-or-id}.md`.
Use `--head`/`--tail` to preview turns directly in stdout.

```bash
# Full transcript → temp file (prints clickable path)
python3 "$SA" extract <file.jsonl>

# Full transcript → specific directory (auto-names the file)
python3 "$SA" extract <file.jsonl> -o /path/to/dir/

# Full transcript → specific filename
python3 "$SA" extract <file.jsonl> -o /path/to/transcript.md

# Preview first 10 turns in stdout (safe for context window)
python3 "$SA" extract <file.jsonl> --head 10

# Preview last 5 turns in stdout
python3 "$SA" extract <file.jsonl> --tail 5

# With tool call summaries and timestamps
python3 "$SA" extract <file.jsonl> --tools --timestamps

# With thinking blocks (collapsed in details tags)
python3 "$SA" extract <file.jsonl> --thinking

# Include sidechain (agent/team) entries
python3 "$SA" extract <file.jsonl> --sidechains
```

**Session naming:** If the user has set a custom session title (via Claude Code's rename feature), it appears in the filename. Otherwise falls back to a short session UUID.

**IMPORTANT for Claude:** When the user asks to "extract" or "export" a session, ALWAYS use file output (no `--head`/`--tail`). Print the resulting path so they can click it. Only use `--head`/`--tail` for quick peeks that the user wants to see inline.

### analyze — Session statistics

```bash
# Markdown report (duration, tokens, tools, files modified)
python3 "$SA" analyze <file.jsonl>

# JSON output for piping or further processing
python3 "$SA" analyze <file.jsonl> --format json
```

## Output Formats

- **list** → Markdown table (default), JSON with full paths (`--json`), or bare path (`--latest`)
- **search** → Markdown with snippets (default) or JSON (`--json`)
- **extract** → Date-stamped markdown file (temp dir or `-o` path); `--head`/`--tail` for stdout preview
- **analyze** → Markdown tables (default) or JSON (`--format json`)

## Important

- The script streams JSONL line-by-line — handles arbitrarily large session files
- Sidechain entries (sub-agent conversations) are excluded by default in `extract`
- The `analyze` command tracks files modified via Write/Edit tool calls
- Cache hit rate = `cache_read / (input + cache_read)` — higher is better
- `search` is case-insensitive substring matching across user and assistant text
- `list --latest` outputs a bare path — ideal for `$(...)` subshell piping
