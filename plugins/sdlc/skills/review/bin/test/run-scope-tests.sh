#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in the Stack Map printf formats are literal Markdown
# Fixture tests for scope.js — the review tier classifier and PE glob routing baseline.
# Each case builds a throwaway git repo, commits a change, and asserts the JSON scope.js prints.
# No npm packages — bash + git + node only. Ends "<n> checks, <m> failed"; exit 1 on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../scope.js"

for tool in node git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool not on PATH — cannot run scope tests" >&2
    exit 1
  fi
done
if [ ! -f "$CLI" ]; then
  echo "FAIL: scope.js not found at $CLI" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic git: no user/system config (hooks, signing, templates), fixed identity, main as the default branch.
export HOME="$TMP/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global advice.detachedHead false

total=0
fails=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }

# check <name> <json> <js-boolean-expression over `o`>
check() {
  local name="$1" json="$2" expr="$3"
  if node -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$json" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — got: $json"
  fi
}

# new_repo <dir> — a repo whose main has one commit and whose HEAD is a feature branch.
new_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  echo base > "$d/README.md"
  git -C "$d" add -A && git -C "$d" commit -qm base
  git -C "$d" checkout -qb feat/42-test
}
# put <repo> <path> <n-lines> — write a file of n lines
put() { mkdir -p "$(dirname "$1/$2")"; seq 1 "$3" | sed 's/^/line /' > "$1/$2"; }
commit() { git -C "$1" add -A && git -C "$1" commit -qm change; }
classify() { node "$CLI" classify --root "$1" --mode branch --range main...HEAD; }

# --- tier ----------------------------------------------------------------------
R="$TMP/config"; new_repo "$R"; put "$R" config/app.yml 5; commit "$R"
check "a small config-only change is TRIVIAL" "$(classify "$R")" \
  'o.tier === "TRIVIAL" && o.tier_source === "classifier" && o.signals.config_only && o.signals.size_small && o.files_changed === 1 && o.lines_added === 5'

R="$TMP/secret"; new_repo "$R"; put "$R" deploy/secrets.yml 2; commit "$R"
check "a 2-line secrets file floors at STANDARD" "$(classify "$R")" \
  'o.tier === "STANDARD" && o.signals.security_path && o.security_files.includes("deploy/secrets.yml") && o.tier_signals.includes("deploy/secrets.yml")'

R="$TMP/authsvc"; new_repo "$R"; put "$R" src/AuthService.cs 3; put "$R" docs/author.md 3; commit "$R"
check "security keywords match words, not substrings (AuthService yes, author no)" "$(classify "$R")" \
  'o.security_files.join() === "src/AuthService.cs"'

R="$TMP/compound"; new_repo "$R"
for f in infra/IAMRole.json infra/iamrole.yaml config/oauth.yml config/keyvault.json deploy/bucketpolicy.json deploy/secretsmanager.yml config/accesstoken.json config/userauth.json src/Authority.cs; do put "$R" "$f" 1; done
put "$R" docs/diagram.md 1; put "$R" docs/authors.md 1
commit "$R"
check "compound security names floor the tier; author and diagram do not" "$(classify "$R")" \
  '["infra/IAMRole.json","infra/iamrole.yaml","config/oauth.yml","config/keyvault.json","deploy/bucketpolicy.json","deploy/secretsmanager.yml","config/accesstoken.json","config/userauth.json","src/Authority.cs"].every(f => o.security_files.includes(f)) && !o.security_files.includes("docs/diagram.md") && !o.security_files.includes("docs/authors.md") && o.tier === "STANDARD"'

for f in .github/workflows/ci.yml .github/actions/setup/action.yml db/migrations/001.js deploy/security-group.yaml infra/iam.json; do
  R="$TMP/floor-${f//\//-}"; new_repo "$R"; put "$R" "$f" 3; commit "$R"
  check "a 3-line $f change floors at STANDARD" "$(classify "$R")" 'o.tier === "STANDARD" && o.signals.security_path'
done

R="$TMP/edge50"; new_repo "$R"; put "$R" a.yml 25; put "$R" b.yml 20; put "$R" c.yml 5; commit "$R"
check "50 lines across 3 config files is still TRIVIAL" "$(classify "$R")" 'o.tier === "TRIVIAL" && o.signals.size_small'
R="$TMP/edge51"; new_repo "$R"; put "$R" a.yml 51; commit "$R"
check "51 config lines is past size_small" "$(classify "$R")" 'o.tier === "STANDARD" && !o.signals.size_small'
R="$TMP/edge4"; new_repo "$R"; for i in 1 2 3 4; do put "$R" "c$i.yml" 1; done; commit "$R"
check "4 config files is past size_small" "$(classify "$R")" 'o.tier === "STANDARD" && !o.signals.size_small'

R="$TMP/rename"; new_repo "$R"; put "$R" src/old.py 300; commit "$R"
git -C "$R" branch -f main HEAD; git -C "$R" mv src/old.py src/new.py; commit "$R"
check "a pure rename counts once, under its new path" "$(classify "$R")" \
  'o.changed_files.join() === "src/new.py" && o.lines_added + o.lines_removed === 0 && o.tier !== "DEEP"'
R="$TMP/rename-secret"; new_repo "$R"; put "$R" config/secrets.yml 3; commit "$R"
git -C "$R" branch -f main HEAD; git -C "$R" mv config/secrets.yml config/app.yml; commit "$R"
check "renaming a security file away still floors the tier" "$(classify "$R")" \
  'o.signals.security_path && o.tier === "STANDARD"'

R="$TMP/deps"; new_repo "$R"; put "$R" package.json 3; commit "$R"
check "a dependency manifest floors at STANDARD" "$(classify "$R")" \
  'o.tier === "STANDARD" && o.signals.deps_or_schema'

R="$TMP/large"; new_repo "$R"; put "$R" src/big.py 400; commit "$R"
check "400 changed lines is DEEP" "$(classify "$R")" 'o.tier === "DEEP" && o.signals.size_large'

R="$TMP/many"; new_repo "$R"; for i in $(seq 1 15); do put "$R" "src/f$i.py" 1; done; commit "$R"
check "15 changed files is DEEP" "$(classify "$R")" 'o.tier === "DEEP" && o.files_changed === 15'

R="$TMP/code"; new_repo "$R"; put "$R" src/a.py 10; commit "$R"
check "a small source change is STANDARD" "$(classify "$R")" 'o.tier === "STANDARD" && !o.signals.config_only'

R="$TMP/fixtures"; new_repo "$R"; put "$R" tests/fixtures/sample.ts 5; commit "$R"
check "a non-code artifact counts as config-only" "$(classify "$R")" 'o.tier === "TRIVIAL"'

# --- exclusion -----------------------------------------------------------------
R="$TMP/review-only"; new_repo "$R"; put "$R" docs/code-reviews/42-code-review.md 50; commit "$R"
out="$(classify "$R")"; code=$?
if [ "$code" -eq 3 ]; then pass "a review-doc-only diff exits 3 (nothing to review)"; else fail "review-doc-only diff exit $code"; fi
check "the stop reason names the excluded files" "$out" 'o.stop === "only excluded files changed — nothing to review" && o.excluded.includes("docs/code-reviews/42-code-review.md")'

R="$TMP/empty-index"; new_repo "$R"
out="$(node "$CLI" classify --root "$R" --mode staged)"; code=$?
if [ "$code" -eq 3 ]; then pass "an empty index exits 3 (nothing to review)"; else fail "empty index exit $code"; fi
check "an empty index says nothing is staged, not excluded" "$out" 'o.stop === "nothing staged — nothing to review" && o.excluded.length === 0'
R="$TMP/no-commits"; new_repo "$R"
check "a branch with no commits says no changes" "$(classify "$R")" 'o.stop === "no changes against the base — nothing to review"'

R="$TMP/mixed"; new_repo "$R"; put "$R" docs/code-reviews/42-code-review.md 500; put "$R" src/a.py 4; commit "$R"
check "excluded files never inflate the counts or tier" "$(classify "$R")" \
  'o.changed_files.join() === "src/a.py" && o.lines_added === 4 && o.tier === "STANDARD" && o.excluded.length === 1'

# --- routing -------------------------------------------------------------------
R="$TMP/route"; new_repo "$R"
put "$R" api/Search.cs 1; put "$R" db/sprocs/usp_Find.sql 1; put "$R" .github/workflows/ci.yml 1; put "$R" svc/main.go 1
put "$R" .github/actions/setup/action.yml 1; put "$R" action.yml 1; put "$R" ci/workflows/build.yml 1
put "$R" web/App.vue 1; put "$R" infra/main.tf 1; put "$R" plugins/x/skills/y/SKILL.md 1; put "$R" plugins/x/README.md 1
put "$R" README.md 2; put "$R" scripts/run.sh 1; put "$R" plugins/x/references/style.md 1; put "$R" plugins/x/assets/t.md 1
put "$R" .claude/rules/a/b.md 1; put "$R" Dockerfile.api 1
put "$R" plugins/x/agents/a.md 1; put "$R" plugins/x/commands/c.md 1
put "$R" CLAUDE.md 1; put "$R" persona.code.md 1
put "$R" AGENTS.md 1; put "$R" svc/AGENTS.md 1; put "$R" .github/copilot-instructions.md 1
put "$R" .github/instructions/go.instructions.md 1; put "$R" .github/instructions/backend/api.instructions.md 1
put "$R" .github/instructions/notes.md 1
mkdir -p "$R/ng"; echo '{}' > "$R/ng/angular.json"; put "$R" ng/src/app/a.component.ts 1; put "$R" ng/src/app/a.component.html 1
put "$R" tools/plain.ts 1
commit "$R"
out="$(classify "$R")"
check "stack globs route to their specialist" "$out" \
  'o.routing["api/Search.cs"] === "pe-csharp" && o.routing["db/sprocs/usp_Find.sql"] === "pe-sql-server" && o.routing[".github/workflows/ci.yml"] === "pe-github-actions" && o.routing["svc/main.go"] === "pe-go" && o.routing["web/App.vue"] === "pe-vue" && o.routing["infra/main.tf"] === "pe-aws-infra" && o.routing["Dockerfile.api"] === "pe-aws-infra"'
check "GitHub Actions workflows, local actions, and action metadata route to pe-github-actions" "$out" \
  '[".github/workflows/ci.yml",".github/actions/setup/action.yml","action.yml"].every(f => o.routing[f] === "pe-github-actions")'
check "a workflow-like file outside .github/workflows is not claimed" "$out" 'o.routing["ci/workflows/build.yml"] === "pe-general-purpose"'
check "governance globs route to pe-governance (root and nested)" "$out" \
  '["plugins/x/skills/y/SKILL.md","plugins/x/README.md","plugins/x/references/style.md","plugins/x/assets/t.md",".claude/rules/a/b.md","plugins/x/agents/a.md","plugins/x/commands/c.md","CLAUDE.md","persona.code.md"].every(f => o.routing[f] === "pe-governance")'
check "AGENTS.md and Copilot instruction files route to pe-governance" "$out" \
  '["AGENTS.md","svc/AGENTS.md",".github/copilot-instructions.md",".github/instructions/go.instructions.md",".github/instructions/backend/api.instructions.md"].every(f => o.routing[f] === "pe-governance") && o.routing[".github/instructions/notes.md"] === "pe-general-purpose"'
check "the repo-root README and unmatched files fall back to pe-general-purpose" "$out" \
  'o.routing["README.md"] === "pe-general-purpose" && o.routing["scripts/run.sh"] === "pe-general-purpose"'
check "*.ts under an Angular project routes to pe-angular; elsewhere it does not" "$out" \
  'o.routing["ng/src/app/a.component.ts"] === "pe-angular" && o.routing["ng/src/app/a.component.html"] === "pe-angular" && o.routing["tools/plain.ts"] === "pe-general-purpose"'
# matched_pes == unique(routing values) ∪ keys(domain_pes), each once
UNION='o.changed_files.every(f => typeof o.routing[f] === "string") && [...new Set(o.matched_pes)].sort().join() === [...new Set([...Object.values(o.routing), ...Object.keys(o.domain_pes)])].sort().join() && new Set(o.matched_pes).size === o.matched_pes.length'
check "every changed file has exactly one stack PE and matched_pes is the stack and domain union" "$out" "$UNION"

check "every matched PE is one sdlc ships" "$out" \
  'o.routing["db/sprocs/usp_Find.sql"] === "pe-sql-server" && !o.matched_pes.some(p => !/^pe-(csharp|angular|sql-server|github-actions|go|rust|vue|aws-infra|devtools|governance|general-purpose|audio)$/.test(p))'
check "no audio path, no domain PE" "$out" 'Object.keys(o.domain_pes).length === 0 && !o.matched_pes.includes("pe-audio")'

# --- Rust and dev tooling ------------------------------------------------------
R="$TMP/rust"; new_repo "$R"
for f in engine/src/lib.rs engine/build.rs Cargo.toml engine/Cargo.toml Cargo.lock rust-toolchain rust-toolchain.toml .cargo/config.toml engine/.cargo/config.toml; do put "$R" "$f" 1; done
put "$R" .cargo/credentials.toml 1; put "$R" docs/Cargo.toml.md 1
commit "$R"
out="$(classify "$R")"
check "Rust sources, manifests, toolchain files, and .cargo/config.toml route to pe-rust" "$out" \
  '["engine/src/lib.rs","engine/build.rs","Cargo.toml","engine/Cargo.toml","Cargo.lock","rust-toolchain","rust-toolchain.toml",".cargo/config.toml","engine/.cargo/config.toml"].every(f => o.routing[f] === "pe-rust")'
check "other .cargo files and Cargo-named docs are not pe-rust's" "$out" \
  'o.routing[".cargo/credentials.toml"] === "pe-general-purpose" && o.routing["docs/Cargo.toml.md"] === "pe-general-purpose"'
R="$TMP/cargo-manifest"; new_repo "$R"; put "$R" Cargo.toml 3; commit "$R"
check "a Cargo.toml change floors at STANDARD as a dependency manifest" "$(classify "$R")" \
  'o.tier === "STANDARD" && o.signals.deps_or_schema && o.signals.security_path'

R="$TMP/devtools"; new_repo "$R"
for f in scripts/dev/fmt.sh scripts/dev/bootstrap scripts/dev/lib/util.py scripts/dev/seed.ts .githooks/pre-commit tools/.githooks/pre-push \
         .husky/pre-commit lefthook.yml lefthook-local.yml .lefthook.yaml .cargo/config; do put "$R" "$f" 1; done
mkdir -p "$R/scripts/ci" "$R/scripts/release" "$R/scripts/local"
printf '#!/usr/bin/env bash\n# Format staged files.\n#pe:devtools\n' > "$R/scripts/local/fmt.sh"
printf '#!/usr/bin/env bash\r\n# pe: devtools\r\n' > "$R/scripts/local/crlf.sh"
printf '#!/usr/bin/env bash\n# pe: devtools-ish\n' > "$R/scripts/ci/near-miss.sh"
{ printf '#!/usr/bin/env bash\n'; seq 1 10 | sed 's/^/# line /'; printf '# pe: devtools\n'; } > "$R/scripts/release/late.sh"
printf '# pe: devtools\n' > "$R/scripts/release/notes.txt"
printf '#!/usr/bin/env bash\n# pe: devtools\n' > "$R/tools/dev.sh"
put "$R" scripts/dev/main.go 1
commit "$R"
out="$(classify "$R")"
check "scripts/dev shell and extensionless scripts, .githooks, .husky, and lefthook config route to pe-devtools" "$out" \
  '["scripts/dev/fmt.sh","scripts/dev/bootstrap",".githooks/pre-commit","tools/.githooks/pre-push",".husky/pre-commit","lefthook.yml","lefthook-local.yml",".lefthook.yaml"].every(f => o.routing[f] === "pe-devtools")'
check "a non-shell script under scripts/dev keeps its own reviewer" "$out" \
  'o.routing["scripts/dev/lib/util.py"] === "pe-general-purpose" && o.routing["scripts/dev/seed.ts"] === "pe-general-purpose"'
check "the extensionless .cargo/config routes to pe-rust" "$out" 'o.routing[".cargo/config"] === "pe-rust"'
check "a scripts/**/*.sh with a # pe: devtools header line routes to pe-devtools (CRLF too)" "$out" \
  'o.routing["scripts/local/fmt.sh"] === "pe-devtools" && o.routing["scripts/local/crlf.sh"] === "pe-devtools"'
check "a near-miss header, a header past line 10, a non-.sh file, or a script outside scripts/ stays with pe-general-purpose" "$out" \
  '["scripts/ci/near-miss.sh","scripts/release/late.sh","scripts/release/notes.txt","tools/dev.sh"].every(f => o.routing[f] === "pe-general-purpose")'
check "a language specialist outranks pe-devtools inside scripts/dev" "$out" 'o.routing["scripts/dev/main.go"] === "pe-go"'
R="$TMP/devtools-deleted"; new_repo "$R"; mkdir -p "$R/scripts"; printf '# pe: devtools\n' > "$R/scripts/gone.sh"; commit "$R"
git -C "$R" branch -f main HEAD; git -C "$R" rm -q scripts/gone.sh; put "$R" src/a.py 1; commit "$R"
check "a deleted headed script has no header to read and falls back to pe-general-purpose" "$(classify "$R")" \
  'o.routing["scripts/gone.sh"] === "pe-general-purpose"'
# The header is read from the content under review, never from unstaged or uncommitted edits.
R="$TMP/devtools-rev"; new_repo "$R"; mkdir -p "$R/scripts"
printf '#!/usr/bin/env bash\n# pe: devtools\n' > "$R/scripts/a.sh"; printf '#!/usr/bin/env bash\n' > "$R/scripts/b.sh"
git -C "$R" add -A
printf '#!/usr/bin/env bash\n' > "$R/scripts/a.sh"; printf '#!/usr/bin/env bash\n# pe: devtools\n' > "$R/scripts/b.sh"
check "staged mode reads the header from the index" "$(node "$CLI" classify --root "$R" --mode staged)" \
  'o.routing["scripts/a.sh"] === "pe-devtools" && o.routing["scripts/b.sh"] === "pe-general-purpose"'
git -C "$R" add -A; git -C "$R" commit -qm change; printf '#!/usr/bin/env bash\n' > "$R/scripts/b.sh"
check "branch mode reads the header from HEAD" "$(classify "$R")" 'o.routing["scripts/b.sh"] === "pe-devtools"'

# --- vite.config / webmanifest: pe-vue only in a Vue project -------------------
R="$TMP/vite"; new_repo "$R"
mkdir -p "$R/app" "$R/react"; printf '{"dependencies":{"vue":"^3.4.0"}}\n' > "$R/app/package.json"
printf '{"dependencies":{"react":"^18.0.0"}}\n' > "$R/react/package.json"
put "$R" app/vite.config.ts 1; put "$R" app/public/site.webmanifest 1; put "$R" react/vite.config.ts 1; put "$R" app/src/db.ts 1
commit "$R"; out="$(classify "$R")"
check "vite.config and webmanifest route to pe-vue under a package.json depending on vue" "$out" \
  'o.routing["app/vite.config.ts"] === "pe-vue" && o.routing["app/public/site.webmanifest"] === "pe-vue"'
check "a non-Vue vite.config and a standalone storage module stay with pe-general-purpose" "$out" \
  'o.routing["react/vite.config.ts"] === "pe-general-purpose" && o.routing["app/src/db.ts"] === "pe-general-purpose"'

# --- domain PEs ----------------------------------------------------------------
R="$TMP/audio"; new_repo "$R"
put "$R" web/src/audio/Tuner.vue 1; put "$R" engine/crates/pitch/src/yin.rs 1; put "$R" web/src/lib/PitchWorklet.ts 1
put "$R" web/src/lib/drone-worklet.mjs 1; put "$R" web/src/components/Settings.vue 1; put "$R" web/src/lib/audioUtils.ts 1
put "$R" web/src/audio/Tuner.tsx 1; put "$R" src/lib/pitch-worklet.cjs 1
put "$R" crates/audio-engine/src/lib.rs 1; put "$R" engine/crates/audio-dsp/src/yin.rs 1; put "$R" src/Audio/Graph.ts 1
put "$R" src/audiobook-store/cart.ts 1; put "$R" src/dispatch/queue.ts 1
commit "$R"
out="$(classify "$R")"
check "an audio-path file gets pe-audio and keeps its stack PE" "$out" \
  'o.routing["web/src/audio/Tuner.vue"] === "pe-vue" && o.domain_pes["pe-audio"].kind === "domain" && o.domain_pes["pe-audio"].files.includes("web/src/audio/Tuner.vue") && o.domain_pes["pe-audio"].files.includes("engine/crates/pitch/src/yin.rs") && o.matched_pes.includes("pe-vue") && o.matched_pes.includes("pe-audio")'
check "worklet files match pe-audio in any directory" "$out" \
  'o.domain_pes["pe-audio"].files.includes("web/src/lib/PitchWorklet.ts") && o.domain_pes["pe-audio"].files.includes("web/src/lib/drone-worklet.mjs") && o.routing["web/src/lib/PitchWorklet.ts"] === "pe-general-purpose"'
check "a non-audio file gets only its stack PE" "$out" \
  'o.routing["web/src/components/Settings.vue"] === "pe-vue" && !o.domain_pes["pe-audio"].files.includes("web/src/components/Settings.vue") && !o.domain_pes["pe-audio"].files.includes("web/src/lib/audioUtils.ts")'
check "a domain PE never takes a file out of routing" "$out" \
  'o.changed_files.every(f => typeof o.routing[f] === "string" && o.routing[f] !== "pe-audio")'
check "tsx and cjs sources match pe-audio" "$out" \
  '["web/src/audio/Tuner.tsx","src/lib/pitch-worklet.cjs"].every(f => o.domain_pes["pe-audio"].files.includes(f))'
check "an audio directory matches as a whole word in any case" "$out" \
  '["crates/audio-engine/src/lib.rs","engine/crates/audio-dsp/src/yin.rs","src/Audio/Graph.ts"].every(f => o.domain_pes["pe-audio"].files.includes(f)) && o.routing["crates/audio-engine/src/lib.rs"] === "pe-rust"'
check "a directory word that only contains audio or dsp does not match" "$out" \
  '!["src/audiobook-store/cart.ts","src/dispatch/queue.ts"].some(f => o.domain_pes["pe-audio"].files.includes(f))'
check "matched_pes is the stack and domain union on an audio change" "$out" "$UNION"

# --- Stack Map -----------------------------------------------------------------
# on_main <repo> — commit and make that commit the base, so the Stack Map is read from main.
on_main() { commit "$1"; git -C "$1" branch -f main HEAD; }
HDR='| Path | Stack | Built-in PE | Test Command |
| - | - | - | - |'
R="$TMP/map"; new_repo "$R"
cat > "$R/AGENTS.md" <<EOF
# Agents

## Stack Map

$HDR
| gen/**/*.go | Generated Go | Generic | \`make gen-check\` |
| lib/special/** | Rust bindings | \`sdlc:pe-rust\` | \`cargo test -p special\` |
| lib/** | Go | \`code-reviewer:pe-go\` | \`go vet ./...\`, \`go test ./lib/...\` |
| lib/special/old/** | Old | (skip) | n/a |
| vendor/**, README.md | Third party | (skip) | n/a |
| frontend/ | Vue | pe-vue | \`cd frontend && npm test\` |
| ops/** | Python | pe-python | \`pytest\` |
| engine/{synth,fx}/** | Audio (domain) | pe-audio | n/a (stack PE runs suites) |
| docs/adr/** | ADRs | pe-general-purpose | # TODO |
| | Empty | pe-go | |
EOF
on_main "$R"
put "$R" gen/api/types.go 1; put "$R" lib/special/bind.go 1; put "$R" lib/core.go 1; put "$R" lib/special/old/x.go 1
put "$R" vendor/dep/a.go 1; put "$R" README.md 3; put "$R" docs/README.md 1; put "$R" frontend/server.ts 1; put "$R" apps/frontend/main.go 1
put "$R" ops/run.py 1; put "$R" engine/synth/osc.rs 1; put "$R" engine/fx/delay.rs 1; put "$R" web/src/audio/Tuner.vue 1
put "$R" docs/adr/0001.md 1; put "$R" svc/main.go 1
commit "$R"
out="$(classify "$R")"
check "a Stack Map row wins over the built-in glob (Generic is pe-general-purpose; sdlc: and code-reviewer: prefixes)" "$out" \
  'o.routing["gen/api/types.go"] === "pe-general-purpose" && o.routing["lib/special/bind.go"] === "pe-rust" && o.routing["frontend/server.ts"] === "pe-vue" && o.routing["svc/main.go"] === "pe-go"'
check "Stack Map rows match in table order: an earlier row wins over a later (skip)" "$out" \
  'o.routing["lib/core.go"] === "pe-go" && o.routing["lib/special/old/x.go"] === "pe-rust" && !o.excluded.includes("lib/special/old/x.go")'
check "Stack Map paths anchor at the repo root unless they have no slash" "$out" \
  'o.routing["apps/frontend/main.go"] === "pe-go" && o.excluded.includes("docs/README.md")'
check "a (skip) row excludes its files like docs/code-reviews" "$out" \
  '["vendor/dep/a.go","README.md"].every(f => o.excluded.includes(f) && !o.changed_files.includes(f) && !(f in o.routing)) && o.lines_added === 12'
check "a domain-PE row adds files to domain_pes, keeps the default globs, and never routes" "$out" \
  '["engine/synth/osc.rs","engine/fx/delay.rs","web/src/audio/Tuner.vue"].every(f => o.domain_pes["pe-audio"].files.includes(f)) && o.routing["engine/synth/osc.rs"] === "pe-rust" && !Object.values(o.routing).includes("pe-audio")'
check "an unknown PE row is ignored with a note" "$out" \
  'o.routing["ops/run.py"] === "pe-general-purpose" && o.stack_map_notes.some(n => n.includes("row 7") && n.includes("unknown PE \"pe-python\"")) && o.stack_map_notes.some(n => n.includes("row 10") && n.includes("no paths"))'
check "stack_commands lists each PE's commands from the rows that routed a changed file" "$out" \
  'Object.keys(o.stack_commands).sort().join() === "pe-general-purpose,pe-go,pe-rust,pe-vue" && o.stack_commands["pe-go"].join("|") === "go vet ./...|go test ./lib/..." && o.stack_commands["pe-general-purpose"].join() === "make gen-check" && o.stack_commands["pe-rust"].join() === "cargo test -p special" && o.stack_commands["pe-vue"].join() === "cd frontend && npm test"'
check "stack_map names the file and the revision it was read from" "$out" \
  'o.stack_map.file === "AGENTS.md" && o.stack_map.from === "main" && o.stack_map.rows === 8'
git -C "$R" branch -f main HEAD; put "$R" vendor/dep/b.go 1; commit "$R"
classify "$R" >/dev/null; code=$?
if [ "$code" -eq 3 ]; then pass "a diff of only (skip) files exits 3"; else fail "skip-only diff exit $code"; fi

# The map is read from the range's base: a change cannot skip or re-route its own files.
R="$TMP/map-base"; new_repo "$R"
printf '## Stack Map\n\n%s\n| src/** | Go | pe-go | `go test ./...` |\n' "$HDR" > "$R/AGENTS.md"; on_main "$R"
printf '## Stack Map\n\n%s\n| src/** | Hidden | (skip) | n/a |\n' "$HDR" > "$R/AGENTS.md"; put "$R" src/a.py 2; commit "$R"
check "branch mode reads the Stack Map from the base, not the change" "$(classify "$R")" \
  'o.routing["src/a.py"] === "pe-go" && !o.excluded.includes("src/a.py") && o.stack_map_notes.some(n => n.includes("apply once merged"))'
R2="$TMP/map-new"; new_repo "$R2"
printf '## Stack Map\n\n%s\n| src/** | Hidden | (skip) | n/a |\n' "$HDR" > "$R2/AGENTS.md"; put "$R2" src/a.py 2; commit "$R2"
check "a Stack Map added by the change applies once merged, with a note" "$(classify "$R2")" \
  'o.stack_map === null && o.routing["src/a.py"] === "pe-general-purpose" && o.stack_map_notes.some(n => n.includes("apply once merged"))'
check "files mode reads the working-tree Stack Map" "$(node "$CLI" classify --root "$R" --mode files --targets src,AGENTS.md)" \
  'o.excluded.join() === "src/a.py" && o.stack_map.from === "worktree"'

R="$TMP/map-imports"; new_repo "$R"
printf '@AGENTS.md\n' > "$R/CLAUDE.md"; printf '## Stack Map\n\n%s\n| src/** | Go | pe-go | n/a |\n' "$HDR" > "$R/AGENTS.md"; on_main "$R"
put "$R" src/a.py 1; commit "$R"
check "a CLAUDE.md that only imports @AGENTS.md reads AGENTS.md's Stack Map" "$(classify "$R")" \
  'o.stack_map.file === "AGENTS.md" && o.routing["src/a.py"] === "pe-go" && Object.keys(o.stack_commands).length === 0'
R="$TMP/map-both"; new_repo "$R"
printf '# Project\n@AGENTS.md\n\n## Stack Map\n\n%s\n| src/** | Rust | pe-rust | n/a |\n' "$HDR" > "$R/CLAUDE.md"
printf '## Stack Map\n\n%s\n| src/** | Go | pe-go | n/a |\n' "$HDR" > "$R/AGENTS.md"; on_main "$R"
put "$R" src/a.py 1; commit "$R"
check "CLAUDE.md's Stack Map wins over AGENTS.md's when CLAUDE.md is not import-only" "$(classify "$R")" \
  'o.stack_map.file === "CLAUDE.md" && o.routing["src/a.py"] === "pe-rust"'

R="$TMP/map-malformed"; new_repo "$R"
printf '## Stack Map\n\n| Path | PE |\n| src/** | pe-go |\n' > "$R/CLAUDE.md"
printf '```md\n## Stack Map\n\n%s\n| src/** | Go | pe-go | n/a |\n```\n' "$HDR" > "$R/AGENTS.md"; on_main "$R"
put "$R" src/a.go 1; put "$R" src/b.py 1; commit "$R"
check "a table with no separator row, or one inside a code fence, is no Stack Map, with a note" "$(classify "$R")" \
  'o.stack_map === null && o.routing["src/b.py"] === "pe-general-purpose" && o.routing["src/a.go"] === "pe-go" && o.stack_map_notes.join().includes("CLAUDE.md: Stack Map ignored") && Object.keys(o.stack_commands).length === 0'
R="$TMP/map-nopecol"; new_repo "$R"
printf '## Stack Map\n\n| Path | Stack |\n| - | - |\n| src/** | Go |\n' > "$R/CLAUDE.md"
printf '## Stack Map\n\n%s\n| src/** | Go | pe-go | n/a |\n' "$HDR" > "$R/AGENTS.md"; on_main "$R"
put "$R" src/b.py 1; commit "$R"
check "a table with no PE column falls through to the next instruction file" "$(classify "$R")" \
  'o.stack_map.file === "AGENTS.md" && o.routing["src/b.py"] === "pe-go" && o.stack_map_notes.some(n => n.includes("no Path or PE column"))'
R="$TMP/map-none"; new_repo "$R"; put "$R" src/b.py 1; commit "$R"
check "no instruction file means no Stack Map and no notes" "$(classify "$R")" \
  'o.stack_map === null && o.stack_map_notes.length === 0 && Object.keys(o.stack_commands).length === 0'

# --- files-mode targets --------------------------------------------------------
R="$TMP/targets"; new_repo "$R"
put "$R" infra/templates/web.tf 3; put "$R" src/app.py 2; commit "$R"
out="$(node "$CLI" classify --root "$R" --mode files --targets ./infra/templates/web.tf)"
check "files mode normalizes a ./-prefixed file target before routing" "$out" \
  'o.changed_files.join() === "infra/templates/web.tf" && o.routing["infra/templates/web.tf"] === "pe-aws-infra"'
out="$(node "$CLI" classify --root "$R" --mode files --targets infra//templates/web.tf)"
check "files mode normalizes a doubled slash in a file target" "$out" 'o.routing["infra/templates/web.tf"] === "pe-aws-infra"'
node "$CLI" classify --root "$R" --mode files --targets ../outside.yaml >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "files mode rejects a target outside the root"; else fail "outside target exit $code"; fi
for target in . ./; do
  out="$(node "$CLI" classify --root "$R" --mode files --targets "$target")"
  check "files mode reviews the whole repo for target '$target'" "$out" \
    'o.changed_files.includes("src/app.py") && o.routing["infra/templates/web.tf"] === "pe-aws-infra"'
done
put "$R" ..notes.txt 1
out="$(node "$CLI" classify --root "$R" --mode files --targets ..notes.txt)"
check "files mode accepts an in-repo name that starts with '..'" "$out" 'o.changed_files.join() === "..notes.txt"'

# --- modes ---------------------------------------------------------------------
R="$TMP/staged"; new_repo "$R"; put "$R" src/a.py 7; git -C "$R" add -A
out="$(node "$CLI" classify --root "$R" --mode staged)"
check "staged mode reviews the index and never writes the branch ledger" "$out" \
  'o.changed_files.join() === "src/a.py" && o.lines_added === 7 && o.diff_cmd === "git diff --cached" && o.ledger === false'

R="$TMP/files"; new_repo "$R"; put "$R" src/a.py 12; put "$R" src/lib/b.py 3; put "$R" other/c.py 1; commit "$R"
out="$(node "$CLI" classify --root "$R" --mode files --targets src/a.py,src/lib)"
check "files mode expands folders, counts file lines, and binds no diff" "$out" \
  'o.changed_files.join() === "src/a.py,src/lib/b.py" && o.lines_added === 15 && o.diff_cmd === null'
check "files mode never writes the branch ledger" "$out" 'o.ledger === false'
R="$TMP/untracked"; new_repo "$R"; put "$R" mixed/t.py 2; commit "$R"; put "$R" mixed/new.py 3; put "$R" fresh/a.py 4
echo "ignored.log" > "$R/.gitignore"; put "$R" mixed/ignored.log 1
out="$(node "$CLI" classify --root "$R" --mode files --targets mixed,fresh)"
check "files mode includes untracked, non-ignored files in a folder" "$out" \
  '[...o.changed_files].sort().join() === "fresh/a.py,mixed/new.py,mixed/t.py"'
R="$TMP/deleted"; new_repo "$R"; put "$R" src/a.py 2; put "$R" src/b.py 2; commit "$R"; rm "$R/src/b.py"
check "files mode skips a tracked file deleted in the working tree" "$(node "$CLI" classify --root "$R" --mode files --targets src)" \
  'o.changed_files.join() === "src/a.py"'
mkdir -p "$R/empty"
node "$CLI" classify --root "$R" --mode files --targets empty >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "files mode with a folder of no reviewable files exits 2"; else fail "empty folder exit $code"; fi
node "$CLI" classify --root "$R" --mode files --targets nope.py >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "files mode with a missing target exits 2"; else fail "missing target exit $code"; fi

out="$(node "$CLI" classify --root "$R" --mode adhoc --adhoc-lines 20)"
check "ad-hoc mode routes pasted code to pe-general-purpose without a diff or ledger" "$out" \
  'o.matched_pes.join() === "pe-general-purpose" && o.diff_cmd === null && o.ledger === false && o.tier === "STANDARD"'

R="$TMP/pr"; new_repo "$R"; put "$R" src/a.py 2; commit "$R"
out="$(node "$CLI" classify --root "$R" --mode pr --range main...HEAD)"
# Git Bash converts path arguments before calling native Node on Windows.
pr_root="$(node -p 'process.argv[1]' "$R")"
check "pr mode binds a review-root diff command and keeps the ledger" "$out" \
  "o.diff_cmd === 'git -C \"$pr_root\" diff main...HEAD' && o.ledger === true"

node "$CLI" classify --root "$R" --mode branch >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "branch mode without --range exits 2"; else fail "branch mode without range exit $code"; fi

# --- pe-tiers ------------------------------------------------------------------
pt() { node "$CLI" pe-tiers <<<"$1"; }
check "a PE whose files are all non-code artifacts runs TRIVIAL" \
  "$(pt '{"tier":"STANDARD","routing":{"a.postman_collection.json":"pe-general-purpose","src/A.cs":"pe-csharp"},"content_risk_files":[]}')" \
  'o["pe-general-purpose"] === "TRIVIAL" && o["pe-csharp"] === "STANDARD"'
check "a content-risk or security artifact keeps the round tier" \
  "$(pt '{"tier":"DEEP","routing":{"fixtures/a.json":"pe-general-purpose","fixtures/token.json":"pe-sql-server"},"content_risk_files":["fixtures/a.json"]}')" \
  'o["pe-general-purpose"] === "DEEP" && o["pe-sql-server"] === "DEEP"'

echo "=================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] && [ "$fails" -eq 0 ]
