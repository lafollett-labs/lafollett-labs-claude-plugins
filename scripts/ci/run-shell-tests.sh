#!/usr/bin/env bash
# Discovery-based deterministic shell-test runner.
#
# Finds every `plugins/**/bin/test/run-*.sh` and `scripts/ci/**/test/run-*.sh` suite, runs them in
# parallel (SHELL_TEST_JOBS at a time, default the CPU count), and aggregates exit codes: ANY non-zero suite fails the run. A new suite that follows the
# `test/run-*.sh` convention is discovered with no workflow edit.
#
# Deterministic: no network, no time/order dependence (discovery is sorted; output is printed in that order). Requires bash, node,
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

# Suites are independent (each owns its mktemp dirs), so they run in parallel: SHELL_TEST_JOBS at a time
# (default: the CPU count). Each suite's output is buffered and printed whole, in sorted order, so the log
# reads the same as a serial run. A suite whose worker died (no exit code recorded) counts as failed.
jobs="${SHELL_TEST_JOBS:-}"
[ -n "$jobs" ] || jobs="$( { nproc || sysctl -n hw.ncpu; } 2>/dev/null )"
case "$jobs" in ''|*[!0-9]*|0) jobs=2 ;; esac
OUT="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; wait; rm -rf "$OUT"' EXIT

# run_one <index> <suite> — run one suite, recording its output, exit code and seconds under $OUT, and print a
# start and a finish line as it goes, so a suite that hangs until the job times out is the one never finished.
# A suite that parallelizes inside (PE_TEST_JOBS) gets 2 workers, so the runner does not oversubscribe the CPUs.
run_one() {
  local t0 rc
  t0=$(date +%s)
  echo "... start: $2"
  PE_TEST_JOBS="${PE_TEST_JOBS:-2}" bash "$2" > "$OUT/$1.log" 2>&1 < /dev/null
  rc=$?
  echo "$rc" > "$OUT/$1.rc"
  echo $(( $(date +%s) - t0 )) > "$OUT/$1.t"
  echo "... done:  $2 (exit $rc, $(cat "$OUT/$1.t")s)"
}

# Split on newlines only, so suite paths containing spaces survive.
i=0
while IFS= read -r suite; do
  i=$((i + 1))
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do sleep 0.1; done
  run_one "$i" "$suite" &
done <<EOF
$suites
EOF
wait
echo "================================================"

total=0
failed=0
failed_suites=""
i=0
while IFS= read -r suite; do
  i=$((i + 1))
  total=$((total + 1))
  echo "=== RUN: $suite ==="
  cat "$OUT/$i.log" 2>/dev/null
  code="$(cat "$OUT/$i.rc" 2>/dev/null)"
  [ -n "$code" ] || code="no exit code, the suite's worker died"
  secs="$(cat "$OUT/$i.t" 2>/dev/null || echo '?')"
  if [ "$code" = 0 ]; then
    echo "--- PASS: $suite (${secs}s)"
  else
    echo "--- FAIL: $suite (exit $code, ${secs}s)"
    failed=$((failed + 1))
    failed_suites="${failed_suites}  - ${suite} (exit ${code})
"
  fi
done <<EOF
$suites
EOF

echo "================================================"
echo "shell test suites: $total total, $failed failed ($jobs at a time)"
if [ "$failed" -ne 0 ]; then
  printf 'failed suites:\n%s' "$failed_suites"
  exit 1
fi
echo "ALL SUITES PASS"
exit 0
