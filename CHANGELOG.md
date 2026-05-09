# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `LICENSE` — MIT
- `CONTRIBUTING.md` — public-repo contribution flow + authoring style guide
- `CHANGELOG.md` — this file
- `license: MIT` and `repository` fields added to all five plugin manifests (`code-reviewer`, `context-handoff`, `issue-manager`, `session-analyzer`, `ux-designer`) and the marketplace metadata
- `code-reviewer`: `skills/code-reviewer/assets/adversarial-lenses.md` — single canonical home for the six common Pass 4 lenses, the calibration anchor, and the apply protocol. Loaded at Pass 4 entry by each production PE sub-agent (PEs are self-contained execution units; SKILL.md is for the calling agent's orchestration).

### Changed
- `code-reviewer`: PE agents (`pe-go`, `pe-vue`, `pe-aws-infra`, `pe-governance`) load the canonical Common Lenses + Calibration Anchor from `${CLAUDE_PLUGIN_ROOT}/skills/code-reviewer/assets/adversarial-lenses.md` at Pass 4 entry. Path uses Claude Code's `${CLAUDE_PLUGIN_ROOT}` variable (substituted at agent-load time to the plugin's absolute install path) — relative paths from sub-agents do not resolve reliably and force the agent to grep the file system. `pe-devtools` retains its calibrated single-operator lens set inline (different threat model).
- `code-reviewer`: SKILL.md asset references (`summary-report-template.md`, `adversarial-lenses.md`) updated to use `${CLAUDE_PLUGIN_ROOT}` consistently
- `code-reviewer`: Pass 4 Adversarial Re-read recalibrated against over-firing — added Calibration Anchor to `SKILL.md § Common Adversarial Lenses`, clarified that NEW Pass 4 findings must clear the Phase 5 Finding Validation bar, and that closed-set themes from prior rounds should not re-fire under fresh adversarial lenses
- `code-reviewer`: `SKILL.md § Round-to-Round Continuity` rewritten — round-to-round context comes from the committed review doc on the branch (`./docs/code-reviews/{name}-code-review.md`), not from a session-resume wrapper script
- `code-reviewer`: project-agnostic scrub — example file paths and Stack Map entries no longer reference any single project's repository layout

### Removed
- `code-reviewer`: dead references to wrapper scripts (`scripts/headless-review.sh`, `scripts/bg-launch.sh`) that were never shipped with the plugin
