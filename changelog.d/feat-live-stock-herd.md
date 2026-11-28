### Added
- **live-stock**: a new plugin. `herd` runs a work plan's GitHub issues or local
  story codes as parallel Claude Code lanes in herdr, each in its own worktree and
  each going through `sdlc:implement`, `sdlc:review --auto` and `sdlc:pull-request`.
  It answers lane gates as the engineer would, merges approved PRs behind a head-SHA
  guard, finishes each issue and stops when the run file's goal holds.
