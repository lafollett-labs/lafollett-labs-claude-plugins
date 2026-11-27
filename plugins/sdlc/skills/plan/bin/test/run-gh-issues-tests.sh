#!/usr/bin/env bash
# Runs gh-issues.test.js with `node --test` (offline: every gh call goes to the shared stub gh) and
# reports each test as a PASS:/FAIL: line, then the totals.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run gh-issues tests"
  echo "1 checks, 1 failed"
  exit 1
fi

out="$(node --test --test-reporter=tap "$HERE/gh-issues.test.js" 2>&1)"
code=$?

# Top-level results only; older Node nests a file's tests under one result named after the file.
sed -nE 's/^ *not ok [0-9]+ - (.*)$/FAIL: \1/p; s/^ *ok [0-9]+ - (.*)$/PASS: \1/p' <<<"$out" | grep -v '\.test\.js$'

total="$(sed -nE 's/^# tests ([0-9]+)$/\1/p' <<<"$out" | tail -n 1)"
failed="$(sed -nE 's/^# fail ([0-9]+)$/\1/p' <<<"$out" | tail -n 1)"
if [ -z "$total" ] || [ -z "$failed" ]; then
  printf '%s\n' "$out"
  echo "FAIL: node --test printed no summary"
  echo "1 checks, 1 failed"
  exit 1
fi
if [ "$code" -ne 0 ] && [ "$failed" -eq 0 ]; then
  failed=1
fi
if [ "$failed" -ne 0 ]; then
  echo "--- node --test output ---"
  printf '%s\n' "$out" | grep -vE '^ *ok [0-9]+ - '
fi

echo "$total checks, $failed failed"
[ "$failed" -eq 0 ]
