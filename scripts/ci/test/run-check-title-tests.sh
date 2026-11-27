#!/usr/bin/env bash
# Tests for scripts/ci/check-title.sh against a throwaway git repo. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../check-title.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name "Test" && git config --global user.email "test@example.invalid"
git config --global commit.gpgsign false && git config --global init.defaultBranch main

fails=0
total=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1 — $2"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] expected [$3]"; fi; }

R="$W/r"
git init -q "$R"
# head <message...>: make the repo's HEAD a commit with that message (each arg one -m paragraph)
head() { local a=(); for m in "$@"; do a+=(-m "$m"); done; git -C "$R" commit -q --allow-empty "${a[@]}"; }
# title <title> <commits> [head-ref] [head-repo]: exit code, output kept in $W/out
title() {
  (cd "$R" && env TITLE="$1" COMMITS="$2" HEAD_REF="${3:-feat/x}" HEAD_REPO="${4:-o/r}" REPO=o/r bash "$CHECK") \
    > "$W/out" 2>&1
  echo $?
}
said() { grep -c -- "$1" "$W/out" || true; }

echo "=== check-title tests ==="

head "chore: seed"
check "a conventional title passes" "$(title "feat(x): add y" 3)" 0
check "  and prints its level" "$(said 'release level: minor, or major if')" 1
check "a non-conventional title fails" "$(title "Add y" 3)" 1
check "the release subject on a feature branch fails" "$(title "chore(release): v1.2.3" 3)" 1
check "  and says why" "$(said 'only the release workflow')" 1
check "the release subject on this repo's release/next passes" "$(title "chore(release): v1.2.3" 3 release/next o/r)" 0
check "the release subject on a fork's release/next fails" "$(title "chore(release): v1.2.3" 3 release/next f/r)" 1

head "Add y"
check "a one-commit PR whose commit is not conventional fails" "$(title "feat: add y" 1)" 1
head "fix: add y"
check "a one-commit PR whose commit releases below the title fails" "$(title "feat: add y" 1)" 1
check "  and names both levels" "$(said 'releases patch where the title releases minor')" 1
head "chore: tidy"
check "a one-commit PR at the title's level passes" "$(title "fix: tidy" 1)" 0
check "  and prints the squash level" "$(grep -cx 'release level: patch' "$W/out")" 1
head "feat: add y" "BREAKING CHANGE: y replaces z"
check "a lone commit's BREAKING CHANGE footer the title lacks fails" "$(title "feat: add y" 1)" 1
check "a lone commit's footer matched by the title's ! passes" "$(title "feat!: add y" 1)" 0
head "feat!: add y"
check "a ! on both passes as major" "$(title "feat!: add y" 1):$(said 'release level: major')" "0:1"

# The suite only matters if CI runs the script, from the title job, on pull requests.
CI_YML="$HERE/../../../.github/workflows/ci.yml"
title_job="$(awk '/^  title:/{t=1; next} t && /^  [^ ]/{t=0} t' "$CI_YML")"
check "ci.yml's title job runs check-title.sh" "$(printf '%s\n' "$title_job" | grep -c '^        run: bash scripts/ci/check-title.sh$')" 1
check "ci.yml's title job runs on pull requests" "$(printf '%s\n' "$title_job" | grep -c "^    if: github.event_name == 'pull_request'$")" 1

echo "=============================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] || { echo "FAIL: no checks ran"; exit 1; }
[ "$fails" -eq 0 ] || exit 1
echo "ALL PASS"
