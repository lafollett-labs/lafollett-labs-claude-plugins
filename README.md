# LaFollett Labs — Claude Code Plugins

Claude Code plugin marketplace for [LaFollett Labs LLC](https://lafollettlabs.com).
Cross-project skills, commands, and developer workflow tools that work in any
repository.

## Available Plugins

Each plugin's README covers how to use it and the tips worth knowing before you
do.

| Plugin | What it does | |
| - | - | - |
| **code-reviewer** | Reviews that dispatch a principal engineer per stack — Go, Vue (Nuxt or Vite PWA), Rust/WASM, AWS IaC, agent governance, dev tooling, plus real-time audio — then consolidate the findings | [Usage & tips](./plugins/code-reviewer/README.md) |
| **context-handoff** | Carry a session's working state, decisions, and next steps across a `/clear` | [Usage & tips](./plugins/context-handoff/README.md) |
| **issue-manager** | *Deprecated: use `sdlc:plan`.* GitHub Issues that define what and why, never how — authored locally, pushed without duplicates | [Usage & tips](./plugins/issue-manager/README.md) |
| **live-stock** | `herd` runs a work plan's issues as parallel Claude Code lanes in herdr — each one implement → review → pull request on `sdlc` — then merges and finishes them | [Usage & tips](./plugins/live-stock/README.md) |
| **plugin-janitor** | Remove cached plugin versions nothing points at, and the empty directories they leave | [Usage & tips](./plugins/plugin-janitor/README.md) |
| **sdlc** | The delivery loop on GitHub — plan issues, implement, review with principal-engineer agents, open the PR, triage Copilot, or `deliver` it end to end | [Usage & tips](./plugins/sdlc/README.md) |
| **session-analyzer** | Find, read, and measure your Claude Code sessions | [Usage & tips](./plugins/session-analyzer/README.md) |
| **ux-designer** | Design harness producing shippable code — parallel visual directions in isolated worktrees | [Usage & tips](./plugins/ux-designer/README.md) |
| **watchwith** | Watch a video *with* Claude — dense frames paired with the narration spoken over them | [Usage & tips](./plugins/watchwith/README.md) |

## Installation

Add the marketplace once:

```
/plugin marketplace add https://github.com/lafollett-labs/lafollett-labs-claude-plugins
```

Then install whichever you want:

```
/plugin install code-reviewer
/plugin install context-handoff
/plugin install issue-manager
/plugin install live-stock
/plugin install plugin-janitor
/plugin install sdlc
/plugin install session-analyzer
/plugin install ux-designer
/plugin install watchwith
```

Updating is `/plugin marketplace update lafollett-labs-claude-plugins`. That
copies each bumped plugin into the cache and never sweeps the old ones, which is
what `plugin-janitor` is for.

### External dependencies

Most plugins need nothing beyond Claude Code. The exceptions:

| Plugin | Needs |
| - | - |
| `code-reviewer` | `gh` (PR reviews only) |
| `issue-manager` | `gh`, `node` |
| `live-stock` | the `sdlc` plugin, `herdr`, `gh`, `node`, `git`; Slack MCP optional |
| `sdlc` | `gh`, `node`, `git`; Slack MCP optional |
| `ux-designer` | Playwright MCP server (optional — enables visual self-critique) |
| `watchwith` | `ffmpeg`; `deno` recommended. Python packages self-install on first run |

## Repository Structure

```
.claude-plugin/
  marketplace.json              # Marketplace registry
plugins/
  <name>/
    README.md                   # Usage and tips — start here
    .claude-plugin/plugin.json  # Name, description, version
    commands/                   # Slash commands, if any
    agents/                     # Sub-agents, if any
    skills/<skill>/
      SKILL.md                  # Instructions the model loads
      README.md                 # Design notes, where one exists
      references/               # Loaded on demand
      assets/                   # Templates
      scripts/                  # CLI the skill invokes
      tests/                    # Stdlib test suites
docs/
  code-reviews/                 # Review records, pinned to a SHA
  plans/                        # Live design work
changelog.d/                    # One fragment per unreleased PR
scripts/
  ci/                           # Validators, secret scan, release engine + their suites
  hooks/                        # Optional git hooks
.github/workflows/              # CI (with the title gate), release
```

`code-reviewer` ships seven PE sub-agents under `agents/`, `sdlc` ships eleven plus
`plan-reviewer`, and `ux-designer` ships `design-engineer`.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the contribution flow, branch
naming, commit format, and authoring style guide.

### Adding a New Plugin

1. Create `plugins/<name>/.claude-plugin/plugin.json` with name, description, version, author
2. Add commands, skills, agents, or hooks under the plugin directory
3. Write `plugins/<name>/README.md` — what it does, how to use it, and the tips that are not obvious
4. Add an entry to `.claude-plugin/marketplace.json`
5. Add the plugin to the table in this README
6. Add a changelog fragment, `changelog.d/<branch-slug>.md`

### Versioning

Versions are stamped on release, never by hand. After each merge the release
workflow bumps every changed plugin by the squash commit's conventional type
(`feat` minor, `fix`/`chore`/… patch, `!` major), bumps the marketplace's
`metadata.version`, folds the `changelog.d/` fragments into
[CHANGELOG.md](./CHANGELOG.md), and opens a release PR that auto-merges and is
tagged `v<marketplace version>`. A new plugin debuts at the version its
`plugin.json` declares.

## License

[MIT](./LICENSE) — © 2026 LaFollett Labs LLC
