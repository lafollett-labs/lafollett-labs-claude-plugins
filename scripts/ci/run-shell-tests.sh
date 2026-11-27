#!/usr/bin/env bash
# Discovery-based deterministic shell-test runner.
#
# Finds every `plugins/**/bin/test/run-*.sh` and `scripts/ci/**/test/run-*.sh` suite, runs each,
# and aggregates exit codes: ANY non-zero suite fails the run. A new suite that follows the
# `test/run-*.sh` convention is discovered with no workflow edit.
#
# Deterministic: no network, no time/order dependence (discovery is sorted). Requires bash, node,
# python3 3.11+ and gitleaks v8.25+ on PATH (the suites run node validators, check-allowlist.py and gitleaks).
set -u

# Repo root = two levels up from scripts/ci/, so the runner works from any CWD.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL: cannot cd to repo root $ROOT" >&2; exit 1; }

# Sorted discovery — find's order is unspecified, so sort for a deterministic run order.
suites="$( { find plugins -type f -path '*/bin/test/run-*.sh'; find scripts/ci -type f -path '*/test/run-*.sh'; } | sort)"

if [ -z "$suites" ]; then
  # Fail CLOSED: this repo ships suites, so zero discovery signals a broken glob or a moved
  # convention — not a legitimate empty run. A green job that ran no tests would silently
  # evaporate the gate. ALLOW_ZERO_SUITES=1 is the explicit opt-out for a genuine bootstrap.
  if [ "${ALLOW_ZERO_SUITES:-0}" = "1" ]; then
    echo "WARNING: no shell test suites discovered (ALLOW_ZERO_SUITES=1 — passing anyway)"
    exit 0
  fi
  echo "FAIL: no shell test suites discovered under plugins/**/bin/test/ or scripts/ci/**/test/." >&2
  echo "      This repo ships suites, so zero discovery signals a broken glob or a moved" >&2
  echo "      convention — failing closed. Set ALLOW_ZERO_SUITES=1 to allow an empty run." >&2
  exit 1
fi

total=0
failed=0
failed_suites=""

# Split on newlines only, so suite paths containing spaces survive.
OLDIFS="$IFS"
IFS='
'
for suite in $suites; do
  total=$((total + 1))
  echo "=== RUN: $suite ==="
  bash "$suite"
  code=$?
  if [ "$code" -eq 0 ]; then
    echo "--- PASS: $suite"
  else
    echo "--- FAIL: $suite (exit $code)"
    failed=$((failed + 1))
    failed_suites="${failed_suites}  - ${suite} (exit ${code})
"
  fi
done
IFS="$OLDIFS"

echo "================================================"
echo "shell test suites: $total total, $failed failed"
if [ "$failed" -ne 0 ]; then
  printf 'failed suites:\n%s' "$failed_suites"
  exit 1
fi
echo "ALL SUITES PASS"
exit 0
