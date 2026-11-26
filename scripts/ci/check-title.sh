#!/usr/bin/env bash
# The PR title gate. The squash commit sets the release level, and GitHub squashes a one-commit PR
# under that commit's message, so a lone commit must pass too and release at the title's level.
# chore(release): vX belongs to this repo's release/next PR.
#   TITLE     the PR title            COMMITS    the PR's commit count
#   HEAD_REF  the PR head branch      HEAD_REPO  the head repo (owner/name)    REPO  this repo
# Run from a checkout of the PR head. Exit 0 pass, 1 fail.
set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release/version-stamp.js"
command -v node >/dev/null 2>&1 || { echo "::error::check-title: node not on PATH"; exit 1; }

release_pr=no
[ -n "${REPO:-}" ] && [ "${HEAD_REF:-}" = release/next ] && [ "${HEAD_REPO:-}" = "$REPO" ] && release_pr=yes
rc=0
check_subject() { # check_subject <what> <subject>
  if ! node "$ENGINE" subject-check --subject "$2"; then
    echo "::error::$1 is not a conventional commit (type(scope)!: description): $2"; rc=1
  elif [ "$release_pr" = no ] && node "$ENGINE" release-version --subject "$2" >/dev/null 2>&1; then
    echo "::error::$1 uses the release subject, which only the release workflow's PR may: $2"; rc=1
  fi
}

check_subject "PR title" "${TITLE:-}"
level="$(node "$ENGINE" level --subject "${TITLE:-}" 2>/dev/null)"
note=", or major if a commit message carries a BREAKING CHANGE: footer"
if [ "${COMMITS:-}" = 1 ]; then
  body="$(mktemp)"
  trap 'rm -f "$body"' EXIT
  if ! subject="$(git log -1 --format=%s HEAD)" || ! git log -1 --format=%b HEAD > "$body"; then
    echo "::error::check-title: cannot read the PR's commit"; exit 1
  fi
  check_subject "the PR's only commit (the squash subject)" "$subject"
  lone="$(node "$ENGINE" level --subject "$subject" --body-file "$body" 2>/dev/null)"
  if [ "$rc" -eq 0 ] && [ "$lone" != "$level" ]; then
    echo "::error::a one-commit PR squashes under its commit's message, which releases $lone where the title releases $level; match the type, ! and any BREAKING CHANGE: footer: $subject"
    rc=1
  fi
  level="$lone"
  note=""
fi
[ "$rc" -eq 0 ] && echo "release level: $level$note"
exit "$rc"
