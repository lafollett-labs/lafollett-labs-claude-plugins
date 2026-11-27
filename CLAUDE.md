# LaFollett Labs — Claude Plugins

Cross-project Claude Code plugins maintained by LaFollett Labs LLC.
Marketplace-installable via `/plugins`.

## Structure

See [README.md](./README.md) for the full plugin list and repository tree.

```
.claude-plugin/
  marketplace.json          # Marketplace registry
plugins/
  code-reviewer/            # PE-powered five-pass code reviews + review moves
  context-handoff/          # /handoff-context + /resume-context
  issue-manager/            # GitHub Issue management
  plugin-janitor/           # Plugin cache cleanup
  session-analyzer/         # JSONL session analysis
  ux-designer/              # UX design harness
  watchwith/                # Watch a video, write down what was on screen
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Each plugin is independently versioned; this repo is the source of truth.

Optional: `git config core.hooksPath scripts/hooks` runs gitleaks on each commit, and the private denylist scan when `git config labs.denylistScan <path>` names it. The hooks check no version or fragment rule.

### Versions and changelog — HARD RULE

Never edit an existing `version` in a plugin.json or marketplace.json, or CHANGELOG.md. The release workflow writes all three after merge, and CI fails a version edit.
Title every PR as a conventional commit; a single-commit PR's commit must be one too and give the same plugin bump as the title. CI fails the PR otherwise.
Check before pushing: `bash scripts/ci/check-pr.sh origin/main HEAD` (`upstream/main` in a fork).

```
if the PR changes plugins/:
    add changelog.d/<branch-slug>.md (format: changelog.d/README.md)   # CI fails the PR without one
if it adds a plugin:
    author its plugin.json version and marketplace.json entry          # the only version a branch writes
if it removes a plugin:
    title it `type!:`                                                   # the marketplace bumps major
```

| Squash commit | Plugin bump |
| - | - |
| `feat` | minor |
| `fix`, `chore`, `docs`, `refactor`, `test`, … | patch |
| `type!:` in the title, or a `BREAKING CHANGE:` footer in a commit message (not the PR description) | major |

The level applies to every plugin the PR touches, so keep unrelated plugin edits in separate PRs.
Use `feat` only for a capability a user could ask for by name; every other change takes a patch type.

## License

[MIT](./LICENSE) — © 2026 LaFollett Labs LLC
