---
name: init-project
description: Scans the project and writes or updates the `## Stack Map` table that sdlc:review reads before its built-in globs — one row per path set naming the sdlc PE that reviews it (pe-go, pe-rust, pe-vue, pe-angular, pe-csharp, pe-sql-server, pe-aws-infra, pe-github-actions, pe-governance, pe-devtools, pe-general-purpose, the pe-audio domain PE, or (skip)) and that stack's test command. Detects languages, frameworks, Cargo workspaces and wasm32 crates, audio/DSP paths, and test commands, shows the table, and writes AGENTS.md or CLAUDE.md only after the engineer approves. This skill should be used when the engineer says "init project for review", "write a Stack Map", "set up sdlc review routing", "/sdlc:init-project", or asks which PE reviews which path.
---

# Init Project (sdlc:init-project)


Write the repo's Stack Map: the table `sdlc:review`'s `scope.js` reads to route paths to PEs, exclude paths, and list each PE's test commands. Never create agent files; the PEs ship with the plugin.

## Phase 1: Detect stacks

Skip `node_modules/`, `target/`, `dist/`, `build/`, `.git/`, `vendor/`, and wasm-pack output (any directory holding `*_bg.wasm`) in every scan.

| Marker | Stack | PE |
| - | - | - |
| `go.mod`, `*.go` | Go | `pe-go` |
| `Cargo.toml`, `*.rs` | Rust | `pe-rust` |
| `*.vue`, `nuxt.config.*` | Vue 3 / Nuxt (Vite SPA when `vite.config.*` exists without `nuxt.config.*`) | `pe-vue` |
| `angular.json` | Angular (its `*.ts` and `*.html`) | `pe-angular` |
| `*.cs`, `*.csproj`, `*.sln` | C# / .NET | `pe-csharp` |
| `*.sqlproj`, or `*.sql` with T-SQL (`GO` batch lines, `CREATE PROCEDURE`, `[dbo]`) | SQL Server | `pe-sql-server` |
| `*.sql` without T-SQL markers | Other SQL | `pe-general-purpose` |
| `cdk.json`, `cdktf.json`, `*.tf`, `template.yml`, `Dockerfile*`, `docker-compose*` | AWS / IaC / Docker | `pe-aws-infra` |
| `.github/workflows/**`, `.github/actions/**`, `action.yml` | GitHub Actions | `pe-github-actions` |
| `**/SKILL.md`, `**/agents/*.md`, `**/commands/*.md`, `**/CLAUDE.md`, `**/AGENTS.md`, `.claude/rules/**/*.md`, `.github/copilot-instructions.md`, `**/skills/**/references/*.md`, `**/skills/**/assets/*.md` | Agent governance markdown | `pe-governance` |
| `scripts/dev/**`, `.githooks/**`, `.husky/**`, `lefthook.yml` | Local dev tooling | `pe-devtools` |
| React, Svelte, Node/TS backends, Python, Java, `.gitlab-ci.yml`, anything else | No specialist | `pe-general-purpose` |

Read framework markers inside each stack root: `[workspace]` in a `Cargo.toml` (that directory is the Rust stack root), a member `Cargo.toml` with `crate-type` containing `"cdylib"` and a `wasm-bindgen` dependency (a WebAssembly crate), `vite-plugin-pwa` or `workbox-*` in `package.json` (PWA), `.storybook/`, `playwright.config.*`, `vitest.config.*`, `jest.config.*`, `pytest.ini`, `Makefile`.

### Audio paths

```
signals  = grep -rlE 'AudioContext|AudioWorkletProcessor|registerProcessor|getUserMedia|createMediaStreamSource|createOscillator|cpal::|rustfft|realfft|hound::' \
             --include='*.rs' --include='*.ts' --include='*.js' --include='*.mjs' --include='*.vue' . (minus skip dirs)
covered  = signals under a directory whose name holds the word audio, dsp or pitch, or whose basename contains "worklet"
fixtures = directories holding *.wav or *.flac whose path contains "fixture" or "testdata"
extra    = signals − covered

audio_paths = []
for dir in parent directories of extra:
  if at least half of dir's source files are in signals: audio_paths += "<dir>/**"
  else:                                                   audio_paths += each file of extra in dir
audio_paths += fixtures
if audio_paths:
  emit | <audio_paths, comma-separated> | Real-time audio / DSP (domain) | `pe-audio` | n/a (stack PE runs suites) |
```

`covered` files need no row: `pe-audio`'s default globs already match them. List them under `pe-audio` in the summary.

## Phase 2: Map paths

```bash
ls -d */ | head -30
find <dir> -type f -name '*.*' -not -path '*/node_modules/*' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -10
```

Assign each top-level directory, and each significant subdirectory, to a stack. Group directories that share a stack and test command into one row (`svc/**, pkg/**`). Scope a row to its stack's files when its directory mixes stacks (`web/**/*.vue`, not `web/**`).

## Phase 3: Detect test commands

| Stack | Look for | Default command |
| - | - | - |
| Go | `go.mod` | `go vet ./... && go test ./... -count=1 -race` |
| Rust | workspace-root `Cargo.toml` | `cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace` |
| Rust → wasm32 | each WebAssembly crate | append `&& cargo build -p <crate> --target wasm32-unknown-unknown --release` to the Rust command |
| Vue / Nuxt / Angular / Node | `package.json` scripts | `npm run typecheck && npm test` (add `&& npm run build` for a PWA or WASM consumer) |
| C# | `*.sln` | `dotnet build && dotnet test` |
| SQL Server | `*.sqlproj` | `dotnet build <project>.sqlproj` |
| CDK | `package.json` beside `cdk.json` | `npm test && npx cdk synth --all` |
| CDKTF | `cdktf.json` | `npm test && npx cdktf synth` |
| Terraform | `*.tf` | `terraform validate` |
| GitHub Actions | `.github/workflows/` | `actionlint` |
| Python | `pyproject.toml`, `requirements*.txt` | `pytest` |
| Java | `pom.xml` / `build.gradle` | `mvn test` / `./gradlew test` |
| Governance, docs, audio (domain) | — | `n/a` |

When `package.json` or a `Makefile` exists in the stack root, use its real `test`, `typecheck`, `lint` and `build` script or target names instead of the defaults. A stack root below the repo root prefixes its command with `cd <dir> &&`. A stack with no test found gets `# TODO: no test command detected` in the command column and a line in the summary.

## Phase 4: Resolve the instruction file

```
# repo-root AGENTS.md and CLAUDE.md
claude_imports_only = CLAUDE.md exists and every non-blank line of it is `@AGENTS.md` or `@./AGENTS.md`

if CLAUDE.md holds a `## Stack Map`:
  target = CLAUDE.md        # update that map; never write a second one
elif AGENTS.md holds a `## Stack Map`:
  target = AGENTS.md
elif AGENTS.md exists and (CLAUDE.md does not exist or claude_imports_only):
  target = AGENTS.md
else:
  target = CLAUDE.md        # created if absent
```

## Phase 5: Build the table

```markdown
## Stack Map

| Path | Stack | PE | Test Command |
| - | - | - | - |
| docs/code-reviews/**, vendor/**, **/*.generated.ts | Review docs, vendored and generated code | (skip) | n/a |
| **/SKILL.md, **/agents/*.md, **/CLAUDE.md, **/AGENTS.md | Agent governance markdown | `pe-governance` | n/a |
| svc/**/*.go, pkg/**/*.go, go.mod, go.sum | Go | `pe-go` | `go vet ./... && go test ./... -count=1 -race` |
| engine/** | Rust (Cargo workspace, wasm32) | `pe-rust` | `cd engine && cargo test --workspace && cargo build -p engine-wasm --target wasm32-unknown-unknown --release` |
| web/server/** | Node API | `pe-general-purpose` | `cd web && npm run test:server` |
| web/**/*.vue, web/**/*.ts | Vue 3 + Vite | `pe-vue` | `cd web && npm run typecheck && npm test && npm run build` |
| engine/crates/synth/**, fixtures/audio/** | Real-time audio / DSP (domain) | `pe-audio` | n/a (stack PE runs suites) |
| infra/** | AWS CDK | `pe-aws-infra` | `cd infra && npm test && npx cdk synth --all` |
```

How `scope.js` reads the table:

| Rule | Effect |
| - | - |
| Columns | found by header: `Path`, any header containing the word `PE`, any header containing `Test` |
| Path | comma-separated globs; no `/` matches the basename anywhere, otherwise from the repo root; `dir/` means `dir/**`; `{a,b}` expands |
| PE | an sdlc PE name, `sdlc:pe-x`, `code-reviewer:pe-x`, `Generic` (= `pe-general-purpose`), or `(skip)`; any other name is ignored with a note |
| Order | the first stack or `(skip)` row matching a file wins, top to bottom, before the built-in globs |
| `(skip)` | the file is excluded from review |
| `pe-audio` row | adds files to the domain PE beside their stack PE; never routes |
| Test Command | each backtick span is one command; `n/a`, `-`, `# TODO` or empty is none |
| Source | branch and PR reviews read the map from the target branch, so a new or edited map applies once merged |

Order rows: `(skip)` first, then `pe-governance` and `pe-devtools`, then narrower paths before broader ones. Keep every row's paths scoped so no row claims a file another row's stack owns.

### Frontend routing check

```
server_side(f) = f is not *.config.*, *.spec.*, *.test.*, or under server/ beside a nuxt.config.* (Nitro is pe-vue's)
                 and (a path segment of f is backend/, functions/, lambda/ or server/
                      or f imports http, https, net, child_process or fs (bare or node:), express, fastify, koa,
                         hono, @nestjs/*, pg, mysql2, prisma, @prisma/*, mongoose, knex, drizzle-orm, typeorm,
                         sequelize, ioredis, ws, or any other HTTP-server framework, database or cache driver, or ORM)
for each row whose PE is pe-vue:
  hits = files under the row's paths (minus skip dirs) where server_side(f)
  if hits:
    insert a row above it for the hits' directories → pe-general-purpose with their own test command
    summary += "WARNING: <row paths> would route <n> server-side files (e.g. <file>) to pe-vue — added <dirs> → pe-general-purpose"
```

Markdown follows its audience: model-read files (skills, agents, CLAUDE.md, AGENTS.md, rules) → `pe-governance`; human docs (ADRs, runbooks, READMEs) → `pe-general-purpose` or `(skip)`.

## Phase 6: Confirm and write

```
existing = the `## Stack Map` table in target, if any
proposed = Phase 5 table
if existing:
  proposed = existing rows kept in order, with new rows inserted per the ordering rule and changed cells updated
  show the diff of existing → proposed (added, changed, removed rows)
else:
  show proposed
ask: "Write this Stack Map to {target}? (yes / edit / no)"
match answer:
  yes  → replace the existing table in place, or append `## Stack Map` + table to target (create it if absent)
  edit → apply the engineer's changes, show the table again, ask again
  no   → write nothing; print the table for manual use
```

Never write before the engineer answers yes, and never remove an existing row the engineer did not approve removing.

## Phase 7: Summary

```
=== Stack Map ready for sdlc:review ===

Stacks:
  - Go (pe-go):                 svc/, pkg/
  - Rust workspace (pe-rust):   engine/   (wasm32 crate: engine-wasm)
  - Vue 3 + Vite (pe-vue):      web/
  - Audio / DSP (pe-audio):     engine/crates/synth/, fixtures/audio/  (+ default globs)
Skipped:            docs/code-reviews/, vendor/
No test command:    {stacks with # TODO}
Routing warnings:   {frontend routing check warnings}
Written to:         {target} | not written

Run /sdlc:review to review with this map (branch and PR reviews use it once it is on the target branch).
```
