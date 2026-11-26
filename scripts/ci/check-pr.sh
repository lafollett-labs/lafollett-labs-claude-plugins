#!/usr/bin/env bash
# PR rules the release workflow depends on. Usage: check-pr.sh <base-sha> <head-sha>
#   1. A branch never edits an existing version: plugin.json "version" or the marketplace version.
#      The release workflow stamps them; a hand edit double-bumps. A new plugin.json debuts as authored.
#   2. A change under plugins/ adds or edits a changelog.d/*.md fragment (README.md excluded).
# Exit 0 clean, 1 on a violation (each printed as a GitHub error annotation), 2 on bad input.
set -uo pipefail

base="${1:-}"
head="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/scripts/ci/release/version-stamp.js"
MARKETPLACE=".claude-plugin/marketplace.json"

die() { echo "check-pr: $1" >&2; exit 2; }
[ -n "$base" ] && [ -n "$head" ] || die "usage: check-pr.sh <base-sha> <head-sha>"
git cat-file -e "$base^{commit}" 2>/dev/null || die "base $base is not a commit in this clone"
git cat-file -e "$head^{commit}" 2>/dev/null || die "head $head is not a commit in this clone"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Compare against the merge base: the PR's own changes, not whatever main gained since.
mb="$(git merge-base "$base" "$head")" || die "no merge base between $base and $head"
git diff --name-only --no-renames "$mb" "$head" > "$WORK/changed" || die "diff failed"

fails=0
err() { echo "::error file=$1::$2"; fails=$((fails + 1)); }

version_of() { # version_of <sha> <path>: the file's version, or empty when absent at <sha>
  git show "$1:$2" > "$WORK/v.json" 2>/dev/null || return 0
  node "$ENGINE" read-version "$WORK/v.json" 2>/dev/null || echo "<unreadable>"
}

while IFS= read -r f; do
  case "$f" in
    "$MARKETPLACE"|plugins/*/.claude-plugin/plugin.json) ;;
    *) continue ;;
  esac
  old="$(version_of "$mb" "$f")"
  [ -n "$old" ] || continue
  new="$(version_of "$head" "$f")"
  [ -z "$new" ] && continue
  if [ "$old" != "$new" ]; then
    err "$f" "version changed $old -> $new; the release workflow stamps versions, so revert it"
  fi
done < "$WORK/changed"

if grep -q '^plugins/' "$WORK/changed"; then
  git diff --name-only --no-renames --diff-filter=AM "$mb" "$head" -- changelog.d > "$WORK/fragments" || die "diff failed"
  if ! grep -E '^changelog\.d/[^/]+\.md$' "$WORK/fragments" | grep -vq '^changelog\.d/README\.md$'; then
    err "changelog.d" "changes under plugins/ need a changelog.d/<branch-slug>.md fragment (see changelog.d/README.md)"
  fi
fi

if [ "$fails" -gt 0 ]; then
  echo "check-pr: $fails violation(s)"
  exit 1
fi
echo "check-pr: no version edits; changelog fragment present where needed"
