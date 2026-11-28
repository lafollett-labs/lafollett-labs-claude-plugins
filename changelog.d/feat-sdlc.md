### Added
- **sdlc**: a new plugin for the delivery loop on GitHub. `plan` writes issues and
  sub-issues, `implement` builds a ticket test-first, `review` runs principal-engineer
  agents and keeps the review in the repo, `pull-request` opens the PR and gates on
  its checks, `copilot-review` triages Copilot's review threads, and `deliver` runs
  the loop end to end. Slack is optional and off by default.

### Deprecated
- **issue-manager**: use `sdlc:plan`, which covers its templates, quality checklist
  and `gh-issues.js` sync.
