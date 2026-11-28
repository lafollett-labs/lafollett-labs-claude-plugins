#!/usr/bin/env bash
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
check "every changed file has exactly one PE and matched_pes is their union" "$out" \
  'o.changed_files.every(f => typeof o.routing[f] === "string") && new Set(Object.values(o.routing)).size === o.matched_pes.length'

check "every matched PE is one sdlc ships" "$out" \
  'o.routing["db/sprocs/usp_Find.sql"] === "pe-sql-server" && !o.matched_pes.some(p => !/^pe-(csharp|angular|sql-server|github-actions|go|rust|vue|aws-infra|devtools|governance|general-purpose)$/.test(p))'

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
for f in scripts/dev/fmt.sh scripts/dev/lib/util.py .githooks/pre-commit tools/.githooks/pre-push lefthook.yml; do put "$R" "$f" 1; done
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
check "scripts/dev, .githooks, and lefthook.yml route to pe-devtools" "$out" \
  '["scripts/dev/fmt.sh","scripts/dev/lib/util.py",".githooks/pre-commit","tools/.githooks/pre-push","lefthook.yml"].every(f => o.routing[f] === "pe-devtools")'
check "a scripts/**/*.sh with a # pe: devtools header line routes to pe-devtools (CRLF too)" "$out" \
  'o.routing["scripts/local/fmt.sh"] === "pe-devtools" && o.routing["scripts/local/crlf.sh"] === "pe-devtools"'
check "a near-miss header, a header past line 10, a non-.sh file, or a script outside scripts/ stays with pe-general-purpose" "$out" \
  '["scripts/ci/near-miss.sh","scripts/release/late.sh","scripts/release/notes.txt","tools/dev.sh"].every(f => o.routing[f] === "pe-general-purpose")'
check "a language specialist outranks pe-devtools inside scripts/dev" "$out" 'o.routing["scripts/dev/main.go"] === "pe-go"'
R="$TMP/devtools-deleted"; new_repo "$R"; mkdir -p "$R/scripts"; printf '# pe: devtools\n' > "$R/scripts/gone.sh"; commit "$R"
git -C "$R" branch -f main HEAD; git -C "$R" rm -q scripts/gone.sh; put "$R" src/a.py 1; commit "$R"
check "a deleted headed script has no header to read and falls back to pe-general-purpose" "$(classify "$R")" \
  'o.routing["scripts/gone.sh"] === "pe-general-purpose"'

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
