# LaFollett Labs — Claude Plugins

Cross-project Claude Code plugins maintained by LaFollett Labs LLC.
Marketplace-installable via `/plugins`.

## Structure

See [README.md](./README.md) for the full plugin list and repository tree.

```
.claude-plugin/
  marketplace.json          # Marketplace registry
plugins/
  code-reviewer/            # PE-powered four-pass code reviews
  context-handoff/          # /handoff-context + /resume-context
  issue-manager/            # GitHub Issue management
  session-analyzer/         # JSONL session analysis
  ux-designer/              # UX design harness
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Each plugin is independently versioned; this repo is the source of truth.

### Version bumping (required on every edit)

Every change to a plugin's content MUST include a patch version bump in `.claude-plugin/marketplace.json` and that plugin's `.claude-plugin/plugin.json`. Without a bump, `/plugins update` may not pick up the change.

```
bug fix / text change      → patch  (1.0.0 → 1.0.1)
new feature or command     → minor  (1.0.1 → 1.1.0)
breaking change            → major  (1.1.0 → 2.0.0)
```

## License

[MIT](./LICENSE) — © 2026 LaFollett Labs LLC
