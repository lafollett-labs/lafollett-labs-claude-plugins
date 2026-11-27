#!/usr/bin/env bash
# Fixture tests for build-plan.js — where PE front-end commands run and which build each UI project runs.
# Each case writes a throwaway git repo (angular.json / package.json), pipes a plan request to the
# CLI, and asserts on the JSON it prints and on the disposable worktree it creates. No npm packages —
# bash + git + node only.
# Exit 0 = all cases pass, 1 = any fail.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../build-plan.js"

for tool in node git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool not on PATH — cannot run build-plan tests" >&2
    exit 1
  fi
done
if [ ! -f "$CLI" ]; then
  echo "FAIL: build-plan.js not found at $CLI" >&2
  exit 1
fi

TMP="$(mktemp -d)"
command -v cygpath > /dev/null && TMP="$(cygpath -m "$TMP")"   # Git Bash: a C:/ path Windows node can open from JSON
trap 'rm -rf "$TMP"' EXIT
unset CLAUDE_CODE_TMPDIR
export TMPDIR="$TMP/os-tmp" TEMP="$TMP/os-tmp"   # os.tmpdir() reads TMPDIR on POSIX, TEMP first on Windows
mkdir -p "$TMPDIR"
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

# assert <name> <shell-condition...>
assert() {
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# plan <root> <checkout> <routing-json> [mode] [builds] — prints the CLI's stdout
plan() {
  local root="$1" checkout="$2" routing="$3" mode="${4:-branch}" builds="${5:-worktree}"
  printf '{"root":"%s","checkout":"%s","mode":"%s","builds":"%s","routing":%s}' "$root" "$checkout" "$mode" "$builds" "$routing" \
    | node "$CLI" plan
}

# field <json> <js-expression over `o`> — prints the value
field() { node -e 'const o = JSON.parse(process.argv[1]); console.log(eval(process.argv[2]))' "$1" "$2"; }

# write <file> — writes stdin to <file>, creating parent directories
write() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

# repo <dir> — git init and commit everything in <dir>
repo() {
  git -C "$1" init -q -b main && git -C "$1" config user.email t@example.com && git -C "$1" config user.name t \
    && git -C "$1" config commit.gpgsign false && git -C "$1" add -A && git -C "$1" commit -qm base
}

ANGULAR='{"src/app/app.component.ts":"pe-angular"}'

# webapp <dir> — a federated Angular app: native-federation build wrapping an esbuild target,
# prod and local-prod swap in prod environment files, build = "npm run ng build", build:local exists.
webapp() {
  write "$1/angular.json" <<'JSON'
{"projects":{"webapp":{"projectType":"application","root":"","architect":{
  "build":{"builder":"@angular-architects/native-federation:build","options":{"target":"webapp:esbuild","dev":false},
    "configurations":{"prod":{"target":"webapp:esbuild:prod"},"local-prod":{"target":"webapp:esbuild:local-prod"},
                      "local":{"target":"webapp:esbuild:local"}}},
  "esbuild":{"builder":"@angular/build:application","options":{"outputPath":{"base":"dist","browser":""}},
    "configurations":{
      "prod":{"fileReplacements":[{"replace":"src/environments/environment.ts","with":"src/environments/environment.prod.ts"}]},
      "local-prod":{"fileReplacements":[{"replace":"src/environments/environment.ts","with":"src/environments/environment.local-prod.ts"}]},
      "local":{"fileReplacements":[{"replace":"src/environments/environment.ts","with":"src/environments/environment.local.ts"}]}}}}}}}
JSON
  write "$1/package.json" <<'JSON'
{"scripts":{"ng":"node --max-old-space-size=16384 ./node_modules/@angular/cli/bin/ng",
  "build":"npm run ng build","build:prod":"npm run ng -- build -c prod","build:local":"npm run ng -- build -c local"}}
JSON
  echo 'export const a = 0;' | write "$1/src/app/app.component.ts"
  printf 'dist/\n' > "$1/.gitignore"
}

# mfe <dir> <scripts-json> <configurations-json> — an ngx-build-plus app whose default is production
mfe() {
  write "$1/angular.json" <<JSON
{"projects":{"mfe":{"projectType":"application","root":"","architect":{"build":{"builder":"ngx-build-plus:browser",
  "defaultConfiguration":"production","options":{"outputPath":"dist/mfe"},"configurations":$3}}}}}
JSON
  printf '{"scripts":%s}\n' "$2" | write "$1/package.json"
}
MFE_CONFIGS='{"production":{"fileReplacements":[{"replace":"src/environments/environment.ts","with":"src/environments/environment.prod.ts"}]},"development":{},"local":{"fileReplacements":[{"replace":"src/environments/environment.ts","with":"src/environments/environment.local.ts"}]}}'

run_of() { echo "o.plans.find(p => p.pe === '$1')"; }
scratch_count() { find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'sdlc-review-build-*' | wc -l | tr -d ' '; }

# ── In place, the webapp builds its local script in a disposable worktree of HEAD ──
webapp "$TMP/webapp" && repo "$TMP/webapp"
mkdir -p "$TMP/webapp/.git/hooks"
printf '#!/bin/sh\ntouch "%s"\n' "$TMP/hook-ran" > "$TMP/webapp/.git/hooks/post-checkout"
chmod +x "$TMP/webapp/.git/hooks/post-checkout"
o="$(plan "$TMP/webapp" in-place "$ANGULAR")"
P="$(run_of pe-angular)"
check "in place → a disposable worktree inside a scratch directory under the OS temp dir" "$o" \
  "o.placement === 'disposable-worktree' && o.scratch.startsWith(process.env.TMPDIR.replace(/\\\\/g,'/') + '/sdlc-review-build-') && o.build_root === o.scratch + '/checkout'"
B="$(field "$o" o.build_root)"
assert "in place → the build root is a worktree of the checkout at its HEAD" \
  test "$(git -C "$B" rev-parse HEAD 2>/dev/null)" = "$(git -C "$TMP/webapp" rev-parse HEAD)" -a \
  "$(cd "$(git -C "$B" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" = "$(cd "$TMP/webapp/.git" && pwd -P)"
assert "in place → the checkout's hooks do not run for the disposable worktree" test ! -e "$TMP/hook-ran"
check "in place webapp → build:local in the build root, default output path" "$o" \
  "$P.status === 'run' && $P.configuration === 'local' && $P.dir === o.build_root && $P.command === 'npm run build:local' && $P.output === $P.dir + '/dist'"
check "in place webapp → receipt names configuration and output" "$o" \
  "$P.receipt.includes('local') && $P.receipt.includes($P.output)"
check "in place webapp → BUILD ROOT line names the build root" "$o" "o.build_line.includes(o.build_root)"
assert "in place → the engineer's checkout is untouched" test -z "$(git -C "$TMP/webapp" status --porcelain)"

# ── The build root carries what the review mode reviews ──
webapp "$TMP/modes"
echo 's0' > "$TMP/modes/src/app/s.ts"; echo 'a0' > "$TMP/modes/src/app/a.ts"
repo "$TMP/modes"
echo 's1' > "$TMP/modes/src/app/s.ts"; git -C "$TMP/modes" add src/app/s.ts
echo 'a1' > "$TMP/modes/src/app/a.ts"
echo 'n1' > "$TMP/modes/src/app/new.ts"
echo 'stray' > "$TMP/modes/notes.txt"
before="$(git -C "$TMP/modes" status --porcelain)"
FILES='{"src/app/a.ts":"pe-angular","src/app/new.ts":"pe-angular"}'
content() { cat "$1/src/app/$2" 2>/dev/null || echo '-'; }

o="$(plan "$TMP/modes" in-place "$ANGULAR" branch)"; B="$(field "$o" o.build_root)"
assert "branch mode → HEAD only" test "$(content "$B" s.ts)$(content "$B" a.ts)$(content "$B" new.ts)" = "s0a0-"
o="$(plan "$TMP/modes" in-place "$ANGULAR" pr)"; B="$(field "$o" o.build_root)"
assert "pr mode → HEAD only" test "$(content "$B" s.ts)$(content "$B" a.ts)" = "s0a0"
o="$(plan "$TMP/modes" in-place "$ANGULAR" staged)"; B="$(field "$o" o.build_root)"
assert "staged mode → HEAD plus the staged changes" test "$(content "$B" s.ts)$(content "$B" a.ts)$(content "$B" new.ts)" = "s1a0-"
o="$(plan "$TMP/modes" in-place "$FILES" files)"; B="$(field "$o" o.build_root)"
assert "files mode → HEAD plus working-tree changes and untracked review targets" \
  test "$(content "$B" s.ts)$(content "$B" a.ts)$(content "$B" new.ts)" = "s1a1n1"
assert "files mode → untracked files outside the review targets stay behind" test ! -e "$B/notes.txt"
assert "every mode → the engineer's checkout and index are untouched" test "$(git -C "$TMP/modes" status --porcelain)" = "$before"

# ── Untracked .npmrc files reach the build root; other ignored files do not ──
mfe "$TMP/mono/apps/web" '{"ng":"ng","build:local":"ng build --configuration local"}' "$MFE_CONFIGS"
printf '.npmrc\nsecret.ts\n' > "$TMP/mono/.gitignore"
repo "$TMP/mono"
echo 'root-registry' > "$TMP/mono/.npmrc"
echo 'web-registry' > "$TMP/mono/apps/web/.npmrc"
echo 'x' > "$TMP/mono/apps/web/secret.ts"
o="$(plan "$TMP/mono" in-place '{"apps/web/src/app/x.ts":"pe-angular"}')"; P="$(run_of pe-angular)"
B="$(field "$o" o.build_root)"
check "project in a subdirectory → its dir inside the build root" "$o" "$P.dir === o.build_root + '/apps/web' && $P.command === 'npm run build:local'"
assert "untracked .npmrc files are copied into the build root" \
  test "$(cat "$B/.npmrc" 2>/dev/null)$(cat "$B/apps/web/.npmrc" 2>/dev/null)" = "root-registryweb-registry"
assert "other ignored files are not copied" test ! -e "$B/apps/web/secret.ts"
o="$(plan "$TMP/mono" in-place '{"apps/web/src/app/x.ts":"pe-angular","tools/gen.ts":"pe-angular"}' branch off)"
check "a front-end file with no package.json above it gets no plan entry" "$o" \
  "o.plans.length === 1 && o.plans.every(p => p.dir !== null && p.project !== null)"
d="$(printf '{"root":"%s","routing":{"tools/gen.ts":"pe-angular"}}' "$TMP/mono" | node "$CLI" detect)"
check "detect: a specialist-routed file outside every project is not front-end" "$d" "o.front_end === false"
o="$(plan "$TMP/mono" in-place '{"tools/gen.ts":"pe-angular"}')"
check "a specialist-routed file outside every project → no build root, no disposable worktree" "$o" \
  "o.placement === 'none' && o.scratch === null && o.plans.length === 0"
write "$TMP/ngonly/angular.json" <<'JSON'
{"projects":{"app":{"projectType":"application","root":"","architect":{"build":{"builder":"@angular/build:application","options":{"outputPath":"dist/app"}}}}}}
JSON
repo "$TMP/ngonly"
d="$(printf '{"root":"%s","routing":{"widgets/Card.vue":"pe-vue"}}' "$TMP/ngonly" | node "$CLI" detect)"
check "detect: a pe-vue file with angular.json but no package.json above it is not front-end" "$d" "o.front_end === false"

# ── A review-owned worktree builds in place at its default output path ──
R="$TMP/repo"
mkdir -p "$R" && webapp "$R" && repo "$R"
WT="$TMP/.sdlc-worktrees/repo/feat-x"
git -C "$R" worktree add -q -b feat/x "$WT" 2>/dev/null
before="$(scratch_count)"
o="$(plan "$WT" worktree "$ANGULAR" pr)"
P="$(run_of pe-angular)"
check "review-owned worktree → worktree placement, no scratch" "$o" \
  "o.placement === 'review-worktree' && o.scratch === null && o.build_root.endsWith('/feat-x')"
assert "review-owned worktree → no scratch directory created" test "$(scratch_count)" = "$before"
check "review-owned worktree → build:local at the default dist/" "$o" \
  "$P.command === 'npm run build:local' && $P.output.endsWith('/feat-x/dist') && $P.receipt.includes('local')"

# ── A worktree the engineer made is their own checkout → disposable worktree ──
OWN="$TMP/elsewhere/own-wt"
git -C "$R" worktree add -q -b feat/y "$OWN" 2>/dev/null
o="$(plan "$OWN" worktree "$ANGULAR")"
check "engineer's own linked worktree → disposable worktree" "$o" "o.placement === 'disposable-worktree' && o.build_root !== null"
o="$(plan "$R" worktree "$ANGULAR")"
check "primary checkout reported as worktree → disposable worktree" "$o" "o.placement === 'disposable-worktree'"

# ── Script resolution order: build:local, then build:dev, then a non-prod build, then the CLI ──
mfe "$TMP/ra" '{"ng":"ng","build":"ng build","build:local":"ng build --configuration local","build:dev":"ng build --configuration development"}' "$MFE_CONFIGS"
repo "$TMP/ra"
o="$(plan "$TMP/ra" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "production default + build:local → build:local" "$o" "$P.configuration === 'local' && $P.command === 'npm run build:local'"

mfe "$TMP/amenity" '{"ng":"ng","build":"ng build","build:dev":"ng build --configuration development"}' "$MFE_CONFIGS"
repo "$TMP/amenity"
o="$(plan "$TMP/amenity" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "production default + build:dev only → build:dev" "$o" "$P.configuration === 'development' && $P.command === 'npm run build:dev'"

mfe "$TMP/hub" '{"ng":"ng","build":"ng build"}' "$MFE_CONFIGS"
repo "$TMP/hub"
o="$(plan "$TMP/hub" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "production default, no local script → CLI with the local configuration" "$o" \
  "$P.configuration === 'local' && $P.command === 'npm run ng -- build --configuration local' && $P.output === $P.dir + '/dist/mfe'"
o="$(plan "$TMP/hub" worktree "$ANGULAR")"; P="$(run_of pe-angular)"
check "production default, no local script, not review-owned → still never production" "$o" "$P.configuration === 'local'"

mfe "$TMP/prodlocal" '{"build":"ng build","build:local":"ng build -c local-prod"}' \
  '{"production":{},"local-prod":{},"development":{}}'
repo "$TMP/prodlocal"
o="$(plan "$TMP/prodlocal" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "build:local naming a prod configuration is passed over" "$o" \
  "$P.configuration === 'development' && $P.command === 'npx ng build --configuration development'"

mfe "$TMP/allprod" '{"build":"ng build"}' '{"production":{},"prod-eu":{}}'
repo "$TMP/allprod"
o="$(plan "$TMP/allprod" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "every configuration is production → ask for direction, never build" "$o" "$P.status === 'ask' && /production/.test($P.reason) && !$P.command"

# ── build = "npm run ng build" with no local script runs as written ──
webapp "$TMP/nested"
node -e 'const f=process.argv[1],p=require(f);delete p.scripts["build:local"];require("fs").writeFileSync(f,JSON.stringify(p))' "$TMP/nested/package.json"
repo "$TMP/nested"
o="$(plan "$TMP/nested" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "nested npm build script with a non-production default → npm run build" "$o" \
  "$P.configuration === 'default' && $P.command === 'npm run build'"

# ── Libraries, packages without angular.json, multi-project workspaces ──
write "$TMP/lib/angular.json" <<'JSON'
{"projects":{"ui":{"projectType":"library","root":"","architect":{"build":{"builder":"@angular-devkit/build-angular:ng-packagr","defaultConfiguration":"production","options":{"project":"ng-package.json"},"configurations":{"production":{},"development":{}}}}}}}
JSON
echo '{"dest":"out/ui-lib"}' | write "$TMP/lib/ng-package.json"
echo '{"scripts":{"build":"ng build @octo/ui"}}' | write "$TMP/lib/package.json"
repo "$TMP/lib"
o="$(plan "$TMP/lib" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "library in place → builds a non-production configuration to its ng-package.json dest" "$o" \
  "$P.status === 'run' && $P.kind === 'angular-library' && $P.command === 'npx ng build --configuration development' && $P.output === $P.dir + '/out/ui-lib'"

echo '{"scripts":{"build":"tsup"}}' | write "$TMP/pkg/package.json"
repo "$TMP/pkg"
o="$(plan "$TMP/pkg" in-place '{"src/index.ts":"pe-angular"}')"; P="$(run_of pe-angular)"
check "pe-angular package without angular.json → introspect in the build root" "$o" \
  "$P.status === 'introspect' && !$P.command && $P.reason.length > 0 && $P.dir === o.build_root"

write "$TMP/multi/angular.json" <<'JSON'
{"projects":{
  "host-a":{"projectType":"application","root":"projects/a","architect":{"build":{"builder":"@angular/build:application","options":{"outputPath":"dist/a"},"configurations":{"production":{}}}}},
  "host-b":{"projectType":"application","root":"projects/b","architect":{"build":{"builder":"@angular/build:application","options":{"outputPath":"dist/b"},"configurations":{"production":{}}}}}}}
JSON
echo '{"scripts":{}}' | write "$TMP/multi/package.json"
repo "$TMP/multi"
o="$(plan "$TMP/multi" in-place '{"projects/b/src/main.ts":"pe-angular"}')"; P="$(run_of pe-angular)"
check "multi-project workspace → the project whose root holds the file" "$o" \
  "$P.project === 'host-b' && $P.command === 'npx ng build host-b' && $P.output === $P.dir + '/dist/b'"
for cfg in angular.json tsconfig.json package.json; do
  o="$(plan "$TMP/multi" in-place "{\"$cfg\":\"pe-angular\"}")"
  check "multi-project workspace, root $cfg changed → every project builds" "$o" \
    "o.plans.length === 2 && o.plans.every(p => p.status === 'run') && o.plans.map(p => p.command).sort().join() === 'npx ng build host-a,npx ng build host-b'"
done
o="$(plan "$TMP/multi" in-place '{"angular.json":"pe-angular","projects/b/src/main.ts":"pe-angular"}')"
check "workspace config plus a project file → each project planned once" "$o" \
  "o.plans.length === 2 && new Set(o.plans.map(p => p.project)).size === 2"
write "$TMP/rootapp/angular.json" <<'JSON'
{"projects":{
  "app":{"projectType":"application","root":"","sourceRoot":"src","architect":{"build":{"builder":"@angular/build:application","options":{"outputPath":"dist/app"},"configurations":{"production":{}}}}},
  "lib":{"projectType":"library","root":"projects/lib","architect":{"build":{"builder":"@angular/build:ng-packagr","options":{"project":"projects/lib/ng-package.json"}}}}}}
JSON
echo '{"scripts":{}}' | write "$TMP/rootapp/package.json"
repo "$TMP/rootapp"
o="$(plan "$TMP/rootapp" in-place '{"tsconfig.json":"pe-angular"}')"
check "app at root \"\" plus a library, root tsconfig.json changed → both projects planned" "$o" \
  "o.plans.length === 2 && o.plans.map(p => p.project).sort().join() === 'app,lib'"
o="$(plan "$TMP/rootapp" in-place '{"src/main.ts":"pe-angular"}')"
check "app at root \"\", a source file under it → only the app" "$o" \
  "o.plans.length === 1 && o.plans[0].project === 'app'"
echo '{"projects":{}}' | write "$TMP/noproj/angular.json"
echo '{"scripts":{}}' | write "$TMP/noproj/package.json"
repo "$TMP/noproj"
o="$(plan "$TMP/noproj" in-place '{"angular.json":"pe-angular"}')"
check "angular.json with no projects, root config changed → one ask entry" "$o" \
  "o.plans.length === 1 && o.plans[0].status === 'ask'"
o="$(plan "$TMP/multi" in-place '{"tools/gen.ts":"pe-angular"}')"; P="$(run_of pe-angular)"
check "multi-project workspace, a source file outside every project → ask" "$o" \
  "o.plans.length === 1 && $P.status === 'ask' && /no angular.json project contains/.test($P.reason)"

write "$TMP/evilname/angular.json" <<'JSON'
{"projects":{
  "a;touch pwned":{"projectType":"application","root":"projects/a","architect":{"build":{"builder":"@angular/build:application","options":{"outputPath":"dist/a"},"configurations":{"production":{},"x$(id)":{}}}}},
  "b":{"projectType":"application","root":"projects/b","architect":{"build":{"builder":"@angular/build:application","options":{"outputPath":"dist/b"},"defaultConfiguration":"production","configurations":{"production":{},"x$(id)":{}}}}}}}
JSON
echo '{"scripts":{}}' | write "$TMP/evilname/package.json"
repo "$TMP/evilname"
o="$(plan "$TMP/evilname" in-place '{"projects/a/src/main.ts":"pe-angular"}')"; P="$(run_of pe-angular)"
check "a project name that is not shell-safe → skip, no command" "$o" "$P.status === 'skip' && !$P.command && /shell-safe/.test($P.reason)"
o="$(plan "$TMP/evilname" in-place '{"projects/b/src/main.ts":"pe-angular"}')"; P="$(run_of pe-angular)"
check "a configuration name that is not shell-safe is never put in a command" "$o" "!/[$;]/.test($P.command || '')"

# ── Vue: Storybook and Nuxt generate both run in the build root ──
echo '{"scripts":{"build-storybook":"npm run sb -- build","generate":"nuxt generate"}}' | write "$TMP/vue/package.json"
repo "$TMP/vue"
o="$(plan "$TMP/vue" in-place '{"components/Card.vue":"pe-vue"}')"
check "vue in place → storybook at its default output" "$o" \
  "o.plans.some(p => p.kind === 'storybook' && p.status === 'run' && p.command === 'npm run build-storybook' && p.output === o.build_root + '/storybook-static')"
check "vue in place → nuxt generate at its default output" "$o" \
  "o.plans.some(p => p.kind === 'generate' && p.status === 'run' && p.command === 'npm run generate' && p.output === o.build_root + '/.output')"

# ── builds = checkout: the engineer's checkout and node_modules, output in a scratch directory, never an install ──
mkdir -p "$TMP/webapp/node_modules"
o="$(plan "$TMP/webapp" in-place "$ANGULAR" branch checkout)"; P="$(run_of pe-angular)"
check "checkout builds → the checkout is the build root, output in a scratch directory" "$o" \
  "o.placement === 'checkout' && o.build_root === '$TMP/webapp' && o.scratch.startsWith(process.env.TMPDIR.replace(/\\\\/g,'/') + '/sdlc-review-build-') && $P.dir === o.build_root"
check "checkout builds → build:local with a workspace-relative output path into scratch" "$o" \
  "$P.command === \"npm run build:local -- --output-path '\" + require('path').relative($P.dir, $P.output).replace(/\\\\/g,'/') + \"'\" && $P.output.startsWith(o.scratch + '/')"
check "checkout builds → BUILD ROOT line forbids installs" "$o" "o.build_line.includes(o.build_root) && /never run an install/.test(o.build_line)"
check "checkout builds with node_modules → tests, lint, and typecheck still run" "$o" "$P.checks !== 'skip'"
rmdir "$TMP/webapp/node_modules"
o="$(plan "$TMP/webapp" in-place "$ANGULAR" branch checkout)"; P="$(run_of pe-angular)"
check "checkout builds without node_modules → skip, never install" "$o" "$P.status === 'skip' && /node_modules/.test($P.reason) && !$P.command"
check "checkout builds without node_modules → tests, lint, and typecheck skip too" "$o" "$P.checks === 'skip'"

mkdir -p "$TMP/nested/node_modules" "$TMP/lib/node_modules" "$TMP/vue/node_modules" "$TMP/sb/node_modules"
o="$(plan "$TMP/nested" in-place "$ANGULAR" branch checkout)"; P="$(run_of pe-angular)"
check "checkout builds, nested npm script → the repo ng script with the output flag" "$o" \
  "$P.configuration === 'default' && $P.command === \"npm run ng -- build --output-path '\" + require('path').relative($P.dir, $P.output).replace(/\\\\/g,'/') + \"'\""
o="$(plan "$TMP/lib" in-place "$ANGULAR" branch checkout)"; P="$(run_of pe-angular)"
check "checkout builds, library → skip (output set by ng-package.json)" "$o" "$P.status === 'skip' && /ng-package/.test($P.reason)"
echo '{"scripts":{"build-storybook":"storybook build"}}' | write "$TMP/sb/package.json"
o="$(plan "$TMP/sb" in-place '{"components/Card.vue":"pe-vue"}' branch checkout)"
check "checkout builds, vue → storybook into scratch" "$o" \
  "o.plans.some(p => p.kind === 'storybook' && p.status === 'run' && p.command === \"npm run build-storybook -- --output-dir '\" + p.output + \"'\" && p.output.startsWith(o.scratch + '/'))"
o="$(plan "$TMP/vue" in-place '{"components/Card.vue":"pe-vue"}' branch checkout)"
check "checkout builds, storybook script that wraps npm run → skip" "$o" "o.plans.some(p => p.kind === 'storybook' && p.status === 'skip')"
check "checkout builds, nuxt generate → skip with a reason" "$o" "o.plans.some(p => p.kind === 'generate' && p.status === 'skip' && p.reason.length > 0)"
mkdir -p "$TMP/os tmp" "$TMP/webapp/node_modules"
o="$(TMPDIR="$TMP/os tmp" TEMP="$TMP/os tmp" plan "$TMP/webapp" in-place "$ANGULAR" branch checkout)"; P="$(run_of pe-angular)"
check "checkout builds, scratch path that is not shell-safe → skip" "$o" "$P.status === 'skip' && /shell-safe/.test($P.reason)"
rm -rf "$TMP/os tmp"
mkdir -p "$TMP/RUNNER~1.TMP"
o="$(TMPDIR="$TMP/RUNNER~1.TMP" TEMP="$TMP/RUNNER~1.TMP" plan "$TMP/webapp" in-place "$ANGULAR" branch checkout)"; P="$(run_of pe-angular)"
check "checkout builds, Windows 8.3 short temp path (~) → still runs" "$o" "$P.status === 'run' && $P.command.includes('RUNNER~1.TMP')"
rm -rf "$TMP/RUNNER~1.TMP"

# ── builds = off: nothing installs or builds ──
before="$(scratch_count)"
o="$(plan "$TMP/webapp" in-place "$ANGULAR" branch off)"; P="$(run_of pe-angular)"
check "builds off → no build root, every build skipped with a reason" "$o" \
  "o.placement === 'none' && o.scratch === null && o.build_root === null && $P.status === 'skip' && /off/.test($P.reason) && /^none/.test(o.build_line)"
assert "builds off → no scratch directory created" test "$(scratch_count)" = "$before"
o="$(plan "$WT" worktree "$ANGULAR" pr off)"; P="$(run_of pe-angular)"
check "builds off applies to a review-owned worktree too" "$o" "o.placement === 'none' && $P.status === 'skip'"

# ── No front-end project, or no git checkout → no build root ──
before="$(scratch_count)"
o="$(plan "$TMP/webapp" in-place '{"src/Api/Foo.cs":"pe-csharp"}')"
check "non-UI review in place → no build root, no plans" "$o" \
  "o.placement === 'none' && o.scratch === null && o.build_root === null && o.plans.length === 0 && /^none/.test(o.build_line)"
assert "non-UI review in place → no scratch directory created" test "$(scratch_count)" = "$before"

webapp "$TMP/nogit"
o="$(plan "$TMP/nogit" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "not a git checkout → builds skip with a reason, no build root" "$o" \
  "o.placement === 'none' && o.scratch === null && o.build_root === null && $P.status === 'skip' && /worktree/.test($P.reason) && /^none/.test(o.build_line)"
assert "not a git checkout → no scratch directory left" test "$(scratch_count)" = "$before"

# ── A wrapper whose bare inner target defaults to production is production ──
write "$TMP/fedwrap/angular.json" <<'JSON'
{"projects":{"app":{"projectType":"application","root":"","architect":{
  "build":{"builder":"@angular-architects/native-federation:build","options":{"target":"app:esbuild"},
    "configurations":{"production":{"target":"app:esbuild:production"},"development":{"target":"app:esbuild:development"}}},
  "esbuild":{"builder":"@angular/build:application","defaultConfiguration":"production","options":{"outputPath":"dist/app"},
    "configurations":{"production":{"fileReplacements":[{"replace":"src/environments/environment.ts","with":"src/environments/environment.prod.ts"}]},"development":{}}}}}}}
JSON
echo '{"scripts":{"build":"ng build"}}' | write "$TMP/fedwrap/package.json"
repo "$TMP/fedwrap"
o="$(plan "$TMP/fedwrap" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "wrapper over a production-default inner target → non-production configuration" "$o" \
  "$P.configuration === 'development' && $P.command === 'npx ng build --configuration development'"

# ── A root reached through a symlink still builds inside the disposable worktree ──
ln -s "$TMP/webapp" "$TMP/webapp-link"
o="$(plan "$TMP/webapp-link" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "symlinked root → the build root stays inside the scratch directory" "$o" \
  "o.placement === 'disposable-worktree' && o.build_root === o.scratch + '/checkout' && $P.dir === o.build_root"

# ── checkout builds never introspect: no verified output path for a package build ──
mkdir -p "$TMP/pkg/node_modules"
o="$(plan "$TMP/pkg" in-place '{"src/index.ts":"pe-angular"}' branch checkout)"; P="$(run_of pe-angular)"
check "checkout builds, package without angular.json → skip, never introspect" "$o" "$P.status === 'skip' && /output/.test($P.reason) && !$P.command"

# ── plan sweeps this repo's scratch directories left by interrupted rounds ──
webapp "$TMP/sweep" && repo "$TMP/sweep"
age() { node -e 'const f = process.argv[1] + "/git-common-dir"; const t = Date.now() / 1000 - 13 * 3600; require("fs").utimesSync(f, t, t)' "$1"; }
fresh="$(field "$(plan "$TMP/sweep" in-place "$ANGULAR")" o.scratch)"
stale_wt="$(field "$(plan "$TMP/sweep" in-place "$ANGULAR")" o.scratch)"
mkdir -p "$TMP/sweep/node_modules"
stale_co="$(field "$(plan "$TMP/sweep" in-place "$ANGULAR" branch checkout)" o.scratch)"
other="$(field "$(plan "$TMP/webapp" in-place "$ANGULAR")" o.scratch)"
age "$stale_wt"; age "$stale_co"; age "$other"
o="$(plan "$TMP/sweep" in-place '{"src/Api/Foo.cs":"pe-csharp"}')"
check "plan reports the stale scratch directories it swept" "$o" \
  "o.swept.length === 2 && o.swept.includes('$stale_wt') && o.swept.includes('$stale_co')"
assert "sweep removes this repo's stale scratch directories and their worktree registration" \
  test ! -e "$stale_wt" -a ! -e "$stale_co" -a "$(git -C "$TMP/sweep" worktree list --porcelain | grep -c "$(basename "$stale_wt")")" = "0"
assert "sweep keeps fresh scratch directories and other repos' scratch directories" test -d "$fresh" -a -d "$other"

# ── sweep never follows a symlinked checkout to someone else's worktree ──
git -C "$TMP/sweep" worktree add -q --detach "$TMP/victim-wt" 2>/dev/null
echo 'uncommitted' > "$TMP/victim-wt/keep.txt"
evil="$TMPDIR/sdlc-review-build-evil1"
mkdir -p "$evil" && cat "$fresh/git-common-dir" > "$evil/git-common-dir" && ln -s "$TMP/victim-wt" "$evil/checkout" && age "$evil"
plan "$TMP/sweep" in-place '{"src/Api/Foo.cs":"pe-csharp"}' > /dev/null
assert "sweep never removes a worktree a symlinked checkout points at" \
  test -f "$TMP/victim-wt/keep.txt" -a "$(git -C "$TMP/sweep" worktree list --porcelain | grep -c "victim-wt")" = "1"
evil="$TMPDIR/sdlc-review-build-evil2"
mkdir -p "$evil" && cat "$fresh/git-common-dir" > "$evil/git-common-dir" && ln -s "$TMP/victim-wt" "$evil/checkout"
node "$CLI" release --dir "$evil" > /dev/null
assert "release never removes a worktree a symlinked checkout points at" \
  test -f "$TMP/victim-wt/keep.txt" -a "$(git -C "$TMP/sweep" worktree list --porcelain | grep -c "victim-wt")" = "1"

# ── npm scripts with shell syntax are never trusted ──
mfe "$TMP/quoted" '{"ng":"ng","build:local":"ng build --configuration='"'"'production'"'"'"}' "$MFE_CONFIGS"
repo "$TMP/quoted"
o="$(plan "$TMP/quoted" in-place "$ANGULAR")"; P="$(run_of pe-angular)"
check "a quoted production configuration in a script is not trusted" "$o" \
  "$P.configuration === 'local' && $P.command === 'npm run ng -- build --configuration local'"
echo '{"scripts":{"build-storybook":"storybook build && echo done"}}' | write "$TMP/sbchain/package.json"
mkdir -p "$TMP/sbchain/node_modules"
o="$(plan "$TMP/sbchain" in-place '{"components/Card.vue":"pe-vue"}' branch checkout)"
check "checkout builds, chained storybook script → skip" "$o" "o.plans.some(p => p.kind === 'storybook' && p.status === 'skip')"

# ── checkout builds never ask: no engineer-directed build runs in the checkout ──
mkdir -p "$TMP/allprod/node_modules"
o="$(plan "$TMP/allprod" in-place "$ANGULAR" branch checkout)"; P="$(run_of pe-angular)"
check "checkout builds, no non-production build → skip, never ask" "$o" "$P.status === 'skip' && !$P.command"

# ── front-end is decided by the project, not by the PE a file routes to ──
echo '{"dependencies":{"nuxt":"^3.0.0","vue":"^3.0.0"},"scripts":{"generate":"nuxt generate"}}' | write "$TMP/nuxtgp/package.json"
echo 'export const x = 1;' | write "$TMP/nuxtgp/composables/useX.ts"
repo "$TMP/nuxtgp"
d="$(printf '{"root":"%s","routing":{"composables/useX.ts":"pe-general-purpose"}}' "$TMP/nuxtgp" | node "$CLI" detect)"
check "detect: a Nuxt composable routed to pe-general-purpose is front-end" "$d" "o.front_end === true"
d="$(printf '{"root":"%s","routing":{"src/Api/Foo.cs":"pe-csharp"}}' "$TMP/webapp" | node "$CLI" detect)"
check "detect: a C# file is not front-end" "$d" "o.front_end === false"
o="$(plan "$TMP/nuxtgp" in-place '{"composables/useX.ts":"pe-general-purpose"}')"
check "a front-end file routed to another PE gets a BUILD PLAN entry in the build root" "$o" \
  "o.placement === 'disposable-worktree' && o.plans.length === 1 && o.plans[0].pe === 'pe-general-purpose' && o.plans[0].dir === o.build_root"

# ── only front-end files routed to pe-general-purpose count; one plan entry per project ──
mfe "$TMP/ngdeps" '{"ng":"ng","build:local":"ng build --configuration local"}' "$MFE_CONFIGS"
node -e 'const f=process.argv[1],p=require(f);p.dependencies={"@angular/core":"^19.0.0"};require("fs").writeFileSync(f,JSON.stringify(p))' "$TMP/ngdeps/package.json"
echo 'on: [push]' | write "$TMP/ngdeps/.github/workflows/ci.yml"
repo "$TMP/ngdeps"
d="$(printf '{"root":"%s","routing":{".github/workflows/ci.yml":"pe-github-actions"}}' "$TMP/ngdeps" | node "$CLI" detect)"
check "detect: a CI-only change in an Angular repo is not front-end" "$d" "o.front_end === false"
o="$(plan "$TMP/ngdeps" in-place '{".github/workflows/ci.yml":"pe-github-actions"}')"
check "a CI-only change in an Angular repo → no build root" "$o" "o.placement === 'none' && o.plans.length === 0"
o="$(plan "$TMP/ngdeps" in-place '{"package.json":"pe-general-purpose"}')"
check "a package.json-only change → the deterministic Angular build, not introspect" "$o" \
  "o.plans.length === 1 && o.plans[0].pe === 'pe-general-purpose' && o.plans[0].status === 'run' && o.plans[0].command === 'npm run build:local'"
o="$(plan "$TMP/ngdeps" in-place '{"package.json":"pe-general-purpose","src/app/app.component.ts":"pe-angular"}')"
check "one plan entry per project, owned by the specialist PE" "$o" "o.plans.length === 1 && o.plans[0].pe === 'pe-angular'"
echo '{"dependencies":{"react":"^18.0.0","vite":"^5.0.0"},"scripts":{"build":"vite build"}}' | write "$TMP/reactapp/package.json"
d="$(printf '{"root":"%s","routing":{"src/App.tsx":"pe-general-purpose"}}' "$TMP/reactapp" | node "$CLI" detect)"
check "detect: a React / Vite file is front-end" "$d" "o.front_end === true"

# ── workspace config files are front-end files too ──
for f in angular.json tsconfig.json tsconfig.app.json; do
  d="$(printf '{"root":"%s","routing":{"%s":"pe-general-purpose"}}' "$TMP/ngdeps" "$f" | node "$CLI" detect)"
  check "detect: a $f-only change in an Angular repo is front-end" "$d" "o.front_end === true"
done
o="$(plan "$TMP/ngdeps" in-place '{"angular.json":"pe-general-purpose"}')"
check "an angular.json-only change → the deterministic Angular build" "$o" "o.plans.length === 1 && o.plans[0].command === 'npm run build:local'"
echo '{"dependencies":{"vue":"^3.0.0"},"scripts":{"test":"vitest"}}' | write "$TMP/vuebare/package.json"
repo "$TMP/vuebare"
o="$(plan "$TMP/vuebare" in-place '{"src/useX.ts":"pe-general-purpose"}')"
check "a Vue project with no build script → one skip entry naming its dir" "$o" \
  "o.plans.length === 1 && o.plans[0].status === 'skip' && o.plans[0].dir === o.build_root && /script/.test(o.plans[0].reason)"
o="$(plan "$TMP/vuebare" in-place '{"src/useX.ts":"pe-general-purpose"}' branch checkout)"
check "checkout builds, Vue project with no build script and no node_modules → its tests skip too" "$o" \
  "o.plans.length === 1 && o.plans[0].checks === 'skip' && /node_modules/.test(o.plans[0].reason)"

# ── Errors and release ──
before="$(scratch_count)"
echo 'not json' | node "$CLI" plan > /dev/null; rc=$?
assert "malformed input → exit 2, no directory left" test "$rc" -eq 2 -a "$(scratch_count)" = "$before"
plan "$TMP/webapp" in-place "$ANGULAR" sideways > /dev/null; rc=$?
assert "unknown review mode → exit 2, no directory left" test "$rc" -eq 2 -a "$(scratch_count)" = "$before"

registered() { git -C "$TMP/webapp" worktree list --porcelain | grep -c "$(basename "$1")" | tr -d ' '; }
o="$(plan "$TMP/webapp" in-place "$ANGULAR")"
d="$(field "$o" o.scratch)"
node "$CLI" release --dir "$d" > /dev/null; rc=$?
assert "release removes the scratch directory and its worktree registration" test "$rc" -eq 0 -a ! -e "$d" -a "$(registered "$d")" = "0"
node "$CLI" release --dir "$d" > /dev/null; rc=$?
assert "release of a missing directory succeeds" test "$rc" -eq 0

o="$(plan "$TMP/webapp" in-place "$ANGULAR")"
d="$(field "$o" o.scratch)"
rm -rf "$d/checkout"
node "$CLI" release --dir "$d" > /dev/null; rc=$?
assert "release after the worktree vanished still clears its registration" test "$rc" -eq 0 -a ! -e "$d" -a "$(registered "$d")" = "0"

# ── Claude Code's temp folder (CLAUDE_CODE_TMPDIR) wins over the OS temp dir ──
mkdir -p "$TMP/cc-tmp"
o="$(CLAUDE_CODE_TMPDIR="$TMP/cc-tmp" plan "$TMP/webapp" in-place "$ANGULAR")"
check "CLAUDE_CODE_TMPDIR set → the scratch directory is under it" "$o" "o.scratch.startsWith('$TMP/cc-tmp/sdlc-review-build-')"
d="$(field "$o" o.scratch)"
CLAUDE_CODE_TMPDIR="$TMP/cc-tmp" node "$CLI" release --dir "$d" > /dev/null; rc=$?
assert "CLAUDE_CODE_TMPDIR set → release removes a scratch directory under it" test "$rc" -eq 0 -a ! -e "$d"

mkdir -p "$TMPDIR/not-ours"
node "$CLI" release --dir "$TMPDIR/not-ours" > /dev/null; rc=$?
assert "release refuses a directory it did not create" test "$rc" -eq 2 -a -d "$TMPDIR/not-ours"
node "$CLI" release --dir "$TMP/webapp" > /dev/null; rc=$?
assert "release refuses a path outside the OS temp dir" test "$rc" -eq 2 -a -d "$TMP/webapp"

echo "=================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] && [ "$fails" -eq 0 ]
