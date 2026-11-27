#!/usr/bin/env bash
# Integration tests for run-release.sh: real git against a local bare "origin", a stub gh that
# records every call and can squash-merge the release PR. No network. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="$HERE/../run-release.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

command -v git >/dev/null 2>&1 || { echo "FAIL: git not on PATH" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node not on PATH" >&2; exit 1; }

fails=0
total=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1 — $2"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] expected [$3]"; fi; }

export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global init.defaultBranch main
git config --global user.name tester
git config --global user.email tester@example.com
git config --global commit.gpgsign false
git config --global tag.gpgsign false

ORIGIN="$W/origin.git"
DEV="$W/dev"
STATE="$W/gh-state"
mkdir -p "$STATE/releases" "$W/bin"

# ---- stub gh --------------------------------------------------------------------------------------
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: one open-or-merged release PR at a time; state lives in $STATE.
set -u
echo "$*" >> "$STATE/calls"
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "pr list")
    if [ -f "$STATE/pr" ] && [ "$(cat "$STATE/pr-state")" = OPEN ]; then cat "$STATE/pr"; fi ;;
  "pr create")
    [ "${STUB_CREATE_FAIL:-0}" = 1 ] && { echo "GitHub Actions is not permitted to create or approve pull requests" >&2; exit 1; }
    n=$(( $(cat "$STATE/pr-count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/pr-count"
    echo "$n" > "$STATE/pr"; echo OPEN > "$STATE/pr-state"
    arg --title "$@" > "$STATE/pr-title"
    echo "https://github.com/example/repo/pull/$n" ;;
  "pr edit")
    arg --title "$@" > "$STATE/pr-title" ;;
  "workflow run")
    [ "${STUB_DISPATCH_FAIL:-0}" = 1 ] && { echo "HTTP 502" >&2; exit 1; }
    : ;;
  "api repos/{owner}/{repo}/git/refs")
    ref=; sha=
    for a in "$@"; do case "$a" in ref=*) ref="${a#ref=}" ;; sha=*) sha="${a#sha=}" ;; esac; done
    git --git-dir="$ORIGIN" rev-parse -q --verify "$ref" >/dev/null && { echo "Reference already exists (HTTP 422)" >&2; exit 1; }
    git --git-dir="$ORIGIN" update-ref "$ref" "$sha" ;;
  "pr merge")
    case " $* " in *" --disable-auto "*) exit 0 ;; esac
    arg --subject "$@" > "$STATE/merge-subject"
    arg --body "$@" > "$STATE/merge-body"
    if [ "${STUB_AUTOMERGE:-0}" = 1 ]; then "$STATE/squash-merge" >/dev/null 2>&1 || exit 1; fi ;;
  "pr view")
    if [ "${STUB_PR_CLOSED:-0}" = 1 ]; then echo CLOSED; else cat "$STATE/pr-state"; fi ;;
  "release view")
    [ -f "$STATE/releases/$3" ] ;;
  "release create")
    git ls-remote --exit-code --tags "$ORIGIN" "refs/tags/$3" >/dev/null || { echo "tag $3 not on origin" >&2; exit 1; }
    cp "$(arg --notes-file "$@")" "$STATE/releases/$3" ;;
  *) echo "stub gh: unhandled $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$W/bin/gh"

# Squash-merge release/next into main the way GitHub does (one commit, pinned subject + body).
cat > "$STATE/squash-merge" <<'SQ'
#!/usr/bin/env bash
set -eu
tmp="$(mktemp -d)"
git clone -q "$ORIGIN" "$tmp/m"
cd "$tmp/m"
git merge -q --squash origin/release/next
git commit -q -m "$(cat "$STATE/merge-subject")" -m "$(cat "$STATE/merge-body")"
git push -q origin HEAD:main
git push -q origin --delete release/next
echo MERGED > "$STATE/pr-state"
rm -rf "$tmp"
SQ
chmod +x "$STATE/squash-merge"
export STATE ORIGIN

# ---- fixture repo ---------------------------------------------------------------------------------
write_plugin() { # <dir> <name> <version>
  mkdir -p "$1/plugins/$2/.claude-plugin"
  printf '{\n  "name": "%s",\n  "version": "%s",\n  "description": "%s plugin"\n}\n' "$2" "$3" "$2" \
    > "$1/plugins/$2/.claude-plugin/plugin.json"
  echo "# $2" > "$1/plugins/$2/README.md"
}
write_marketplace() { # <dir> <version> <plugins...>
  local d="$1" v="$2"; shift 2
  { printf '{\n  "name": "example-marketplace",\n  "metadata": {\n    "description": "fixture",\n    "version": "%s"\n  },\n  "plugins": [\n' "$v"
    local first=1 p
    for p in "$@"; do
      [ "$first" = 1 ] || printf ',\n'; first=0
      printf '    { "name": "%s", "source": "./plugins/%s" }' "$p" "$p"
    done
    printf '\n  ]\n}\n'; } > "$d/.claude-plugin/marketplace.json"
}

git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$DEV" 2>/dev/null
mkdir -p "$DEV/.claude-plugin" "$DEV/changelog.d"
write_plugin "$DEV" alpha 1.0.0
write_plugin "$DEV" beta 2.3.4
write_marketplace "$DEV" 1.0.0 alpha beta
printf '# Changelog\n\nIntro line.\n\n## [1.0.0] — 2026-01-01\n\nFirst.\n' > "$DEV/CHANGELOG.md"
echo "# Fragments" > "$DEV/changelog.d/README.md"
git -C "$DEV" add -A && git -C "$DEV" commit -qm "chore: initial" && git -C "$DEV" push -q origin main
C0="$(git -C "$DEV" rev-parse HEAD)"

# merge <subject> [body]: commit whatever is staged in DEV and push it to main (a squash-merged PR).
merge() {
  git -C "$DEV" add -A
  if [ $# -gt 1 ]; then git -C "$DEV" commit -qm "$1" -m "$2"; else git -C "$DEV" commit -qm "$1"; fi
  git -C "$DEV" pull -q --rebase origin main
  git -C "$DEV" push -q origin main
}

# release [VAR=value ...]: run the orchestrator in a fresh clone of main, as CI does.
RUN=0
release() {
  RUN=$((RUN + 1))
  local ci="$W/ci-$RUN"
  git clone -q "$ORIGIN" "$ci" 2>/dev/null
  : > "$STATE/calls"
  (cd "$ci" && env PATH="$W/bin:$PATH" RELEASE_DATE=2026-02-03 RELEASE_MERGE_WAIT=0 RELEASE_MERGE_POLL=1 \
    "$@" bash "$RELEASE") > "$W/out" 2>&1
  echo $?
}
remote_file() { git --git-dir="$ORIGIN" show "$1:$2" 2>/dev/null; }
version_at() { remote_file "$1" "$2" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.metadata?j.metadata.version:j.version)})'; }
tag_sha() { git --git-dir="$ORIGIN" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null; }
calls() { grep -c -- "$1" "$STATE/calls" 2>/dev/null || true; }

echo "=== release orchestrator integration tests ==="

# 1. Activation: the first run seeds v1.0.0 at main^1 and, with only a root change, releases nothing.
mkdir -p "$DEV/.github" && echo "on: push" > "$DEV/.github/ci.yml"
merge "ci: add workflows"
code="$(release)"
check "seed: exits 0" "$code" 0
check "seed: v1.0.0 tags the activation merge's first parent" "$(tag_sha v1.0.0)" "$C0"
check "seed: nothing to release" "$(grep -c 'nothing to release' "$W/out")" 1
check "seed: no PR" "$(calls 'pr create')" 0
check "seed: tag created through the API" "$(calls 'api repos/{owner}/{repo}/git/refs -f ref=refs/tags/v1.0.0 -f sha=')" 1

# 2. A feat merge on alpha opens the release PR.
echo "more" >> "$DEV/plugins/alpha/README.md"
printf '### Added\n- **alpha** learns a new move.\n' > "$DEV/changelog.d/alpha-move.md"
merge "feat(alpha): learn a new move (#1)"
code="$(release)"
check "stamp: exits 0" "$code" 0
check "stamp: alpha minor" "$(version_at release/next plugins/alpha/.claude-plugin/plugin.json)" 1.1.0
check "stamp: beta untouched" "$(version_at release/next plugins/beta/.claude-plugin/plugin.json)" 2.3.4
check "stamp: marketplace patch" "$(version_at release/next .claude-plugin/marketplace.json)" 1.0.1
check "stamp: commit subject" "$(git --git-dir="$ORIGIN" log -1 --format=%s release/next)" "chore(release): v1.0.1"
check "stamp: built on main" "$(git --git-dir="$ORIGIN" rev-parse release/next^1)" "$(git --git-dir="$ORIGIN" rev-parse main)"
check "stamp: changelog heading" "$(remote_file release/next CHANGELOG.md | grep -c '^## \[1.0.1\] — 2026-02-03$')" 1
check "stamp: changelog carries the fragment" "$(remote_file release/next CHANGELOG.md | grep -c 'alpha\*\* learns a new move')" 1
check "stamp: changelog plugins line" "$(remote_file release/next CHANGELOG.md | grep -c '^\*\*Plugins:\*\* alpha 1.1.0$')" 1
check "stamp: fragment removed" "$(remote_file release/next changelog.d/alpha-move.md | wc -l | tr -d ' ')" 0
check "stamp: fragments README kept" "$(remote_file release/next changelog.d/README.md)" "# Fragments"
check "stamp: PR opened" "$(calls 'pr create')" 1
check "stamp: CI dispatched on the release branch" "$(calls 'workflow run ci.yml --ref release/next')" 1
check "stamp: auto-merge pins the subject" "$(cat "$STATE/merge-subject")" "chore(release): v1.0.1"
check "stamp: merge body carries the base" "$(grep -c "^Base: $(git --git-dir="$ORIGIN" rev-parse main)$" "$STATE/merge-body")" 1
check "stamp: main untouched" "$(version_at main .claude-plugin/marketplace.json)" 1.0.0

# 3. The CI dispatch fails; the rerun reuses the stamp (no push, PR edited in place) and dispatches.
code="$(release STUB_DISPATCH_FAIL=1)"
check "dispatch-fail: exits 1" "$code" 1
before="$(git --git-dir="$ORIGIN" rev-parse release/next)"
code="$(release)"
check "rerun: exits 0" "$code" 0
check "rerun: branch not re-pushed" "$(git --git-dir="$ORIGIN" rev-parse release/next)" "$before"
check "rerun: CI dispatched on the unchanged stamp" "$(calls 'workflow run ci.yml --ref release/next')" 1
check "rerun: PR edited, not re-created" "$(calls 'pr create'):$(calls 'pr edit')" "0:1"

# 4. Another merge before the release lands regenerates one stamp over both.
echo "fix" >> "$DEV/plugins/beta/README.md"
merge "fix(beta): repair the thing (#2)"
code="$(release)"
check "regen: exits 0" "$code" 0
check "regen: alpha still minor from the baseline" "$(version_at release/next plugins/alpha/.claude-plugin/plugin.json)" 1.1.0
check "regen: beta patch" "$(version_at release/next plugins/beta/.claude-plugin/plugin.json)" 2.3.5
check "regen: marketplace still one patch" "$(version_at release/next .claude-plugin/marketplace.json)" 1.0.1
check "regen: fragments present -> subjects not listed" "$(remote_file release/next CHANGELOG.md | grep -c 'fix(beta): repair the thing (#2)')" 0
check "regen: re-dispatched" "$(calls 'workflow run ci.yml')" 1

# 5. Auto-merge lands inside the wait: tag + GitHub Release.
code="$(release STUB_AUTOMERGE=1 RELEASE_MERGE_WAIT=5)"
check "merge: exits 0" "$code" 0
check "merge: main is the release commit" "$(git --git-dir="$ORIGIN" log -1 --format=%s main)" "chore(release): v1.0.1"
check "merge: v1.0.1 tags it" "$(tag_sha v1.0.1)" "$(git --git-dir="$ORIGIN" rev-parse main)"
check "merge: release published" "$(grep -c '^## \[1.0.1\]' "$STATE/releases/v1.0.1" 2>/dev/null)" 1
check "merge: notes stop at the entry" "$(grep -c '^## \[1.0.0\]' "$STATE/releases/v1.0.1" 2>/dev/null)" 0

# 6. Idempotent: nothing new, nothing re-published.
code="$(release)"
check "idle: exits 0" "$code" 0
check "idle: nothing to release" "$(grep -c 'nothing to release' "$W/out")" 1
check "idle: no release re-created" "$(calls 'release create')" 0

# 7. A merge the wait missed is tagged by the next run, which then releases what followed.
echo "x" >> "$DEV/plugins/beta/README.md"
merge "feat(beta)!: rename the flag (#3)"
code="$(release)"
check "missed: stamp opened" "$code" 0
check "missed: breaking -> beta major" "$(version_at release/next plugins/beta/.claude-plugin/plugin.json)" 3.0.0
"$STATE/squash-merge" >/dev/null 2>&1
echo "docs" > "$DEV/NOTES.md"
merge "docs: root note (#4)"
code="$(release)"
check "missed: exits 0" "$code" 0
check "missed: v1.0.2 tagged on the merged release commit" "$(git --git-dir="$ORIGIN" log -1 --format=%s "$(tag_sha v1.0.2)")" "chore(release): v1.0.2"
check "missed: release published" "$(test -f "$STATE/releases/v1.0.2" && echo yes)" yes
check "missed: the root-only merge after it releases nothing" "$(grep -c 'nothing to release' "$W/out")" 1

# 7b. A look-alike that a tagged release then passes is not held for, and a name git quotes still bumps.
echo "y" >> "$DEV/plugins/alpha/README.md"
merge "fix(alpha): tweak (#5)"
code="$(release)"
check "passed: stamp opened" "$code" 0
echo "look" >> "$DEV/NOTES.md"
merge "chore(release): v8.8.8"                      # a look-alike lands while the release PR is open
"$STATE/squash-merge" >/dev/null 2>&1                # then the release PR merges, Base: trailer intact
printf 'x\n' > "$DEV/plugins/beta/caf$(printf '\303\251') \"q\".md"
merge "fix(beta): a file git quotes (#6)"
code="$(release)"
check "passed: exits 0" "$code" 0
check "passed: the release after the look-alike is tagged" \
  "$(git --git-dir="$ORIGIN" log -1 --format=%s "$(tag_sha v1.0.3)")" "chore(release): v1.0.3"
check "passed: the next release PR is armed, not held" "$(calls 'pr merge [0-9]* --auto'):$(calls 'disable-auto')" "1:0"
check "passed: a name git quotes bumps its plugin" "$(version_at release/next plugins/beta/.claude-plugin/plugin.json)" 3.0.1

# 8. A debut keeps its authored version and raises the marketplace minor.
write_plugin "$DEV" gamma 0.1.0
write_marketplace "$DEV" 1.0.2 alpha beta gamma
merge "feat(gamma): debut (#5)"
code="$(release)"
check "debut: exits 0" "$code" 0
check "debut: gamma at its authored version" "$(version_at release/next plugins/gamma/.claude-plugin/plugin.json)" 0.1.0
check "debut: marketplace minor" "$(version_at release/next .claude-plugin/marketplace.json)" 1.1.0
check "debut: plugins line marks it new" "$(remote_file release/next CHANGELOG.md | grep -c 'gamma 0.1.0 (new)')" 1

# 9. A closed release PR fails the run.
code="$(release STUB_PR_CLOSED=1 RELEASE_MERGE_WAIT=2)"
check "closed: exits 1" "$code" 1
check "closed: says so" "$(grep -c 'closed without merging' "$W/out")" 1

# 10. PR creation refused (Actions may not open PRs): fails with the setting hint.
echo "CLOSED" > "$STATE/pr-state"
code="$(release STUB_CREATE_FAIL=1)"
check "no-create: exits 1" "$code" 1
check "no-create: names the setting" "$(grep -c 'Allow GitHub Actions to create and approve pull requests' "$W/out")" 1

# 11. Bad tunables fail before any git or gh call.
refs_before="$(git --git-dir="$ORIGIN" for-each-ref)"
code="$(release RELEASE_MERGE_WAIT=soon)"
check "tunables: a non-numeric wait exits 1" "$code" 1
check "tunables: says why" "$(grep -c 'must be whole seconds' "$W/out")" 1
check "tunables: no gh call, origin untouched" \
  "$(calls '.'):$([ "$(git --git-dir="$ORIGIN" for-each-ref)" = "$refs_before" ] && echo same)" "0:same"

# 12. A release-looking subject without the Base: trailer is not tagged and does not wedge the run,
#     and the run leaves the release PR, which re-bumps that commit's plugins, for a human.
echo "z" >> "$DEV/README.txt"
merge "chore(release): v9.9.8"
code="$(release)"
check "look-alike: exits 0" "$code" 0
check "look-alike: warns" "$(grep -c 'has no Base: trailer' "$W/out")" 1
check "look-alike: not tagged" "$(tag_sha v9.9.8 || echo none)" none
check "look-alike: auto-merge turned off, not armed" "$(calls 'pr merge [0-9]* --disable-auto'):$(calls 'pr merge [0-9]* --auto')" "1:0"
check "look-alike: PR left for a human, with the recovery" \
  "$(grep -c 'is left for a human' "$W/out"):$(grep -c 'gh release create v9.9.8 --target [0-9a-f]\{40\}), close #[0-9]*, and re-run' "$W/out")" "1:1"

# 13 (last: it leaves main wedged). A release commit whose version disagrees with its marketplace fails closed.
echo "y" >> "$DEV/README.txt"
merge "chore(release): v9.9.9" "Base: $(git --git-dir="$ORIGIN" rev-parse main)"
code="$(release)"
check "mismatch: exits 1" "$code" 1
check "mismatch: says why" "$(grep -c 'says v9.9.9 but its marketplace version is' "$W/out")" 1
check "mismatch: no v9.9.9 tag" "$(tag_sha v9.9.9 || echo none)" none

echo "=============================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] || { echo "FAIL: no checks ran"; exit 1; }
[ "$fails" -eq 0 ] || exit 1
echo "ALL PASS"
