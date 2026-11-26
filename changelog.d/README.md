# Changelog fragments

Every PR that changes `plugins/` adds one fragment here, named after its branch
(`changelog.d/feat-sdlc-github.md`). CI fails the PR without one.

```markdown
### Added
- **sdlc** opens pull requests on GitHub (`sdlc`).

### Fixed
- **code-reviewer** ...
```

Use Keep a Changelog headings (`Added`, `Changed`, `Deprecated`, `Removed`,
`Fixed`, `Security`). On release, the release workflow merges every fragment
into one `CHANGELOG.md` entry headed by the new marketplace version, lists the
plugin versions it bumped, and deletes the fragments. Never write a version
number here or edit a `version` field: the release stamps both.
