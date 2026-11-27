#!/usr/bin/env bash
# The required check's last step: pass only when every job it needs passed.
#   NEEDS   toJSON(needs) of the job          EVENT  github.event_name
#   EXPECT  how many jobs it needs            REF    github.ref
# `title` runs on pull requests only. It may be skipped on a push, or on the release workflow's
# dispatch of release/next; a dispatch on any other branch would clear a PR's head without it.
set -uo pipefail
die() { echo "::error::gate-needs: $1"; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq not on PATH"
n="$(jq -e 'if type == "object" then length else error end' <<<"${NEEDS:-}" 2>/dev/null)" || die "NEEDS is not a JSON object"
[ "$n" = "${EXPECT:-}" ] || die "expected ${EXPECT:-?} jobs in needs, found $n"
fail=0
while read -r job result; do
  case "$job:$result" in
    *:success) echo "  ok    $job" ;;
    title:skipped)
      if [ "${EVENT:-}" = push ] || { [ "${EVENT:-}" = workflow_dispatch ] && [ "${REF:-}" = refs/heads/release/next ]; }; then
        echo "  skip  title (${EVENT:-} ${REF:-})"
      else
        echo "::error::title was skipped on ${EVENT:-?} ${REF:-?}; only a push or the release/next dispatch may skip it"
        fail=1
      fi ;;
    *) echo "::error::$job: $result"; fail=1 ;;
  esac
done < <(jq -r 'to_entries[] | "\(.key) \(.value.result)"' <<<"$NEEDS")
exit "$fail"
