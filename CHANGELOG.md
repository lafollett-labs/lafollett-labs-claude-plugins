# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `code-reviewer` (v2.7.2, marketplace 1.17.2): all 5 PE agent definitions (`pe-go`, `pe-vue`, `pe-aws-infra`, `pe-governance`, `pe-devtools`) now bake the team-mode delivery contract into their own Workflow step. Previously the contract lived only in the calling-agent dispatch input (SKILL.md), so PEs invoked from custom calling-agents that omitted the delivery clause would render YAML in session and idle without SendMessage. Now PE definitions self-contain the contract: `match invocation_mode: foreground → return YAML as tool-result; background-teammate → SendMessage(to: "team-lead", message: <yaml>)`. PEs deliver correctly regardless of dispatch site.
- `code-reviewer` (v2.7.1, marketplace 1.17.1): SKILL.md `§ Dispatch Input` now specifies an explicit DELIVERY CONTRACT split by invocation mode. Previously, "Return YAML findings" was ambiguous — when calling agents dispatched PEs with `team_name` set (background teammate mode), PEs would render YAML in their session and idle without calling the SendMessage tool, leaving the calling agent with no findings. Now: foreground dispatch returns YAML as tool-result; background-team dispatch delivers YAML via SendMessage to the team lead. Calling-agent contract clarified to treat team-mode dispatches as async with SendMessage delivery, not synchronous tool result.

### Added
- `LICENSE` — MIT
- `CONTRIBUTING.md` — public-repo contribution flow + authoring style guide + sub-agent self-containment convention
- `CHANGELOG.md` — this file
- `license: MIT` and `repository` fields added to all five plugin manifests (`code-reviewer`, `context-handoff`, `issue-manager`, `session-analyzer`, `ux-designer`) and the marketplace metadata

### Changed
- `code-reviewer`: PE agents (`pe-go`, `pe-vue`, `pe-aws-infra`, `pe-governance`) inline the Pass 4 Common Lenses + Calibration Anchor + Apply Protocol directly in their agent files. Sub-agents are self-contained execution units — neither relative paths nor `${CLAUDE_PLUGIN_ROOT}` substitution work reliably for asset loading from sub-agent context. Inlining is leaner per-invocation than asset-loading (zero asset-load tool call overhead, no path resolution failure modes). Cross-PE sync convention documented in `CONTRIBUTING.md`. `pe-devtools` keeps its calibrated single-operator lens set (different threat model).
- `code-reviewer`: SKILL.md slimmed — `§ Common Adversarial Lenses` section removed; the four-pass protocol summary's Pass 4 line trimmed to bare essentials. Pass 4 is purely PE-domain; the calling agent that loads SKILL.md never executes it directly.
- `code-reviewer`: SKILL.md `§ Engineer-Driven Multi-Round Loop` reduced from ~115 lines (loop-mechanic prose, diminishing-returns, automation, engineer-as-reviewer-conflict justification) to ~10 lines. Methodology rationale moved to the skill's README.md. The calling agent doesn't loop — operator drives by re-invoking — so the methodology was README-shaped from the start.
- `code-reviewer`: SKILL.md `§ Phase 2 Scope Discipline` slimmed; `§ Four-Pass Protocol` reframed to scope Pass 1/2/3 prose explicitly to the generic-fallback case (when calling agent runs the review directly without a matching PE).
- `code-reviewer`: round-to-round continuity logic moved from SKILL.md to each production PE's Workflow section (PEs read prior review doc; that's PE-execution, not calling-agent territory).
- `code-reviewer`: Pass 4 Adversarial Re-read recalibrated against over-firing — added Calibration Anchor to `SKILL.md § Common Adversarial Lenses`, clarified that NEW Pass 4 findings must clear the Phase 5 Finding Validation bar, and that closed-set themes from prior rounds should not re-fire under fresh adversarial lenses
- `code-reviewer`: `SKILL.md § Round-to-Round Continuity` rewritten — round-to-round context comes from the committed review doc on the branch (`./docs/code-reviews/{name}-code-review.md`), not from a session-resume wrapper script
- `code-reviewer`: project-agnostic scrub — example file paths and Stack Map entries no longer reference any single project's repository layout

### Removed
- `code-reviewer`: dead references to wrapper scripts (`scripts/headless-review.sh`, `scripts/bg-launch.sh`) that were never shipped with the plugin
