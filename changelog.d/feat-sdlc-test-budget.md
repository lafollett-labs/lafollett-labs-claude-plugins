### Added
- **sdlc**: `review` gives each PE a test budget. Author test receipts at HEAD's SHA
  (`<command> → pass @ <sha>`) stand in for rerunning those suites, a fix round runs tests
  only for what the fix touched, and a failing receipt forces a full run. At most
  `review.maxParallelPes` (default 2) suite-running PEs run at once; the rest start as
  slots free.
