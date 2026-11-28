---
name: init-project
description: DEPRECATED, use sdlc:init-project. Scan the project and write a Stack Map to AGENTS.md or CLAUDE.md for /code-reviewer. Detects languages, frameworks, Cargo workspaces and wasm32 crates, Vite-only Vue apps, audio/DSP paths, and test commands. PEs (pe-go, pe-vue, pe-rust, pe-aws-infra, pe-governance, pe-devtools, and the pe-audio domain PE) ship with the plugin.
---

# Initialize Project for Code Review

Deprecated:

```text
if the sdlc:init-project skill is available and `node` is on PATH:
  tell the user "code-reviewer is deprecated; running sdlc:init-project" and invoke sdlc:init-project with the same request; stop
else: continue with this skill
```

Bootstraps the `/code-reviewer` skill into any project by scanning the repo
and writing a Stack Map into the project's `AGENTS.md` or `CLAUDE.md` (or `.code-reviewer.yml`).

The seven built-in PE sub-agents — stack PEs `code-reviewer:pe-go`,
`code-reviewer:pe-vue`, `code-reviewer:pe-rust`, `code-reviewer:pe-aws-infra`,
`code-reviewer:pe-governance`, `code-reviewer:pe-devtools`, and the domain PE
`code-reviewer:pe-audio` — ship with the plugin as proper agents. This skill
does NOT regenerate them. For stacks not covered by a built-in PE (Python,
Java, C#, etc.), the code-reviewer skill falls back to a generic review
(three passes plus the review moves) using the Stack Map's test commands.

---

## Phase 1: Detect Stacks

Scan the repository for language markers, build files, and framework configs.

### Language Detection

The "Built-in PE" column maps a detected stack to a plugin-shipped stack PE. "Generic" means no built-in agent matches — code-reviewer falls back to the generic review for that stack. Domain PEs (`pe-audio`) come from § Audio Path Detection, not this table.

| Marker | Stack | Built-in PE |
| - | - | - |
| `go.mod`, `*.go` | Go | `pe-go` |
| `package.json` + `*.vue` | Vue/Nuxt — Vue 3 + Vite (SPA/PWA) when `vite.config.*` exists without `nuxt.config.*` | `pe-vue` |
| `package.json` + `*.tsx`/`*.jsx` | React | `pe-vue` |
| `package.json` + `*.svelte` | Svelte | `pe-vue` |
| `cdk.json`, `*.ts` in `cdk/` or `infra/` | AWS CDK | `pe-aws-infra` |
| `cdktf.json` | CDKTF | `pe-aws-infra` |
| `*.tf` | Terraform | `pe-aws-infra` |
| `Dockerfile*`, `docker-compose*` | Docker | `pe-aws-infra` |
| `.github/workflows/*.yml` | GitHub Actions CI/CD | `pe-aws-infra` |
| `.gitlab-ci.yml` | GitLab CI/CD | `pe-aws-infra` |
| `Cargo.toml`, `*.rs` | Rust | `pe-rust` |
| `pyproject.toml`, `requirements.txt`, `*.py` | Python | Generic |
| `*.java`, `pom.xml`, `build.gradle` | Java | Generic |
| `*.cs`, `*.csproj`, `*.sln` | C# / .NET | Generic |
| `.claude/agents/*.md`, `**/SKILL.md`, `plugins/**/agents/*.md`, `**/CLAUDE.md`, `**/AGENTS.md`, `.claude/rules/*.md`, `docs/rules/*.md`, `**/skills/*/assets/*.md`, `**/skills/*/references/*.md` | Agent governance markdown | `pe-governance` |
| `scripts/dev/**/*.sh`, `scripts/**/*.sh` with `# pe: devtools` header, `.githooks/**`, `lefthook.yml` | Local dev tooling (single-operator threat model) | `pe-devtools` |

### Framework Detection

Dig deeper into detected stacks to identify frameworks:

| Indicator | Framework |
| - | - |
| `nuxt.config.*` | Nuxt 3 |
| `vite.config.*` + `*.vue`, no `nuxt.config.*` | Vue 3 + Vite SPA |
| `vite-plugin-pwa` / `workbox-*` in `package.json`, or `*.webmanifest` | PWA (service worker + manifest) |
| `[workspace]` in a `Cargo.toml` | Cargo workspace — its directory is the Rust stack root |
| `crate-type` containing `"cdylib"` + a `wasm-bindgen` dependency in a member `Cargo.toml` | WebAssembly crate (wasm32 target build) |
| `wasm-pack` / `vite-plugin-wasm` in `package.json`, or a `pkg/` import of a wasm-bindgen crate | WASM consumed by the web app |
| `next.config.*` | Next.js |
| `astro.config.*` | Astro |
| `vite.config.*` | Vite |
| `angular.json` | Angular |
| `svelte.config.*` | SvelteKit |
| `tailwind.config.*` | Tailwind CSS |
| `.storybook/` | Storybook |
| `playwright.config.*` | Playwright |
| `vitest.config.*`, `jest.config.*` | Vitest / Jest |
| `testcontainers` in go.mod | Testcontainers (Go) |
| `pytest.ini`, `conftest.py` | Pytest |
| `Makefile` | Make build system |

### Audio Path Detection

```
skip    = node_modules/, target/, dist/, .git/, vendor/, wasm-pack output (any dir holding *_bg.wasm)
signals = grep -rlE 'AudioContext|AudioWorkletProcessor|registerProcessor|getUserMedia|createMediaStreamSource|createOscillator|cpal::|rustfft|realfft|hound::' \
            --include='*.rs' --include='*.ts' --include='*.js' --include='*.mjs' --include='*.vue' . (minus skip)
covered = signals matching pe-audio's default globs: **/{audio,dsp,pitch}/**/*.{rs,ts,js,mjs,vue}, **/*[Ww]orklet*.{ts,js,mjs}
fixtures = directories holding *.wav or *.flac whose path contains "fixture" or "testdata",
           plus any accuracy-baseline file a test reads (grep tests for "baseline")
extra   = signals − covered

audio_paths = []
for dir in parent directories of extra:
  if at least half of dir's source files are in signals: audio_paths += "<dir>/**"
  else:                                                   audio_paths += each file of extra in dir
audio_paths += fixtures

if audio_paths:
  emit Stack Map row: | <audio_paths, comma-separated> | Real-time audio / DSP (domain) | `pe-audio` | n/a (stack PE runs suites) |
elif covered:
  emit no row — the default globs already route those files; list them under pe-audio in the summary
```

---

## Phase 2: Map Directory Structure

Walk the repo and assign each top-level directory (and significant
subdirectories) to a stack and PE type.

```bash
# Get top-level directories
ls -d */ | head -30

# Get file extension distribution per directory
find <dir> -type f -name '*.*' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -10
```

Build a path → stack → PE mapping. Group directories that share the same
stack (e.g., `lambdas/` and `pkg/` are both Go → PE-Go).

---

## Phase 3: Detect Test Commands

For each detected stack, identify the test commands:

| Stack | Look For | Default Test Command |
| - | - | - |
| Go | `go.mod` | `go vet ./... && go test ./... -count=1 -race` |
| Vue/Nuxt | `package.json` scripts | `npm run typecheck && npm test` |
| Vue 3 + Vite (PWA or WASM consumer) | `package.json` scripts | `npm run typecheck && npm test && npm run build` |
| React | `package.json` scripts | `npm test` |
| CDK | `package.json` in cdk dir | `cd <dir> && npm test && npx cdk synth --all` |
| CDKTF | `package.json` in cdktf dir | `cd <dir> && npm test && npx cdktf synth` |
| Terraform | `*.tf` | `terraform validate` |
| Rust | `Cargo.toml` (workspace root) | `cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace` |
| Rust → wasm32 | each WebAssembly crate | `cargo build -p <crate> --target wasm32-unknown-unknown --release` (append to the Rust row) |
| Audio / DSP (domain) | — | n/a — the stack PE for the same files runs the suites |
| Python | `pyproject.toml` / `requirements.txt` | `pytest` |
| Java (Maven) | `pom.xml` | `mvn test` |
| Java (Gradle) | `build.gradle` | `./gradlew test` |
| C# | `*.sln` | `dotnet test` |
| Docker | `Dockerfile` | `docker build --target test` (if multi-stage) |

**Override from package.json:** If `package.json` exists, read `scripts` for
`test`, `typecheck`, `lint`, `build` — use actual script names, not defaults.

---

## Phase 4: Resolve the Instruction File

```
# repo-root AGENTS.md and CLAUDE.md
claude_imports_only = CLAUDE.md exists and every non-blank line of it is `@AGENTS.md` or `@./AGENTS.md`

if CLAUDE.md holds a `## Stack Map`:
  target = CLAUDE.md          # offer to update the existing map; never write a second one
elif AGENTS.md holds a `## Stack Map`:
  target = AGENTS.md          # offer to update the existing map; never write a second one
elif AGENTS.md exists and (CLAUDE.md does not exist or claude_imports_only):
  target = AGENTS.md
else:
  target = CLAUDE.md          # created if absent
```

Read every instruction file that exists for:
- Existing project structure documentation
- Team structure or review chain information
- Coding standards or conventions

---

## Phase 5: Generate Output

### 5a: Stack Map

Generate a Stack Map table and prompt the user to add it to `target`:

```markdown
## Stack Map

| Path | Stack | Built-in PE | Test Command |
| - | - | - | - |
| lambdas/**, pkg/** | Go | `pe-go` | `go vet ./... && go test ./... -count=1 -race` |
| frontend/** | Vue/Nuxt | `pe-vue` | `cd frontend && npm run typecheck && npm test` |
| engine/** | Rust (Cargo workspace, wasm32) | `pe-rust` | `cd engine && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace && cargo build -p engine-wasm --target wasm32-unknown-unknown --release` |
| engine/crates/dsp/**, web/src/audio/**, fixtures/audio/** | Real-time audio / DSP (domain) | `pe-audio` | n/a (stack PE runs suites) |
| cdk/** | CDK TypeScript | `pe-aws-infra` | `cd cdk && npm test && npx cdk synth --all` |
| api/** | Python | Generic | `cd api && pytest` |
| .claude/agents/**, **/SKILL.md, plugins/**/agents/*.md, **/CLAUDE.md, **/AGENTS.md, .claude/rules/*.md, docs/rules/*.md, **/skills/*/assets/*.md, **/skills/*/references/*.md | Agent governance markdown | `pe-governance` | n/a (lint-shaped checks built into PE) |
| docs/architecture/** | ADRs (humans) | Generic | n/a (architectural-consistency review) |
| docs/code-reviews/**, docs/runbooks/**, README.md | Human-targeted docs | (skip) | n/a |
```

### 5a.1: Frontend Routing Check

Run on every row, new or existing, before showing the Stack Map:

```
server_side(f) = f is not *.config.*, *.spec.*, *.test.*, or under server/ beside a nuxt.config.* (Nitro is pe-vue's)
                 and (a path segment of f is backend/, functions/, lambda/ or server/
                      or f imports http, https, net, child_process or fs (bare or node:), express, fastify, koa,
                         hono, @nestjs/*, pg, mysql2, prisma, @prisma/*, mongoose, knex, drizzle-orm, typeorm,
                         sequelize, ioredis, ws, or any other HTTP-server framework, database or cache driver, or ORM)
for each row whose Built-in PE is pe-vue:
  hits = files under the row's paths (minus skip dirs) where server_side(f)
  if hits:
    propose a row for the hits' directories with their own stack and test command (`Generic` for Node/TS backend code)
    print in the summary: "WARNING: <row paths> routes <n> server-side files (e.g. <file>) to pe-vue —
      /code-reviewer adds a generic review for them; narrow the row to exclude <dirs>, or add <dirs> → Generic for their tests"
```

The "Built-in PE" column drives `code-reviewer` dispatch. `Generic` rows are reviewed by the parent skill directly using the listed test command (no PE sub-agent dispatch). `(skip)` rows are not reviewed. A domain row (`pe-audio`) overlaps stack rows on purpose: each file gets its stack PE plus every domain PE whose row matches.

**Audience-boundary rule for markdown:**
- Files whose audience is the model (agent definitions, skills, plugin instructions, CLAUDE.md, AGENTS.md) → `pe-governance` enforces pseudocode + schemas + literal commands + tool-permission consistency
- Files whose audience is humans (ADRs, runbooks, review docs, READMEs) → generic review or skip; prose is the right form
- Hybrid documents (e.g., ADR with embedded pseudocode flow blocks) apply the rule per-section based on each section's audience

### 5b: Summary Report

Print a summary of what was detected and where things went:

```
=== Project Initialized for Code Review ===

Stacks detected:
  - Go (pe-go):             lambdas/, pkg/
  - Vue/Nuxt (pe-vue):      frontend/
  - CDK TypeScript (pe-aws-infra):    cdk/
  - CDKTF TypeScript (pe-aws-infra):  cdktf/
  - GitHub Actions (pe-aws-infra):    .github/workflows/
  - Rust workspace (pe-rust):         engine/   (wasm32 crate: engine-wasm)
  - Audio / DSP domain (pe-audio):    engine/crates/dsp/, web/src/audio/, fixtures/audio/  (+ default globs)

Stack Map written to: {target} (or .code-reviewer.yml if preferred)

Built-in PE sub-agents that will be dispatched:
  - code-reviewer:pe-go           (ships with plugin)
  - code-reviewer:pe-vue          (ships with plugin)
  - code-reviewer:pe-rust         (ships with plugin)
  - code-reviewer:pe-aws-infra   (ships with plugin)
  - code-reviewer:pe-governance  (ships with plugin)
  - code-reviewer:pe-audio        (ships with plugin — domain PE, rides beside pe-rust / pe-vue)

Stacks NOT covered by a built-in PE:
  - {if any} Python (api/) → generic review

Routing warnings:
  - {if any} § 5a.1 warnings, one per line

Run /code-reviewer to start reviewing!
```

---

## Edge Cases

- **Monorepo with many stacks:** map every directory in the Stack Map. The
  code-reviewer skill dispatches one PE sub-agent per matched stack (suite-running
  PEs capped by `max_parallel_pes`, default 2).
- **Stack not covered by a built-in PE** (Python, Java, C#, etc.): record
  the stack + test command in the Stack Map. The code-reviewer skill falls back
  to the generic review using those test commands. Do NOT generate a
  per-project PE file — the plugin's built-in agents are the only PEs.
- **Cargo workspace below the repo root** (e.g., `engine/`): the Rust row's path
  is `<dir>/**` and every command starts `cd <dir> &&`. Emit one wasm32 build per
  WebAssembly crate.
- **Audio code inside a stack root:** keep the stack row as is and add the
  `pe-audio` domain row from § Audio Path Detection — never split the stack row.
- **No tests found:** flag it in the summary — "No test command detected for
  <stack>. Consider adding tests." Add a `# TODO` line in the Stack Map's test
  command column rather than guessing.
- **Existing Stack Map:** merge, don't overwrite. Show the user what would
  change and let them decide.
