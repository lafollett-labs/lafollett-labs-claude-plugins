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
  session-analyzer/         # JSONL session analysis
  ux-designer/              # UX design harness
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Each plugin is independently versioned; this repo is the source of truth.

### Versions and changelog — HARD RULE

The release workflow stamps every version after merge. A branch never edits one.

```
on ANY edit under plugins/<name>/:
    never edit plugin.json .version or marketplace.json .metadata.version   # CI fails the PR
    add changelog.d/<branch-slug>.md (format: changelog.d/README.md)        # CI fails the PR without one
    title the PR, and a single-commit PR's commit, as a conventional commit
on a new plugin:
    author its plugin.json version and its marketplace.json entry; it debuts at that version
```

| Squash subject | Plugin bump |
| - | - |
| `feat` | minor |
| `fix`, `chore`, `docs`, `refactor`, `test`, … | patch |
| `type!:` or a `BREAKING CHANGE:` footer | major |

The marketplace bumps minor when a plugin debuts, major when one is removed under `!`, else patch.
Use `feat` only for a capability a user could ask for by name; everything else is `fix` or `chore`.

Enable the hooks once per clone: `git config core.hooksPath scripts/hooks`.

## License

[MIT](./LICENSE) — © 2026 LaFollett Labs LLC
