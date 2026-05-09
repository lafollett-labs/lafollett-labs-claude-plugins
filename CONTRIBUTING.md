# Contributing

Thanks for your interest in improving the LaFollett Labs Claude Code plugins.

## Quick Start

1. Fork the repo and create a branch: `<type>/<short-summary>` where `<type>` is `feat`, `fix`, `chore`, `docs`, `refactor`, or `test`
2. Make your change — stay scoped (one logical change per PR)
3. Commit using [Conventional Commits](https://www.conventionalcommits.org/) format:
   - `feat: add X`
   - `fix: handle Y in /code-reviewer`
   - `docs: clarify Z`
4. Open a PR with a short description of the change and its motivation

## Plugin & Skill Authoring Style

Plugin agents and skills are markdown files loaded into model context on every invocation — token weight is paid every time. Keep prose lean:

- **Pseudocode for decision trees** — `if/elif/else`, `for x in xs`, `match`-style. Narrative decision trees are a defect.
- **Schemas for data contracts** as fenced blocks (file trees, templates, input contracts)
- **Literal commands verbatim** (grep invocations, format strings, branch patterns)
- **Cut filler** — "Why X" justifications, "Note:" paragraphs, prose summaries restating clear pseudocode, trailing "Important:" footers, redundant cross-references
- **Test before keeping a line:** if removing it does NOT change what the model does, cut it

## Project-Agnostic Skills

These plugins are intended to work for any project that installs them. When adding examples, use generic placeholders (e.g., `frontend/`, `infra/`) rather than names tied to a specific repository. Conventional Go layout (`pkg/`, `cmd/`, `lambdas/`) and CDK layout (`cdk/lib/`) are fine.

## Reporting Issues

Open a GitHub Issue with:
- What you expected to happen
- What actually happened
- Reproduction steps (the smaller the better)
- Plugin / skill name and version (see `plugins/<name>/.claude-plugin/plugin.json`)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
