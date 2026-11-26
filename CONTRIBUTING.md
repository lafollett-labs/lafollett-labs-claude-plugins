# Contributing

Thanks for your interest in improving the LaFollett Labs Claude Code plugins.

## Quick Start

1. Fork the repo and create a branch: `<type>/<short-summary>` where `<type>` is `feat`, `fix`, `chore`, `docs`, `refactor`, or `test`
2. Make your change — stay scoped (one logical change per PR)
3. Commit using [Conventional Commits](https://www.conventionalcommits.org/) format:
   - `feat: add X`
   - `fix: handle Y in /code-reviewer`
   - `docs: clarify Z`
4. If you changed anything under `plugins/`, add a changelog fragment: `changelog.d/<branch-slug>.md` ([format](changelog.d/README.md))
5. Open a PR whose title is a conventional commit, with a short description of the change and its motivation

Never edit a `version` field. After a PR merges, the release workflow bumps each changed plugin
by its squash subject (`feat` minor, `fix`/`chore`/… patch, `!` major), bumps the marketplace,
folds the fragments into `CHANGELOG.md`, and tags the release. CI fails a PR that edits a version
or changes a plugin without a fragment.

Optional local hooks (gitleaks on the staged diff): `git config core.hooksPath scripts/hooks`.

## Plugin & Skill Authoring Style

Plugin agents and skills are markdown files loaded into model context on every invocation — token weight is paid every time. Keep prose lean:

- **Pseudocode for decision trees** — `if/elif/else`, `for x in xs`, `match`-style. Narrative decision trees are a defect.
- **Schemas for data contracts** as fenced blocks (file trees, templates, input contracts)
- **Literal commands verbatim** (grep invocations, format strings, branch patterns)
- **Cut filler** — "Why X" justifications, "Note:" paragraphs, prose summaries restating clear pseudocode, trailing "Important:" footers, redundant cross-references
- **Test before keeping a line:** if removing it does NOT change what the model does, cut it

## Project-Agnostic Skills

These plugins are intended to work for any project that installs them. When adding examples, use generic placeholders (e.g., `frontend/`, `infra/`) rather than names tied to a specific repository. Conventional Go layout (`pkg/`, `cmd/`, `lambdas/`) and CDK layout (`cdk/lib/`) are fine.

## Sub-Agent Self-Containment

Sub-agents (e.g., the PE reviewers in `code-reviewer/agents/*.md`) load their full agent definition file into context at dispatch time. They do NOT automatically inherit `SKILL.md` content, plugin paths, or `${CLAUDE_PLUGIN_ROOT}` substitution in arbitrary markdown body prose. Treat each sub-agent file as a self-contained unit:

- Keep all instructions a sub-agent needs to execute its task INLINE in its agent file, except skill assets the dispatcher passes as absolute paths (`REVIEW_MOVES`, `SPEC_COVERAGE_PROTOCOL`)
- Do NOT reference plugin assets via relative paths from sub-agent prose — the path resolution is unreliable from sub-agent context
- If multiple sub-agents share content (e.g., the six production PEs share the Pass 4 Common Adversarial Lenses + Calibration Anchor + Apply Protocol), inline the shared block in each agent file and document the sync convention below

### Sync convention for shared blocks

The six production PE files (`pe-go.md`, `pe-vue.md`, `pe-rust.md`, `pe-aws-infra.md`, `pe-governance.md`, `pe-audio.md`) carry an identical Pass 4 framing:
- Calibration Anchor
- Six common lenses (`hostile_attacker`, `scale_10x`, `junior_in_one_year`, `prod_incident_2am`, `partial_failure`, `silence_check`)
- How to Apply Pass 4 protocol

Stack-flavored examples for `silence_check` (and any stack-specific lenses) differ per file. The shared blocks must stay in sync. When editing any of those blocks, edit ALL SIX files together.

The § Test Budget `match` block is identical across `pe-go.md`, `pe-vue.md`, `pe-rust.md` and `pe-aws-infra.md`; only the static-check, narrow-run and `always:` lines vary by stack. Edit all four together.

`pe-devtools.md` runs a different lens set (single-operator local threat model) and is NOT part of this sync.

All seven PE files, `pe-devtools.md` included, carry an identical § Review Moves paragraph and identical `Review moves` / `Ripple receipts` Inputs bullets; only the Probes table varies by stack. The move procedures live once, in `skills/code-reviewer/assets/review-moves.md`, which the skill passes to each PE as an absolute `REVIEW_MOVES` path. Edit the paragraph in all seven files together, and keep the M1–M7 names in the asset, the probe tables, `SKILL.md` and the report template identical.

`server_side(f)` is identical in `skills/code-reviewer/SKILL.md` § PE Routing and `skills/init-project/SKILL.md` § 5a.1. Edit both together.

## Reporting Issues

Open a GitHub Issue with:
- What you expected to happen
- What actually happened
- Reproduction steps (the smaller the better)
- Plugin / skill name and version (see `plugins/<name>/.claude-plugin/plugin.json`)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
