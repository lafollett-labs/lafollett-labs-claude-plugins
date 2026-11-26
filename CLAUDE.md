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

### Version bumping — HARD RULE

```
on ANY edit under plugins/<name>/:
    bump plugins/<name>/.claude-plugin/plugin.json  .version
    bump .claude-plugin/marketplace.json            .metadata.version
    add a CHANGELOG.md entry under [Unreleased]
    # all three in the SAME commit as the change, not a follow-up
```

| Change | Bump |
| - | - |
| bug fix, perf, text | patch — 1.0.0 → 1.0.1 |
| new feature or command | minor — 1.0.1 → 1.1.0 |
| breaking change | major — 1.1.0 → 2.0.0 |

Both files, every time. `/plugin marketplace update` compares versions: without a
bump it sees no difference and keeps serving the stale cached copy, so the change
reaches nobody and the working tree lies about what users have.

Check before every commit that touches `plugins/`:

```bash
# `if`, not a trailing `A && B || C` — when A is false the || branch fires and
# every non-plugin commit gets a false warning.
if git diff --cached --name-only | grep -q '^plugins/'; then
  git diff --cached -- '*/plugin.json' '.claude-plugin/marketplace.json' \
    | grep -q '^+.*version' || echo "MISSING VERSION BUMP"
fi
```

## License

[MIT](./LICENSE) — © 2026 LaFollett Labs LLC
