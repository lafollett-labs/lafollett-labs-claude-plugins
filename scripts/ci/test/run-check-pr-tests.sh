#!/usr/bin/env bash
# Tests for scripts/ci/check-pr.sh against throwaway git repos. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

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

# fresh: a repo holding a copy of the checker, one plugin and a marketplace at 1.0.0.
N=0
fresh() {
  N=$((N + 1)); R="$W/r$N"
  mkdir -p "$R/scripts/ci/release" "$R/plugins/alpha/.claude-plugin" "$R/.claude-plugin" "$R/changelog.d"
  cp "$ROOT/scripts/ci/check-pr.sh" "$R/scripts/ci/"
  cp "$ROOT/scripts/ci/release/version-stamp.js" "$R/scripts/ci/release/"
  printf '{\n  "name": "alpha",\n  "version": "1.0.0"\n}\n' > "$R/plugins/alpha/.claude-plugin/plugin.json"
  printf '{\n  "name": "m",\n  "metadata": {\n    "version": "1.0.0"\n  },\n  "plugins": [\n    { "name": "alpha", "source": "./plugins/alpha" }\n  ]\n}\n' \
    > "$R/.claude-plugin/marketplace.json"
  echo "# fragments" > "$R/changelog.d/README.md"
  echo "a" > "$R/plugins/alpha/a.md"
  git -C "$R" init -q && git -C "$R" add -A && git -C "$R" commit -qm init
  BASE="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" checkout -q -b feature
}
commit() { git -C "$R" add -A && git -C "$R" commit -qm "$1"; }
run() { (cd "$R" && bash scripts/ci/check-pr.sh "$BASE" "$(git rev-parse HEAD)") > "$W/out" 2>&1; echo $?; }
frag() { printf '### Fixed\n- %s\n' "$1" > "$R/changelog.d/$1.md"; }

echo "=== check-pr tests ==="

fresh; echo b >> "$R/plugins/alpha/a.md"; frag alpha-fix; commit "fix(alpha): x"
check "a plugin change with a fragment passes" "$(run)" 0

fresh; echo b >> "$R/plugins/alpha/a.md"; commit "fix(alpha): x"
check "a plugin change without a fragment fails" "$(run)" 1
check "  and names changelog.d" "$(grep -c '::error file=changelog.d::' "$W/out")" 1

fresh; echo b >> "$R/plugins/alpha/a.md"; echo more >> "$R/changelog.d/README.md"; commit "fix(alpha): x"
check "editing only the fragments README does not count" "$(run)" 1

fresh; frag old; commit "chore: seed"; BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" rm -q changelog.d/old.md; echo b >> "$R/plugins/alpha/a.md"; commit "fix(alpha): x"
check "deleting a fragment does not count" "$(run)" 1

fresh; echo "x" > "$R/README.md"; commit "docs: root"
check "a root-only change needs no fragment" "$(run)" 0

fresh; sed -i.bak 's/1.0.0/1.0.1/' "$R/plugins/alpha/.claude-plugin/plugin.json"; rm "$R/plugins/alpha/.claude-plugin/plugin.json.bak"
frag alpha-bump; commit "fix(alpha): bump by hand"
check "a hand-edited plugin version fails" "$(run)" 1
check "  and names the file" "$(grep -c '::error file=plugins/alpha/.claude-plugin/plugin.json::version changed 1.0.0 -> 1.0.1' "$W/out")" 1

fresh; sed -i.bak 's/"1.0.0"/"1.1.0"/' "$R/.claude-plugin/marketplace.json"; rm "$R/.claude-plugin/marketplace.json.bak"; commit "chore: bump marketplace"
check "a hand-edited marketplace version fails" "$(run)" 1

fresh; sed -i.bak 's/"name": "alpha"/"name": "alpha", "description": "d"/' "$R/plugins/alpha/.claude-plugin/plugin.json"
rm "$R/plugins/alpha/.claude-plugin/plugin.json.bak"; frag alpha-desc; commit "docs(alpha): describe"
check "editing a manifest without touching its version passes" "$(run)" 0

fresh; mkdir -p "$R/plugins/gamma/.claude-plugin"; printf '{\n  "name": "gamma",\n  "version": "0.1.0"\n}\n' > "$R/plugins/gamma/.claude-plugin/plugin.json"
frag gamma; commit "feat(gamma): debut"
check "a new plugin debuts at its authored version" "$(run)" 0

fresh; git -C "$R" rm -rq plugins/alpha; frag drop; commit "feat!: drop alpha"
check "removing a plugin is not a version edit" "$(run)" 0

fresh; echo b >> "$R/plugins/alpha/a.md"; frag alpha-fix; commit "fix(alpha): x"
git -C "$R" checkout -q main; echo m > "$R/main.txt"; git -C "$R" add -A; git -C "$R" commit -qm "main moves"
sed -i.bak 's/1.0.0/1.0.1/' "$R/plugins/alpha/.claude-plugin/plugin.json"; rm "$R/plugins/alpha/.claude-plugin/plugin.json.bak"
git -C "$R" add -A; git -C "$R" commit -qm "chore(release): v1.0.1"; BASE="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q feature
check "main's own release bump is not blamed on the branch" "$(run)" 0

fresh
check "a missing head is refused" "$( (cd "$R" && bash scripts/ci/check-pr.sh "$BASE") >/dev/null 2>&1; echo $?)" 2
check "an unknown base is refused" "$( (cd "$R" && bash scripts/ci/check-pr.sh 1234567890123456789012345678901234567890 HEAD) >/dev/null 2>&1; echo $?)" 2

echo "=============================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] || { echo "FAIL: no checks ran"; exit 1; }
[ "$fails" -eq 0 ] || exit 1
echo "ALL PASS"
