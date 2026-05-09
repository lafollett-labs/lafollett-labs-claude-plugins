# LaFollett Labs — Claude Code Plugins

Claude Code plugin marketplace for [LaFollett Labs LLC](https://lafollettlabs.com). Cross-project skills, commands, and developer workflow tools that work in any repository.

## Available Plugins

| Plugin | Purpose | Details |
| ------ | ------- | ------- |
| [code-reviewer](./plugins/code-reviewer/skills/code-reviewer/) | PE-powered code reviews + project bootstrapping | [README](./plugins/code-reviewer/skills/code-reviewer/README.md) |
| [context-handoff](./plugins/context-handoff/) | Session state handoff and resume with prior-session deduplication | [Commands](./plugins/context-handoff/commands/) |
| [issue-manager](./plugins/issue-manager/) | GitHub Issue management with intent-over-implementation templates | [Skill](./plugins/issue-manager/skills/issue-manager/SKILL.md) |
| [session-analyzer](./plugins/session-analyzer/) | Analyze and extract conversations from Claude Code session JSONL files | [Skill](./plugins/session-analyzer/skills/session-analyzer/SKILL.md) |
| [ux-designer](./plugins/ux-designer/) | UX design harness with structured discovery, visual iteration, and parallel exploration | [Skill](./plugins/ux-designer/skills/ux-designer/SKILL.md) |

**code-reviewer** — PE-powered code reviews

- **`/code-reviewer`** — Four-pass protocol: Architecture → Quality+Tests → Security → mandatory Adversarial Re-read
- **`/init-project`** — Auto-detect stacks and write a Stack Map into `CLAUDE.md`
- Five built-in PE sub-agents shipped as proper agents (`claude-opus-4-7` model):
  - `pe-go` — Go / PostgreSQL / AWS Lambda
  - `pe-vue` — Vue 3 / Nuxt 3 / TypeScript / Tailwind / Storybook
  - `pe-aws-infra` — AWS CDK / Cloudflare CDKTF / Terraform / Docker / GitHub Actions
  - `pe-governance` — Agent definitions, skills, plugin instructions, CLAUDE.md
  - `pe-devtools` — Local dev tooling (single-operator threat model — calibrated against over-hardening)
- Generic three-pass fallback for stacks without a built-in PE (Rust, Python, Java, C#, etc.)
- Scope discipline (in_scope vs pre-existing findings)
- Verdict logic: CRITICAL/HIGH/MEDIUM block merge; LOW + INFO are awareness-only
- Engineer-driven multi-round loop with hard 3-round cap
- Consolidated reports at `./docs/code-reviews/`

### context-handoff

Save and restore session working state across `/clear` boundaries.

- **`/handoff-context`** — Serializes task goal, completed/in-progress/blocked items, decisions, constraints, modified files, and next steps to `.context/context-handoff.json`
- **`/resume-context`** — Loads the handoff, orients the session, verifies against live git state
- **Prior-session deduplication** — Diffs `next_steps` against archived handoffs' `completed` arrays to flag stale items and resolved blockers

### issue-manager

Create and manage GitHub Issues using intent-focused templates. All issues define **what** and **why** — engineers decide **how**.

- Epic, Story, Task, and Bug templates with quality gates
- CLI script for bulk creation, import, update, and sync status
- Markdown-first workflow: author locally in `docs/epics/`, push to GitHub Issues
- INVEST story validation and intent-over-implementation enforcement

### session-analyzer

Analyze and extract conversations from Claude Code session JSONL files. Python 3.10+, zero dependencies.

- **`list`** — Discover session files by project or across all projects
- **`extract`** — Human-readable conversation transcript with optional tool calls, thinking blocks, and timestamps
- **`analyze`** — Session statistics: duration, token usage, cache hit rate, tool breakdown, files modified
- Streaming parser handles arbitrarily large session files
- Markdown or JSON output formats

### ux-designer

Design harness for Claude Code — replicates and improves upon Claude Design's workflow. Structured discovery, interactive prototype generation, and visual iteration producing shippable code.

- **`/ux-designer`** — Five-phase design workflow: Discovery → Brief & Milestones → Generation → Visual Iteration → Parallel Exploration
- Multi-choice questioning flow fills gaps in the design prompt before generating anything
- **Variation count is asked up front** in Phase 2 (single direction vs 2-4 parallel variations) — no longer hidden behind keyword triggers
- Supports all major frameworks: HTML, React, Next.js, Vue, Nuxt, Svelte, Astro, Solid
- Optional Playwright MCP integration for screenshot-based self-critique and visual iteration
- Storybook support — create new or work with existing Storybook setups for component-level design
- Parallel design exploration via git worktrees, dispatched to a dedicated **`design-engineer`** subagent shipped with the plugin
- Master brief persisted to `.design/brief.md`; per-variation briefs at `.design/briefs/variation-{letter}.md` (in the main repo, passed to sub-agents by absolute path so they're readable from inside fresh worktrees)
- Component library integration (ShadCN, Aceternity, HeroUI, Radix)
- Every milestone committed to git — full version history of design iterations

## Installation

### Add the Marketplace

In Claude Code, open the plugin manager and add this marketplace:

```
/plugins marketplace add https://github.com/clafollett/lafollettlabs-claude-plugins
```

### Install Plugins

```
/plugins install context-handoff
/plugins install issue-manager
/plugins install session-analyzer
/plugins install ux-designer
```

### Manual Installation

If you prefer not to use the marketplace:

**context-handoff** (global commands):
```sh
cp plugins/context-handoff/commands/handoff-context.md ~/.claude/commands/
cp plugins/context-handoff/commands/resume-context.md ~/.claude/commands/
```

**issue-manager** (per-project skill):
```sh
# From the target project root
cp -r plugins/issue-manager/skills/issue-manager .claude/skills/
```

**session-analyzer** (per-project skill):
```sh
cp -r plugins/session-analyzer/skills/session-analyzer .claude/skills/
```

## Repository Structure

```
.claude-plugin/
  marketplace.json              # Marketplace registry
plugins/
  code-reviewer/                # Plugin: PE-powered code reviews
    .claude-plugin/plugin.json
    agents/
      pe-go.md                  # Go/PostgreSQL/Lambda reviewer (claude-opus-4-7)
      pe-vue.md                 # Vue/Nuxt/TS reviewer (claude-opus-4-7)
      pe-aws-infra.md           # CDK/CDKTF/IaC reviewer (claude-opus-4-7)
      pe-governance.md          # Agent governance markdown reviewer (claude-opus-4-7)
      pe-devtools.md            # Local dev tooling reviewer (claude-opus-4-7)
    skills/
      code-reviewer/            # Review engine — orchestrates dispatch + consolidates findings
        SKILL.md
        assets/                 # Report template
      init-project/             # Stack Map bootstrapper
        SKILL.md
        assets/                 # .code-reviewer.yml template
  context-handoff/              # Plugin: session handoff + resume
    .claude-plugin/plugin.json
    commands/
      handoff-context.md
      resume-context.md
  issue-manager/                # Plugin: GitHub Issue management
    .claude-plugin/plugin.json
    skills/
      issue-manager/
        SKILL.md
        references/             # Issue templates + quality checklist
        scripts/                # gh-issues.js CLI
  session-analyzer/             # Plugin: session JSONL analysis
    .claude-plugin/plugin.json
    skills/
      session-analyzer/
        SKILL.md
        scripts/                # session-analyzer.py CLI
  ux-designer/                  # Plugin: UX design harness
    .claude-plugin/plugin.json
    agents/
      design-engineer.md        # Subagent — implements one variation in an isolated worktree
    skills/
      ux-designer/
        SKILL.md
        references/             # Question library, layout patterns, animations, design system, frameworks
        assets/                 # Design brief template
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the contribution flow, branch naming, commit format, and authoring style guide.

### Adding a New Plugin

1. Create `plugins/<name>/.claude-plugin/plugin.json` with name, description, version, author
2. Add commands, skills, agents, or hooks under the plugin directory
3. Add an entry to `.claude-plugin/marketplace.json`
4. Update this README with the plugin description
5. Add a `## [Unreleased]` entry to [CHANGELOG.md](./CHANGELOG.md)

## License

[MIT](./LICENSE) — © 2026 LaFollett Labs LLC
