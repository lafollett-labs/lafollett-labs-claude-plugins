# sdlc:init-project

Scans the repo and writes a `## Stack Map` table into `AGENTS.md` or `CLAUDE.md`. `sdlc:review` reads that table before its built-in globs to decide which principal-engineer agent reviews each path, which paths it skips, and which test commands each agent's stack uses.

> This README is the human usage guide. The model-facing contract lives in [`SKILL.md`](./SKILL.md).

## When to use it

- The built-in globs send a path to the wrong reviewer (a Node API under `web/`, PostgreSQL files that aren't T-SQL).
- You want vendored or generated code left out of review.
- You want to record each stack's real test command in one place.

**Triggers:** `init project for review` · `write a Stack Map` · `/sdlc:init-project`

## How it works

1. **Detect** — languages, frameworks, Cargo workspaces and wasm32 crates, audio/DSP paths, and test commands (from `package.json` scripts and `Makefile` targets where present).
2. **Build** — one row per path set: `Path | Stack | PE | Test Command`. The PE is an sdlc agent name, `pe-audio` for a domain row, or `(skip)`.
3. **Confirm** — shows the table (or the diff against an existing one) and writes only after you say yes.

The file is `AGENTS.md` when the repo has one and `CLAUDE.md` is absent or only imports it (`@AGENTS.md`); otherwise `CLAUDE.md`. An existing Stack Map is updated where it lives.

## Example

```markdown
## Stack Map

| Path | Stack | PE | Test Command |
| - | - | - | - |
| vendor/**, **/*.generated.ts | Vendored and generated code | (skip) | n/a |
| svc/**/*.go, go.mod | Go | `pe-go` | `go vet ./... && go test ./... -count=1 -race` |
| web/server/** | Node API | `pe-general-purpose` | `cd web && npm run test:server` |
| web/**/*.vue, web/**/*.ts | Vue 3 + Vite | `pe-vue` | `cd web && npm run typecheck && npm test` |
| engine/crates/synth/** | Real-time audio / DSP (domain) | `pe-audio` | n/a |
```

The first matching row wins, top to bottom. Branch and PR reviews read the map from the target branch, so a change can't skip or re-route its own files; a new map applies once it is merged. Rows with an unknown PE name are ignored and reported in the review's scope output.

## Related skills

- [`sdlc:review`](../review/README.md) — the review that reads the Stack Map
