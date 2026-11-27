#!/usr/bin/env bash
# Tests for scripts/ci/gate-needs.sh over synthetic `needs` JSON. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../gate-needs.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH"; exit 1; }

fails=0
total=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1 — $2"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] expected [$3]"; fi; }

# needs <title> <shellcheck> <gitleaks> <suites>: a toJSON(needs) value with those results
needs() { printf '{"title":{"result":"%s","outputs":{}},"shellcheck":{"result":"%s","outputs":{}},"gitleaks":{"result":"%s","outputs":{}},"suites":{"result":"%s","outputs":{}}}' "$@"; }
# gate <needs-json> <event> <ref> [expect]: exit code, output kept in $W/out
gate() { env NEEDS="$1" EVENT="$2" REF="$3" EXPECT="${4-4}" bash "$GATE" > "$W/out" 2>&1; echo $?; }
said() { grep -c -- "$1" "$W/out" || true; }

echo "=== gate-needs tests ==="

PR=refs/pull/7/merge
check "all passed on a PR" "$(gate "$(needs success success success success)" pull_request $PR)" 0
check "a failed job fails the gate" "$(gate "$(needs success success failure success)" pull_request $PR)" 1
check "  and names it" "$(said '::error::gitleaks: failure')" 1
check "a cancelled job fails the gate" "$(gate "$(needs success success success cancelled)" pull_request $PR)" 1
check "a skipped non-title job fails the gate" "$(gate "$(needs success skipped success success)" push refs/heads/main)" 1
check "title skipped on a PR fails" "$(gate "$(needs skipped success success success)" pull_request $PR)" 1
check "title skipped on a push passes" "$(gate "$(needs skipped success success success)" push refs/heads/main)" 0
check "title skipped on the release/next dispatch passes" \
  "$(gate "$(needs skipped success success success)" workflow_dispatch refs/heads/release/next)" 0
check "title skipped on a dispatch of any other branch fails" \
  "$(gate "$(needs skipped success success success)" workflow_dispatch refs/heads/feat/x)" 1
check "  and says why" "$(said 'only a push or the release/next dispatch may skip it')" 1
check "fewer jobs than expected fails" "$(gate '{"title":{"result":"success"}}' pull_request $PR)" 1
check "an empty needs object fails" "$(gate '{}' pull_request $PR)" 1
check "needs that are not JSON fail" "$(gate 'nope' pull_request $PR)" 1
check "no EXPECT fails" "$(gate "$(needs success success success success)" pull_request $PR '')" 1

echo "=============================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] || { echo "FAIL: no checks ran"; exit 1; }
[ "$fails" -eq 0 ] || exit 1
echo "ALL PASS"
