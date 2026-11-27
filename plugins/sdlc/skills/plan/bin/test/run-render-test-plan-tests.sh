#!/usr/bin/env bash
# Dependency-free test harness for the Test-Plan renderer.
# Runs render-test-plan.js against each fixture and asserts exit code, stdout
# content, checkbox count, or empty output. bash + node only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDERER="$HERE/../render-test-plan.js"
FIXTURES="$HERE/fixtures"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run renderer tests"
  echo "1 checks, 1 failed"
  exit 1
fi

checks=0
fails=0

# verdict <name> <ok: 0|1> <failure detail>
verdict() {
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — $3"
    fails=$((fails + 1))
  fi
}

# assert_case <fixture> <expected_exit> <grep_signature|-->
# grep_signature: a line that MUST appear in stdout ("--" to skip the content check)
assert_case() {
  local fixture="$1" expected_exit="$2" signature="$3"
  local out code
  checks=$((checks + 1))
  out="$(node "$RENDERER" --file "$FIXTURES/$fixture" 2>/dev/null)"
  code=$?
  if [ "$code" -ne "$expected_exit" ]; then
    echo "FAIL: $fixture — expected exit $expected_exit, got $code"
    fails=$((fails + 1)); return
  fi
  if [ "$signature" != "--" ] && ! grep -qF -- "$signature" <<<"$out"; then
    echo "FAIL: $fixture — exit $code OK but missing signature: $signature"
    fails=$((fails + 1)); return
  fi
  echo "PASS: $fixture (exit $code)"
}

# assert_empty <fixture> — exit 0 AND zero-byte stdout (proves "no empty scaffold")
assert_empty() {
  local fixture="$1" out code
  checks=$((checks + 1))
  out="$(node "$RENDERER" --file "$FIXTURES/$fixture" 2>/dev/null)"
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "FAIL: $fixture — expected exit 0, got $code"
    fails=$((fails + 1)); return
  fi
  if [ -n "$out" ]; then
    echo "FAIL: $fixture — expected empty stdout but got: $out"
    fails=$((fails + 1)); return
  fi
  echo "PASS: $fixture (empty stdout, exit 0)"
}

# assert_count <fixture> <expected_checkbox_count>
assert_count() {
  local fixture="$1" expected="$2" out code n
  checks=$((checks + 1))
  out="$(node "$RENDERER" --file "$FIXTURES/$fixture" 2>/dev/null)"
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "FAIL: $fixture — expected exit 0, got $code"
    fails=$((fails + 1)); return
  fi
  n="$(grep -c '^- \[ \] ' <<<"$out")"
  if [ "$n" -ne "$expected" ]; then
    echo "FAIL: $fixture — expected $expected checkbox(es), got $n"
    fails=$((fails + 1)); return
  fi
  echo "PASS: $fixture ($n checkbox(es))"
}

echo "=== Test-Plan renderer tests ==="

# Gherkin scenarios → one checkbox per scenario title; DoD checkboxes excluded.
assert_case  "tp-two-scenarios.md"   0 "## Test Plan"
assert_case  "tp-two-scenarios.md"   0 "- [ ] Search returns matching books"
assert_case  "tp-two-scenarios.md"   0 "- [ ] Search with no matches shows empty state"
assert_count "tp-two-scenarios.md"   2

# Bullet ACs → one checkbox per bullet; marker not doubled; out-of-section bullet ignored.
assert_case  "tp-bullet-acs.md"      0 "- [ ] Member can filter books by genre"
assert_count "tp-bullet-acs.md"      3

# No AC section → nothing emitted.
assert_empty "tp-no-acs.md"
# AC header present but empty section, next H2 is DoD → nothing emitted (boundary).
assert_empty "tp-empty-ac-section.md"
# Unfilled template placeholders → skipped → nothing emitted.
assert_empty "tp-template-stubs.md"

# Duplicate ACs → dedup collapses identical items (pins the seen.has() branch).
assert_count "tp-duplicate-acs.md"   2
# Mixed dialect → scenarios win; a stray bullet in the same section is ignored.
assert_case  "tp-mixed-dialect.md"   0 "- [ ] Scenario title wins over bullets"
assert_count "tp-mixed-dialect.md"   1
mixed_out="$(node "$RENDERER" --file "$FIXTURES/tp-mixed-dialect.md" 2>/dev/null)"
! grep -qF -- "This bullet must be ignored" <<<"$mixed_out"
verdict "tp-mixed-dialect.md (bullet ignored)" $? "bullet leaked despite scenario precedence"
# Star/plus unordered bullets are harvested, not just '-'.
assert_count "tp-star-bullets.md"    2
# Fenced code is never a criterion: a fenced "## Acceptance Criteria" example is not the section,
# and a fenced "## …" line or bullet inside the real section neither ends it nor is harvested.
assert_count "tp-fenced-ac.md"       2
assert_case  "tp-fenced-ac.md"       0 "- [ ] Real two"
# A line starting with a one-line ```span``` is inline code, not a fence opener.
assert_count "tp-inline-span-ac.md"  1
# A fence line with an info string never closes a block: the bare fence after it does.
assert_count "tp-fence-info-line.md" 2
# CRLF body → checkbox present and no carriage return leaks into output.
assert_case  "tp-crlf.md"            0 "- [ ] Criterion authored with CRLF line endings"
crlf_out="$(node "$RENDERER" --file "$FIXTURES/tp-crlf.md" 2>/dev/null)"
! printf '%s' "$crlf_out" | grep -q $'\r'
verdict "tp-crlf.md (no carriage return in output)" $? "output contains a carriage return"

# Header appears exactly once in a positive case.
tp_out="$(node "$RENDERER" --file "$FIXTURES/tp-two-scenarios.md" 2>/dev/null)"
[ "$(grep -c '^## Test Plan$' <<<"$tp_out")" -eq 1 ]
verdict "single canonical header" $? "expected exactly one '## Test Plan' header"

# Missing file → usage/IO error, exit 1.
node "$RENDERER" --file "$FIXTURES/does-not-exist.md" >/dev/null 2>&1
[ $? -eq 1 ]
verdict "missing file (exit 1)" $? "expected exit 1"

# Missing --file arg → usage error, exit 1.
node "$RENDERER" >/dev/null 2>&1
[ $? -eq 1 ]
verdict "missing --file arg (exit 1)" $? "expected exit 1"

echo "=========================================="
echo "$checks checks, $fails failed"
[ "$fails" -eq 0 ]
