#!/usr/bin/env bash
# Unit tests for the release ENGINE (version-stamp.js): levels, planning, bump math, the
# byte-preserving rewrite and the changelog. No git, no network. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../version-stamp.js"
FIX="$HERE/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v node >/dev/null 2>&1 || { echo "FAIL: node not on PATH" >&2; exit 1; }
[ -f "$ENGINE" ] || { echo "FAIL: engine not found at $ENGINE" >&2; exit 1; }

fails=0
total=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1 — $2"; fails=$((fails + 1)); }

# assert_stdout <label> <expected> <engine args...>: exit 0 and exact stdout.
assert_stdout() {
  local label="$1" expected="$2" got code; shift 2
  got="$(node "$ENGINE" "$@" 2>/dev/null)"; code=$?
  if [ "$code" -ne 0 ]; then fail "$label" "exit $code"; return; fi
  if [ "$got" != "$expected" ]; then fail "$label" "got [$got] expected [$expected]"; return; fi
  pass "$label"
}

assert_exit() {
  local label="$1" expected="$2" code; shift 2
  node "$ENGINE" "$@" >/dev/null 2>&1; code=$?
  if [ "$code" -ne "$expected" ]; then fail "$label" "exit $code (expected $expected)"; return; fi
  pass "$label"
}

assert_has() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1" "missing [$3]"; fi
}

assert_lacks() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "unexpected [$3]"; else pass "$1"; fi
}

# commit <sha-digit> <subject> <body> <files...>: one record in the plan --log format.
commit() {
  local d="$1" subject="$2" body="$3"; shift 3
  printf '\x1e%s\x1f%s\x1f%s\x1f\n' "$(printf "%040d" "$d")" "$subject" "$body"
  local f; for f in "$@"; do printf '%s\n' "$f"; done
}

echo "=== release engine unit tests ==="

# --- commit level ------------------------------------------------------------------------------
assert_stdout "level feat -> minor" "minor" level --subject "feat: add thing"
assert_stdout "level feat(scope) -> minor" "minor" level --subject "feat(alpha): add thing (#12)"
assert_stdout "level fix -> patch" "patch" level --subject "fix(alpha): repair"
assert_stdout "level chore -> patch" "patch" level --subject "chore: tidy"
assert_stdout "level feat! -> major" "major" level --subject "feat!: drop the old flag"
assert_stdout "level fix(scope)! -> major (breaking beats fix)" "major" level --subject "fix(alpha)!: rename"
printf 'Body line\n\nBREAKING CHANGE: the flag is gone\n' > "$WORK/body-breaking"
assert_stdout "level BREAKING CHANGE footer -> major" "major" level --subject "fix: x" --body-file "$WORK/body-breaking"
printf 'Body line\n\nBREAKING-CHANGE: the flag is gone\n' > "$WORK/body-breaking2"
assert_stdout "level BREAKING-CHANGE footer -> major" "major" level --subject "fix: x" --body-file "$WORK/body-breaking2"
printf 'mentions a BREAKING CHANGE: inline only\n' > "$WORK/body-inline"
assert_stdout "level inline BREAKING CHANGE mid-line -> not major" "patch" level --subject "fix: x" --body-file "$WORK/body-inline"
assert_stdout "level non-conventional -> patch" "patch" level --subject "Update README.md"
assert_stdout "level uppercase type -> patch" "patch" level --subject "Feat: shouting"
assert_exit "level requires --subject" 1 level
assert_exit "level rejects a flag with no value" 1 level --subject

# --- subject check -----------------------------------------------------------------------------
assert_exit "subject-check accepts feat(scope)!:" 0 subject-check --subject "feat(sdlc)!: port the plugin"
assert_exit "subject-check accepts a (#N) suffix" 0 subject-check --subject "fix: thing (#3)"
assert_exit "subject-check rejects no colon" 1 subject-check --subject "feat add thing"
assert_exit "subject-check rejects no space after colon" 1 subject-check --subject "feat:thing"
assert_exit "subject-check rejects empty description" 1 subject-check --subject "feat: "
assert_exit "subject-check rejects nested parens in scope" 1 subject-check --subject "feat(a(b)): x"
assert_exit "subject-check rejects Merge subjects" 1 subject-check --subject "Merge branch 'feat/x' into 'main'"

# --- release subject ---------------------------------------------------------------------------
assert_stdout "release-version reads the version" "1.35.0" release-version --subject "chore(release): v1.35.0"
assert_stdout "release-version tolerates a (#N) suffix" "1.35.0" release-version --subject "chore(release): v1.35.0 (#42)"
assert_exit "release-version rejects other chores" 1 release-version --subject "chore: v1.35.0"
assert_exit "release-version rejects a trailing word" 1 release-version --subject "chore(release): v1.35.0 hotfix"
assert_exit "release-version rejects a prerelease" 1 release-version --subject "chore(release): v1.35.0-rc.1"

# --- plan ----------------------------------------------------------------------------------------
commit 1 "feat(alpha): new move" "" plugins/alpha/skills/a/SKILL.md > "$WORK/log1"
assert_stdout "plan: one feat on alpha" "plugin alpha minor
marketplace patch" plan --log "$WORK/log1" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

{ commit 1 "fix(alpha): one" "" plugins/alpha/a.md
  commit 2 "feat(alpha): two" "" plugins/alpha/b.md
  commit 3 "fix(beta): three" "" plugins/beta/c.md; } > "$WORK/log2"
assert_stdout "plan: per-plugin max level across commits" "plugin alpha minor
plugin beta patch
marketplace patch" plan --log "$WORK/log2" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

commit 1 "docs: root only" "" README.md CHANGELOG.md changelog.d/x.md .github/workflows/ci.yml > "$WORK/log3"
assert_stdout "plan: root-only commits release nothing" "" plan --log "$WORK/log3" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

: > "$WORK/log-empty"
assert_stdout "plan: empty range releases nothing" "" plan --log "$WORK/log-empty" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

commit 1 "chore: retitle" "" .claude-plugin/marketplace.json > "$WORK/log4"
assert_stdout "plan: marketplace-only edit -> marketplace patch" "marketplace patch" plan --log "$WORK/log4" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-edited.json"

{ commit 1 "feat(gamma): debut" "" plugins/gamma/.claude-plugin/plugin.json .claude-plugin/marketplace.json
  commit 2 "fix(alpha): x" "" plugins/alpha/a.md; } > "$WORK/log5"
assert_stdout "plan: a debut keeps its version and raises the marketplace minor" "plugin alpha patch
new gamma
marketplace minor" plan --log "$WORK/log5" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-added.json"

commit 1 "feat!: drop beta" "" plugins/beta/a.md .claude-plugin/marketplace.json > "$WORK/log6"
assert_stdout "plan: removal + breaking -> marketplace major, no bump for the removed plugin" "marketplace major" \
  plan --log "$WORK/log6" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-removed.json"

commit 1 "chore: drop beta" "" plugins/beta/a.md .claude-plugin/marketplace.json > "$WORK/log7"
assert_stdout "plan: removal without the marker -> marketplace patch" "marketplace patch" \
  plan --log "$WORK/log7" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-removed.json"

# The release commit is the only one touching beta: if it were counted, beta would bump.
RELEASE_BODY="**Plugins:** beta 2.0.1

Base: $(printf '%040d' 7)"
{ commit 1 "fix(alpha): x" "" plugins/alpha/a.md
  commit 2 "chore(release): v1.29.6 (#9)" "$RELEASE_BODY" plugins/beta/.claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md
  commit 3 "fix(alpha): y" "" plugins/alpha/b.md; } > "$WORK/log8"
assert_stdout "plan: release commits in range are ignored" "plugin alpha patch
marketplace patch" plan --log "$WORK/log8" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

{ commit 1 "fix(alpha): x" "" plugins/alpha/a.md
  commit 2 "chore(release): v9.9.9" "" plugins/beta/b.md; } > "$WORK/log8b"
assert_stdout "plan: a release-looking subject without the Base: trailer still bumps" "plugin alpha patch
plugin beta patch
marketplace patch" plan --log "$WORK/log8b" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

# git log -z: NUL after the format line and after each name, which is written as is (no C quoting).
{ printf '\x1e%040d\x1f%s\x1f\x1f\0\n%s\0' 1 "fix: quoted names" "plugins/alpha/caf$(printf '\303\251').md"
  printf '\x1e%040d\x1f%s\x1f\x1f\0\n%s\0%s\0' 2 "fix: more" 'plugins/beta/q"x.md' 'README.md'; } > "$WORK/log-z"
assert_stdout "plan: a -z log with names git would quote bumps their plugins" "plugin alpha patch
plugin beta patch
marketplace patch" plan --log "$WORK/log-z" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"
printf '\x1e%040d\x1f%s\x1f\x1f\0\n%s\0' 1 "chore: retitle" ".claude-plugin/marketplace.json" > "$WORK/log-z4"
assert_stdout "plan: a -z log's marketplace-only edit -> marketplace patch" "marketplace patch" \
  plan --log "$WORK/log-z4" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-edited.json"

commit 1 "fix: x" "trailer

BREAKING CHANGE: gone" plugins/alpha/a.md > "$WORK/log9"
assert_stdout "plan: a footer break in the body -> major" "plugin alpha major
marketplace patch" plan --log "$WORK/log9" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

commit 1 "fix: stray" "" plugins/unlisted/a.md > "$WORK/log10"
assert_stdout "plan: an unlisted plugin dir bumps nothing" "" plan --log "$WORK/log10" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

printf 'not a log record' > "$WORK/log-bad"
printf '\x1eonly-a-sha' >> "$WORK/log-bad"
assert_exit "plan: a malformed record fails closed" 1 plan --log "$WORK/log-bad" --before "$FIX/marketplace-base.json" --after "$FIX/marketplace-base.json"

# --- bump math -----------------------------------------------------------------------------------
assert_stdout "bump patch" "1.29.6" bump 1.29.5 patch
assert_stdout "bump minor zeros patch" "1.30.0" bump 1.29.5 minor
assert_stdout "bump major zeros minor and patch" "2.0.0" bump 1.29.5 major
assert_exit "bump rejects a two-part version" 1 bump 1.2 patch
assert_exit "bump rejects an unknown level" 1 bump 1.2.3 huge

# --- read-version + byte-preserving bump-file --------------------------------------------------
assert_stdout "read-version: marketplace metadata.version" "1.29.5" read-version "$FIX/marketplace-base.json"
assert_stdout "read-version: marketplace top-level fallback" "3.4.5" read-version "$FIX/marketplace-toplevel.json"
assert_stdout "read-version: plugin.json" "1.2.3" read-version "$FIX/plugin.json"

# assert_preserve <label> <fixture> <level> <expected>: only the version bytes change.
assert_preserve() {
  local label="$1" fixture="$2" level="$3" expected="$4" got
  cp "$FIX/$fixture" "$WORK/p.json"
  got="$(node "$ENGINE" bump-file "$WORK/p.json" "$level" 2>/dev/null)" || { fail "$label" "bump-file failed"; return; }
  [ "$got" = "$expected" ] || { fail "$label" "printed [$got]"; return; }
  sed "s/\"$expected\"/\"OLD\"/" "$WORK/p.json" > "$WORK/a"
  awk '!d && /"version": "[^"]+"/ {sub(/"version": "[^"]+"/, "\"version\": \"OLD\""); d=1} {print}' "$FIX/$fixture" > "$WORK/b"
  if cmp -s "$WORK/a" "$WORK/b"; then pass "$label"; else fail "$label" "bytes outside the version changed"; fi
}
assert_preserve "bump-file plugin.json patch preserves bytes" plugin.json patch 1.2.4
assert_preserve "bump-file marketplace minor preserves bytes" marketplace-base.json minor 1.30.0
cp "$FIX/marketplace-base.json" "$WORK/m.json"; node "$ENGINE" bump-file "$WORK/m.json" major >/dev/null 2>&1
assert_stdout "bump-file marketplace writes metadata.version" "2.0.0" read-version "$WORK/m.json"
assert_exit "bump-file fails closed on a nested version first" 1 bump-file "$FIX/misordered-version.json" patch
assert_exit "bump-file fails closed on an equal-value nested version first" 1 bump-file "$FIX/equal-nested-version.json" patch
cp "$FIX/marketplace-entry-first.json" "$WORK/e.json"
assert_exit "bump-file fails closed when a plugin entry's version precedes metadata" 1 bump-file "$WORK/e.json" patch
assert_stdout "a refused bump leaves the file untouched" "1.0.0" read-version "$WORK/e.json"
assert_exit "bump-file rejects a missing file" 1 bump-file "$WORK/nope.json" patch

# --- changelog -----------------------------------------------------------------------------------
mkdir -p "$WORK/frag" "$WORK/nofrag"
printf '### Fixed\n- **alpha** repairs a thing.\n  - with a nested detail\n' > "$WORK/frag/b-fix.md"
printf '### Added\n- **gamma** debuts.\n\n### Fixed\n- **beta** fixes another.\n' > "$WORK/frag/a-add.md"
printf 'loose line before any heading\n' > "$WORK/frag/c-loose.md"
printf '# not a fragment\n' > "$WORK/frag/README.md"
printf '# Changelog\n\nIntro.\n\n## [1.29.5] — 2026-01-01\n\nOlder entry.\n' > "$WORK/cl.md"
cp "$WORK/cl.md" "$WORK/cl-orig.md"
node "$ENGINE" changelog-release --file "$WORK/cl.md" --version 1.30.0 --date 2026-02-03 \
  --plugins "alpha@1.2.4,gamma@0.1.0!new" --fragments-dir "$WORK/frag" > "$WORK/entry" 2>"$WORK/err" \
  || fail "changelog-release with fragments" "$(cat "$WORK/err")"
assert_has "changelog: new heading" "$WORK/cl.md" "## [1.30.0] — 2026-02-03"
assert_has "changelog: plugins line marks the debut" "$WORK/cl.md" "**Plugins:** alpha 1.2.4, gamma 0.1.0 (new)"
assert_has "changelog: fragment bullets kept" "$WORK/cl.md" "- **gamma** debuts."
assert_has "changelog: nested bullet kept" "$WORK/cl.md" "  - with a nested detail"
assert_has "changelog: text before a heading lands under Changed" "$WORK/cl.md" "### Changed"
assert_lacks "changelog: README.md is not a fragment" "$WORK/cl.md" "not a fragment"
assert_has "changelog: older entry kept" "$WORK/cl.md" "Older entry."
# check <label> <got> <expected>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] expected [$3]"; fi; }
check "changelog: same kind merges into one section" "$(grep -c '^### Fixed' "$WORK/cl.md")" 1
order="$(grep '^### ' "$WORK/cl.md" | tr '\n' ' ')"
check "changelog: Keep a Changelog section order" "$order" "### Added ### Changed ### Fixed "
new_line="$(grep -n '^## \[1.30.0\]' "$WORK/cl.md" | cut -d: -f1)"; old_line="$(grep -n '^## \[1.29.5\]' "$WORK/cl.md" | cut -d: -f1)"
check "changelog: newest first" "$([ "$new_line" -lt "$old_line" ] && echo yes)" yes
assert_has "changelog: entry echoed to stdout" "$WORK/entry" "## [1.30.0]"
check "changelog: header bytes preserved" "$(head -n 4 "$WORK/cl.md")" "$(head -n 4 "$WORK/cl-orig.md")"

commit 1 "fix(alpha): repair the thing" "" plugins/alpha/a.md > "$WORK/log-cl"
node "$ENGINE" changelog-release --file "$WORK/seed.md" --version 1.0.1 --date 2026-02-03 --plugins "alpha@1.0.1" \
  --fragments-dir "$WORK/nofrag" --log "$WORK/log-cl" >/dev/null 2>&1 || fail "changelog-release seed" "failed"
assert_has "changelog: seeds the header" "$WORK/seed.md" "# Changelog"
assert_has "changelog: no fragments falls back to commit subjects" "$WORK/seed.md" "- fix(alpha): repair the thing (0000000)"
node "$ENGINE" changelog-release --file "$WORK/meta.md" --version 1.0.2 --date 2026-02-03 --plugins "" \
  --fragments-dir "$WORK/missing-dir" >/dev/null 2>&1 || fail "changelog-release metadata only" "failed"
assert_has "changelog: marketplace-only plugins line" "$WORK/meta.md" "**Plugins:** marketplace metadata only"
assert_exit "changelog-release refuses a duplicate version" 1 changelog-release --file "$WORK/cl.md" --version 1.30.0 \
  --date 2026-02-03 --plugins "" --fragments-dir "$WORK/nofrag"
assert_exit "changelog-release rejects a bad date" 1 changelog-release --file "$WORK/x.md" --version 1.0.0 --date 02/03/2026 \
  --plugins "" --fragments-dir "$WORK/nofrag"
assert_exit "changelog-release rejects a non-semver version" 1 changelog-release --file "$WORK/x.md" --version v1 \
  --date 2026-02-03 --plugins "" --fragments-dir "$WORK/nofrag"
assert_exit "changelog-release requires --fragments-dir" 1 changelog-release --file "$WORK/x.md" --version 1.0.0 --date 2026-02-03

node "$ENGINE" changelog-entry --file "$WORK/cl.md" --version 1.30.0 > "$WORK/one"
assert_has "changelog-entry: includes its heading" "$WORK/one" "## [1.30.0]"
assert_lacks "changelog-entry: stops before the next entry" "$WORK/one" "## [1.29.5]"
node "$ENGINE" changelog-entry --file "$WORK/cl.md" --version 1.29.5 > "$WORK/last"
assert_has "changelog-entry: the last entry runs to EOF" "$WORK/last" "Older entry."
assert_stdout "changelog-entry: an absent version prints nothing" "" changelog-entry --file "$WORK/cl.md" --version 9.9.9
assert_stdout "changelog-entry: dots are literal" "" changelog-entry --file "$WORK/cl.md" --version 1x30x0

assert_exit "unknown subcommand fails" 1 bogus

echo "=============================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] || { echo "FAIL: no checks ran"; exit 1; }
[ "$fails" -eq 0 ] || exit 1
echo "ALL PASS"
