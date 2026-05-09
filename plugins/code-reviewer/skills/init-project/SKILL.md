---
name: init-project
description: Scan the project and write a Stack Map to CLAUDE.md for /code-reviewer. Detects languages, frameworks, test commands. PEs (pe-go, pe-vue, pe-aws-infra, pe-governance, pe-devtools) ship with the plugin.
---

# Initialize Project for Code Review

Bootstraps the `/code-reviewer` skill into any project by scanning the repo
and writing a Stack Map into the project's `CLAUDE.md` (or `.code-reviewer.yml`).

The five built-in PE sub-agents — `code-reviewer:pe-go`,
`code-reviewer:pe-vue`, `code-reviewer:pe-aws-infra`,
`code-reviewer:pe-governance`, `code-reviewer:pe-devtools` — ship with
the plugin as proper agents. This skill does NOT regenerate them. For
stacks not covered by a built-in PE (Rust, Python, Java, C#, etc.), the
code-reviewer skill falls back to a generic three-pass review using the
Stack Map's test commands.

---

## Phase 1: Detect Stacks

Scan the repository for language markers, build files, and framework configs.

### Language Detection

The "Built-in PE" column maps a detected stack to one of the five plugin-shipped agents (`pe-go`, `pe-vue`, `pe-aws-infra`, `pe-governance`, `pe-devtools`). "Generic" means no built-in agent matches — code-reviewer falls back to a generic three-pass review for that stack.

| Marker | Stack | Built-in PE |
| --- | --- | --- |
| `go.mod`, `*.go` | Go | `pe-go` |
| `package.json` + `*.vue` | Vue/Nuxt | `pe-vue` |
| `package.json` + `*.tsx`/`*.jsx` | React | `pe-vue` |
| `package.json` + `*.svelte` | Svelte | `pe-vue` |
| `cdk.json`, `*.ts` in `cdk/` or `infra/` | AWS CDK | `pe-aws-infra` |
| `cdktf.json` | CDKTF | `pe-aws-infra` |
| `*.tf` | Terraform | `pe-aws-infra` |
| `Dockerfile*`, `docker-compose*` | Docker | `pe-aws-infra` |
| `.github/workflows/*.yml` | GitHub Actions CI/CD | `pe-aws-infra` |
| `.gitlab-ci.yml` | GitLab CI/CD | `pe-aws-infra` |
| `Cargo.toml`, `*.rs` | Rust | Generic |
| `pyproject.toml`, `requirements.txt`, `*.py` | Python | Generic |
| `*.java`, `pom.xml`, `build.gradle` | Java | Generic |
| `*.cs`, `*.csproj`, `*.sln` | C# / .NET | Generic |
| `.claude/agents/*.md`, `**/SKILL.md`, `plugins/**/agents/*.md`, `**/CLAUDE.md`, `.claude/rules/*.md`, `docs/rules/*.md` | Agent governance markdown | `pe-governance` |
| `scripts/dev/**/*.sh`, `scripts/**/*.sh` with `# pe: devtools` header, `.githooks/**`, `lefthook.yml` | Local dev tooling (single-operator threat model) | `pe-devtools` |

### Framework Detection

Dig deeper into detected stacks to identify frameworks:

| Indicator | Framework |
| - | - |
| `nuxt.config.*` | Nuxt 3 |
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
| React | `package.json` scripts | `npm test` |
| CDK | `package.json` in cdk dir | `cd <dir> && npm test && npx cdk synth --all` |
| CDKTF | `package.json` in cdktf dir | `cd <dir> && npm test && npx cdktf synth` |
| Terraform | `*.tf` | `terraform validate` |
| Rust | `Cargo.toml` | `cargo test` |
| Python | `pyproject.toml` / `requirements.txt` | `pytest` |
| Java (Maven) | `pom.xml` | `mvn test` |
| Java (Gradle) | `build.gradle` | `./gradlew test` |
| C# | `*.sln` | `dotnet test` |
| Docker | `Dockerfile` | `docker build --target test` (if multi-stage) |

**Override from package.json:** If `package.json` exists, read `scripts` for
`test`, `typecheck`, `lint`, `build` — use actual script names, not defaults.

---

## Phase 4: Check for Existing CLAUDE.md

Read the project's `CLAUDE.md` (if it exists) for:
- Existing project structure documentation
- Team structure or review chain information
- Coding standards or conventions
- Any Stack Map already defined

If a Stack Map already exists, offer to update it rather than overwriting.

---

## Phase 5: Generate Output

### 5a: Stack Map

Generate a Stack Map table and prompt the user to add it to their `CLAUDE.md`:

```markdown
## Stack Map

| Path | Stack | Built-in PE | Test Command |
| --- | --- | --- | --- |
| lambdas/**, pkg/** | Go | `pe-go` | `go vet ./... && go test ./... -count=1 -race` |
| frontend/** | Vue/Nuxt | `pe-vue` | `cd frontend && npm run typecheck && npm test` |
| cdk/** | CDK TypeScript | `pe-aws-infra` | `cd cdk && npm test && npx cdk synth --all` |
| api/** | Python | Generic | `cd api && pytest` |
| .claude/agents/**, **/SKILL.md, plugins/**/agents/*.md, **/CLAUDE.md, .claude/rules/*.md, docs/rules/*.md | Agent governance markdown | `pe-governance` | n/a (lint-shaped checks built into PE) |
| docs/architecture/** | ADRs (humans) | Generic | n/a (architectural-consistency review) |
| docs/code-reviews/**, docs/runbooks/**, README.md | Human-targeted docs | (skip) | n/a |
```

The "Built-in PE" column drives `code-reviewer` dispatch. `Generic` rows are reviewed by the parent skill directly using the listed test command (no PE sub-agent dispatch). `(skip)` rows are not reviewed.

**Audience-boundary rule for markdown:**
- Files whose audience is the model (agent definitions, skills, plugin instructions, CLAUDE.md) → `pe-governance` enforces pseudocode + schemas + literal commands + tool-permission consistency
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

Stack Map written to: CLAUDE.md (or .code-reviewer.yml if preferred)

Built-in PE sub-agents that will be dispatched:
  - code-reviewer:pe-go           (ships with plugin)
  - code-reviewer:pe-vue          (ships with plugin)
  - code-reviewer:pe-aws-infra   (ships with plugin)
  - code-reviewer:pe-governance  (ships with plugin)

Stacks NOT covered by a built-in PE:
  - {if any} Python (api/), Rust (engine/) → generic three-pass review

Run /code-reviewer to start reviewing!
```

---

## Edge Cases

- **Monorepo with many stacks:** map every directory in the Stack Map. The
  code-reviewer skill dispatches one PE sub-agent per matched stack in parallel.
- **Stack not covered by a built-in PE** (Rust, Python, Java, C#, etc.): record
  the stack + test command in the Stack Map. The code-reviewer skill falls back
  to a generic three-pass review using those test commands. Do NOT generate a
  per-project PE file — the plugin's three built-in agents are the only PEs.
- **No tests found:** flag it in the summary — "No test command detected for
  <stack>. Consider adding tests." Add a `# TODO` line in the Stack Map's test
  command column rather than guessing.
- **Existing Stack Map:** merge, don't overwrite. Show the user what would
  change and let them decide.
