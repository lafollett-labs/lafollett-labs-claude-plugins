#!/usr/bin/env bash
# Release orchestrator: the only half of version stamping that touches git and gh.
#
#   1. reconcile  tag every merged release commit (chore(release): vX plus a Base: trailer) that has
#                 no vX tag yet, and publish its GitHub Release from the CHANGELOG entry
#   2. stamp      plan the bumps for the commits since the newest tag (version-stamp.js plan);
#                 build ONE stamp commit on the latest main; force-push it to the release branch;
#                 open or update the release PR; dispatch CI on it; enable squash auto-merge
#   3. wait       poll the release PR up to RELEASE_MERGE_WAIT seconds; once merged, reconcile
#
# A release-titled commit without the Base: trailer is not tagged. While it is in the plan's range the
# plan may re-bump what it released, so the run leaves the release PR for a human instead of arming
# auto-merge. Paths are read with -z, so a name git would quote still matches plugins/.
#
# The release PR merges as github-actions[bot], and pushes made with GITHUB_TOKEN trigger no
# workflow, so a merge the wait misses is tagged by step 1 of the next run.
#
# Environment (defaults suit CI; the integration suite points them at a local bare repo + stub gh):
#   RELEASE_REMOTE       git remote (default origin)
#   RELEASE_MAIN_REF     default branch (default main)
#   RELEASE_BRANCH       release PR head branch (default release/next)
#   RELEASE_GH           gh binary (default gh)
#   RELEASE_CI_WORKFLOW  workflow dispatched on the release branch (default ci.yml); "" skips
#   RELEASE_MERGE_WAIT   seconds to wait for the release PR to merge (default 600); 0 skips
#   RELEASE_MERGE_POLL   seconds between polls (default 20)
#   RELEASE_DATE         changelog date (default: today, UTC)
#   RELEASE_BOT_NAME / RELEASE_BOT_EMAIL   stamp commit identity
#   GH_REPO              owner/repo for gh (default: the remote of the current checkout)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${RELEASE_ENGINE:-$HERE/version-stamp.js}"
REMOTE="${RELEASE_REMOTE:-origin}"
MAIN="${RELEASE_MAIN_REF:-main}"
BRANCH="${RELEASE_BRANCH:-release/next}"
GH="${RELEASE_GH:-gh}"
CI_WORKFLOW="${RELEASE_CI_WORKFLOW-ci.yml}"
WAIT="${RELEASE_MERGE_WAIT:-600}"
POLL="${RELEASE_MERGE_POLL:-20}"
TODAY="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
BOT_NAME="${RELEASE_BOT_NAME:-github-actions[bot]}"
BOT_EMAIL="${RELEASE_BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
MARKETPLACE=".claude-plugin/marketplace.json"
CHANGELOG="CHANGELOG.md"
FRAGMENTS="changelog.d"
TAG_PREFIX="v"

log() { echo "[release] $*"; }
die() { echo "[release] ERROR: $*" >&2; exit 1; }
engine() { node "$ENGINE" "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v git >/dev/null 2>&1 || die "git not on PATH"
command -v node >/dev/null 2>&1 || die "node not on PATH"
[ -f "$ENGINE" ] || die "engine not found at $ENGINE"
[ -f "$MARKETPLACE" ] || die "$MARKETPLACE not found: run from the repo root"
case "$WAIT$POLL" in *[!0-9]*) die "RELEASE_MERGE_WAIT and RELEASE_MERGE_POLL must be whole seconds" ;; esac
[ "$POLL" -gt 0 ] || die "RELEASE_MERGE_POLL must be > 0"

git config user.name "$BOT_NAME"
git config user.email "$BOT_EMAIL"

# Fail closed on fetch: stale local tags could read as "already released" or mis-anchor the baseline.
fetch_state() {
  git fetch --quiet --tags --prune --prune-tags "$REMOTE" || die "could not fetch tags from $REMOTE"
  git fetch --quiet "$REMOTE" "$MAIN" || die "could not fetch $MAIN from $REMOTE"
  MAIN_SHA="$(git rev-parse FETCH_HEAD)" || die "could not resolve $MAIN"
}

newest_tag() { git tag -l "${TAG_PREFIX}[0-9]*" --sort=-v:refname | head -n 1; }

# create_tag <tag> <sha>: through the REST API, then locally. A GITHUB_TOKEN `git push` of a tag onto
# a commit whose workflow files differ from the default branch's can be refused; the API is not.
create_tag() {
  "$GH" api "repos/{owner}/{repo}/git/refs" -f "ref=refs/tags/$1" -f "sha=$2" >/dev/null \
    || die "failed to create tag $1 at $2"
  git tag "$1" "$2" || die "failed to create local tag $1"
}

# First run: seed the baseline at the first parent of the merge that activated this workflow, so
# that merge's own change is the first thing stamped and history before it is never re-released.
seed_baseline() {
  local seed v tag
  seed="$(git rev-parse -q --verify "$MAIN_SHA^1")" || die "cannot seed: $MAIN has no first parent"
  git show "$seed:$MARKETPLACE" > "$WORK/seed.json" 2>/dev/null || die "no $MARKETPLACE at $MAIN^1"
  v="$(engine read-version "$WORK/seed.json")" || die "cannot read the seed marketplace version"
  tag="$TAG_PREFIX$v"
  create_tag "$tag" "$seed"
  log "first run: seeded baseline $tag at $MAIN^1"
}

# publish_release <tag> <sha> <version>: GitHub Release from the CHANGELOG entry at <sha>. Idempotent.
publish_release() {
  local tag="$1" sha="$2" version="$3"
  if "$GH" release view "$tag" >/dev/null 2>&1; then
    log "release $tag already published"
    return 0
  fi
  git show "$sha:$CHANGELOG" > "$WORK/changelog-at.md" 2>/dev/null || : > "$WORK/changelog-at.md"
  engine changelog-entry --file "$WORK/changelog-at.md" --version "$version" > "$WORK/notes.md" || die "cannot extract notes for $tag"
  [ -s "$WORK/notes.md" ] || echo "Release $tag" > "$WORK/notes.md"
  "$GH" release create "$tag" --verify-tag --title "$tag" --notes-file "$WORK/notes.md" >/dev/null \
    || die "failed to publish GitHub Release $tag"
  log "published release $tag"
}

reconcile() {
  local base sha subject v at tag built_on
  base="$(newest_tag)"
  [ -n "$base" ] || return 0
  git log --reverse --format='%H %s' "$base..$MAIN_SHA" > "$WORK/since.txt" || die "cannot list commits since $base"
  while read -r sha subject; do
    v="$(engine release-version --subject "$subject" 2>/dev/null)" || continue
    # Only the release workflow's squash carries the Base: trailer; a look-alike subject is a plain commit.
    built_on="$(git log -1 --format=%b "$sha" | sed -n 's/^Base: \([0-9a-f]\{40\}\)$/\1/p' | head -n 1)"
    if [ -z "$built_on" ]; then
      echo "::warning::$sha is titled like a release but has no Base: trailer, so it is not tagged"
      # Keep the latest: the hold checks only HELD against BASE, and if any such title is past BASE, the latest is.
      HELD="$sha"; HELD_TAG="$TAG_PREFIX$v"
      continue
    fi
    git show "$sha:$MARKETPLACE" > "$WORK/at.json" 2>/dev/null || die "no $MARKETPLACE at $sha"
    at="$(engine read-version "$WORK/at.json")" || die "cannot read the marketplace version at $sha"
    [ "$at" = "$v" ] || die "release commit $sha says v$v but its marketplace version is $at"
    tag="$TAG_PREFIX$v"
    # Strict up-to-date checks make the stamp's base its merge parent; anything else means commits
    # merged in between shipped inside this release without a bump of their own.
    if [ "$built_on" != "$(git rev-parse "$sha^1")" ]; then
      echo "::warning::$tag was stamped on $built_on but merged onto $(git rev-parse "$sha^1"): commits in between were not bumped"
    fi
    if [ -n "$(git tag -l "$tag")" ]; then
      [ "$(git rev-parse "$tag^{commit}")" = "$sha" ] || die "tag $tag exists on another commit"
    else
      create_tag "$tag" "$sha"
      log "tagged $tag at $sha"
    fi
    publish_release "$tag" "$sha" "$v"
  done < "$WORK/since.txt"
}

# open_pr <title> <body-file>: prints the open release PR number, creating the PR if needed.
open_pr() {
  local title="$1" body="$2" num url
  num="$("$GH" pr list --head "$BRANCH" --base "$MAIN" --state open --json number --jq '.[0].number // empty')" \
    || die "cannot list release PRs"
  if [ -n "$num" ]; then
    "$GH" pr edit "$num" --title "$title" --body-file "$body" >/dev/null || die "cannot update release PR #$num"
  else
    url="$("$GH" pr create --base "$MAIN" --head "$BRANCH" --title "$title" --body-file "$body")" \
      || die "cannot open the release PR (is 'Allow GitHub Actions to create and approve pull requests' on?)"
    num="${url##*/}"
  fi
  case "$num" in ''|*[!0-9]*) die "unexpected PR reference: $num" ;; esac
  echo "$num"
}

fetch_state
[ -n "$(newest_tag)" ] || seed_baseline
HELD=
HELD_TAG=
reconcile

BASE="$(newest_tag)"
log "baseline $BASE, $MAIN at $MAIN_SHA"
# Hold only for a trailer-less release title this plan reads; a release tagged after it moved BASE past it.
if [ -n "$HELD" ] && ! git merge-base --is-ancestor "$BASE^{commit}" "$HELD"; then HELD=; fi

git log --reverse --no-merges -z --format='%x1e%H%x1f%s%x1f%b%x1f' --name-only "$BASE..$MAIN_SHA" > "$WORK/log" \
  || die "change detection failed against $BASE"
git show "$BASE:$MARKETPLACE" > "$WORK/before.json" 2>/dev/null || die "no $MARKETPLACE at $BASE"
git show "$MAIN_SHA:$MARKETPLACE" > "$WORK/after.json" || die "no $MARKETPLACE at $MAIN"
engine plan --log "$WORK/log" --before "$WORK/before.json" --after "$WORK/after.json" > "$WORK/plan" \
  || die "release planning failed"

if ! grep -q '^marketplace ' "$WORK/plan"; then
  log "no plugin or marketplace change since $BASE: nothing to release"
  exit 0
fi

git checkout --quiet --detach "$MAIN_SHA" || die "cannot check out $MAIN_SHA"

spec=""
while read -r kind name level; do
  case "$kind" in
    plugin)
      pj="plugins/$name/.claude-plugin/plugin.json"
      [ -f "$pj" ] || die "$pj is missing for changed plugin $name"
      newv="$(engine bump-file "$pj" "$level")" || die "failed to bump $pj"
      git add "$pj"
      spec="$spec,$name@$newv"
      log "bump $name -> $newv ($level)"
      ;;
    new)
      pj="plugins/$name/.claude-plugin/plugin.json"
      authored="$(engine read-version "$pj")" || die "cannot read the authored version of $pj"
      spec="$spec,$name@$authored!new"
      log "debut $name at $authored"
      ;;
    marketplace)
      mkt_level="$name"
      ;;
    *) die "unknown plan line: $kind $name $level" ;;
  esac
done < "$WORK/plan"
spec="${spec#,}"

VERSION="$(engine bump-file "$MARKETPLACE" "$mkt_level")" || die "failed to bump $MARKETPLACE"
git add "$MARKETPLACE"
TAG="$TAG_PREFIX$VERSION"
TITLE="chore(release): $TAG"
log "marketplace -> $VERSION ($mkt_level)"

engine changelog-release --file "$CHANGELOG" --version "$VERSION" --date "$TODAY" --plugins "$spec" \
  --fragments-dir "$FRAGMENTS" --log "$WORK/log" > "$WORK/entry.md" || die "changelog update failed"
git add "$CHANGELOG"
if [ -d "$FRAGMENTS" ]; then
  find "$FRAGMENTS" -maxdepth 1 -type f -name '*.md' ! -name README.md -exec git rm --quiet {} + \
    || die "failed to remove released changelog fragments"
fi

plugins_line="$(grep -m1 '^\*\*Plugins:\*\*' "$WORK/entry.md")"
git commit --quiet -m "$TITLE" -m "$plugins_line" -m "Base: $MAIN_SHA" || die "stamp commit failed"
STAMP="$(git rev-parse HEAD)"

# Re-pushing an identical stamp would only give the PR a new head SHA and restart its checks.
pushed=yes
if git fetch --quiet "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null; then
  remote_sha="$(git rev-parse FETCH_HEAD)"
  if [ "$(git rev-parse "$remote_sha^1" 2>/dev/null)" = "$MAIN_SHA" ] \
    && [ "$(git rev-parse "$remote_sha^{tree}")" = "$(git rev-parse "$STAMP^{tree}")" ]; then
    pushed=no
    log "$BRANCH already carries this stamp"
  fi
fi
if [ "$pushed" = yes ]; then
  git push --quiet --force "$REMOTE" "$STAMP:refs/heads/$BRANCH" \
    || die "failed to push $BRANCH. If GitHub refused it because the stamp commit's base changes a workflow file, close the release PR, delete $BRANCH, and re-run this workflow"
  log "pushed $STAMP to $BRANCH"
fi

{
  echo "Automated release stamp for the commits since \`$BASE\`."
  echo
  cat "$WORK/entry.md"
  echo
  echo "Merging tags \`$TAG\` and publishes its GitHub Release. Edit nothing here: the next merge to"
  echo "\`$MAIN\` regenerates this branch. Merge it without editing the squash message: its \`Base:\`"
  echo "trailer marks the release, and a release squash without one is not tagged."
} > "$WORK/body.md"

PR="$(open_pr "$TITLE" "$WORK/body.md")" || exit 1
log "release PR #$PR"

# PRs opened with GITHUB_TOKEN trigger no pull_request run, so the required checks are dispatched.
# Every run dispatches, pushed or not: a re-run after a failed dispatch must still give the head its checks.
if [ -n "$CI_WORKFLOW" ]; then
  "$GH" workflow run "$CI_WORKFLOW" --ref "$BRANCH" >/dev/null || die "cannot dispatch $CI_WORKFLOW on $BRANCH"
  log "dispatched $CI_WORKFLOW on $BRANCH"
fi

if [ -n "$HELD" ]; then
  "$GH" pr merge "$PR" --disable-auto >/dev/null 2>&1 \
    || echo "::warning::could not turn off auto-merge on release PR #$PR (it may already be off); check that it is off"
  echo "::warning::release PR #$PR is left for a human: $HELD has a release title but no Base: trailer, so this stamp may bump its plugins again. If $HELD is the release PR's squash, release it by hand (gh release create $HELD_TAG --target $HELD), close #$PR, and re-run this workflow; otherwise merge #$PR by hand"
  exit 0
fi

"$GH" pr merge "$PR" --auto --squash --subject "$TITLE" --body "$plugins_line

Base: $MAIN_SHA" >/dev/null \
  || echo "::warning::could not enable auto-merge on release PR #$PR (is 'Allow auto-merge' on?); merge it by hand"

[ "$WAIT" -gt 0 ] || exit 0
waited=0
while [ "$waited" -lt "$WAIT" ]; do
  state="$("$GH" pr view "$PR" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
  case "$state" in
    MERGED)
      log "release PR #$PR merged"
      fetch_state
      reconcile
      exit 0
      ;;
    CLOSED) die "release PR #$PR was closed without merging" ;;
  esac
  sleep "$POLL"
  waited=$((waited + POLL))
done
echo "::warning::release PR #$PR not merged after ${WAIT}s; the next release run tags it"
exit 0
