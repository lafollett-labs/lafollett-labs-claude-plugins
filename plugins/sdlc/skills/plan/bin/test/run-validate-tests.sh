#!/usr/bin/env bash
# Dependency-free test harness for the BDD story validator.
# Runs validate-story.js against each fixture and asserts its exit code + summary line. bash + node only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$HERE/../validate-story.js"
FIXTURES="$HERE/fixtures"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run validator tests"
  echo "1 checks, 1 failed"
  exit 1
fi

checks=0
fails=0

# assert_file <name> <file> <expected_exit> <grep_signature|-->
# grep_signature: a line that MUST appear in output ("--" to skip the content check)
assert_file() {
  local name="$1" file="$2" expected_exit="$3" signature="$4"
  local out code
  checks=$((checks + 1))
  out="$(node "$VALIDATOR" --file "$file" 2>&1)"
  code=$?
  if [ "$code" -ne "$expected_exit" ]; then
    echo "FAIL: $name — expected exit $expected_exit, got $code"
    fails=$((fails + 1))
    return
  fi
  if [ "$signature" != "--" ] && ! grep -qF -- "$signature" <<<"$out"; then
    echo "FAIL: $name — exit $code OK but missing signature: $signature"
    fails=$((fails + 1))
    return
  fi
  echo "PASS: $name (exit $code)"
}
assert_case() { assert_file "$1" "$FIXTURES/$1" "$2" "$3"; }

echo "=== BDD validator tests ==="
# Clean stories: pass, zero failures, zero warnings.
assert_case "pass.md"                  0 "⚠ Warnings: 0"
assert_case "pass-three-scenarios.md"  0 "⚠ Warnings: 0"
# Passes but warns: pin the anti-pattern signature, distinct from the Effort-Estimate warning.
assert_case "warn-only.md"             0 "⚠ Warning: Implementation details found"
assert_case "warn-only.md"             0 '⚠ Warning: Missing "## Effort Estimate" section'
# Missing User Story / <2 scenarios / no Definition of Done: pin a specific check message.
assert_case "fail-missing-sections.md" 1 'Missing "## User Story" section'
# Two scenarios, one missing "Then": pin the Given-When-Then check message.
assert_case "fail-no-gwt.md"           1 "Incomplete Gherkin scenarios"
assert_case "does-not-exist.md"        1 "File not found"

# The story template `bdd` scaffolds must validate clean as shipped.
assert_file "assets/bdd-story-template.md validates clean" "$HERE/../../assets/bdd-story-template.md" 0 "⚠ Warnings: 0"

echo "=================================="
echo "$checks checks, $fails failed"
[ "$fails" -eq 0 ]
