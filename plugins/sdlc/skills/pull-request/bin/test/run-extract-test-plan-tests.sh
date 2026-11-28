#!/usr/bin/env bash
# Tests for the Test-Plan extractor: exit code, verbatim stdout, section-boundary isolation,
# CRLF hygiene and empty output. Offline; bash + node only. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR="$HERE/../extract-test-plan.js"
FIXTURES="$HERE/fixtures"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run extractor tests" >&2
  exit 1
fi

total=0
fails=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); fails=$((fails + 1)); echo "FAIL: $1"; }

# assert_verbatim <fixture> <expected_file> — stdout must match expected (trailing newlines ignored).
assert_verbatim() {
  local fixture="$1" expected="$2" out code
  out="$(node "$EXTRACTOR" --file "$FIXTURES/$fixture" 2>/dev/null)"
  code=$?
  if [ "$code" -ne 0 ]; then fail "$fixture — expected exit 0, got $code"; return; fi
  if [ "$out" != "$(cat "$FIXTURES/$expected")" ]; then
    fail "$fixture — stdout did not match $expected verbatim; got: [$out]"; return
  fi
  pass "$fixture (verbatim match)"
}

# assert_bytes <fixture> <expected_file> — byte-exact match INCLUDING trailing newlines, which
# command substitution would strip.
assert_bytes() {
  local fixture="$1" expected="$2" tmp code
  tmp="$(mktemp)"
  node "$EXTRACTOR" --file "$FIXTURES/$fixture" >"$tmp" 2>/dev/null
  code=$?
  if [ "$code" -ne 0 ]; then fail "$fixture — expected exit 0, got $code"
  elif ! cmp -s "$tmp" "$FIXTURES/$expected"; then fail "$fixture — byte mismatch vs $expected"
  else pass "$fixture (byte-exact match)"
  fi
  rm -f "$tmp"
}

# assert_case <fixture> <expected_exit> <grep_signature|-->
assert_case() {
  local fixture="$1" expected_exit="$2" signature="$3" out code
  out="$(node "$EXTRACTOR" --file "$FIXTURES/$fixture" 2>/dev/null)"
  code=$?
  if [ "$code" -ne "$expected_exit" ]; then fail "$fixture — expected exit $expected_exit, got $code"; return; fi
  if [ "$signature" != "--" ] && ! grep -qF -- "$signature" <<<"$out"; then
    fail "$fixture — exit $code OK but missing signature: $signature"; return
  fi
  pass "$fixture (exit $code)"
}

# assert_empty <fixture> — exit 0 AND zero-byte stdout (the fallback signal for Phase 5).
assert_empty() {
  local fixture="$1" out code
  out="$(node "$EXTRACTOR" --file "$FIXTURES/$fixture" 2>/dev/null)"
  code=$?
  if [ "$code" -ne 0 ]; then fail "$fixture — expected exit 0, got $code"; return; fi
  if [ -n "$out" ]; then fail "$fixture — expected empty stdout but got: $out"; return; fi
  pass "$fixture (empty stdout, exit 0)"
}

# refute <fixture> <needle> — <needle> must NOT appear in stdout.
refute() {
  local fixture="$1" needle="$2" out
  out="$(node "$EXTRACTOR" --file "$FIXTURES/$fixture" 2>/dev/null)"
  if grep -qF -- "$needle" <<<"$out"; then fail "$fixture — leaked out-of-section content: $needle"; return; fi
  pass "$fixture (no leak of: $needle)"
}

echo "=== Test-Plan extractor tests ==="

# Verbatim extraction: items only, exactly as authored.
assert_verbatim "tp-verbatim.md"     "tp-verbatim.expected"
assert_bytes    "tp-verbatim.md"     "tp-verbatim.expected"
# Section boundary: the following ## Dependencies block must NOT leak.
refute          "tp-verbatim.md"     "Story 15 (test-plan authoring)"
refute          "tp-verbatim.md"     "## Test Plan"
refute          "tp-verbatim.md"     "## Dependencies"

# An H3 inside the section is preserved (the boundary is ^#{1,2}\s); the trailing ## block is excluded.
assert_bytes    "tp-h3-subheading.md" "tp-h3-subheading.expected"
assert_case     "tp-h3-subheading.md" 0 "### Sub detail"
refute          "tp-h3-subheading.md" "## Dependencies"
refute          "tp-h3-subheading.md" "trailing H2 block must be excluded"

# A trailing H1 after the Test Plan terminates the section.
assert_bytes    "tp-trailing-h1.md"   "tp-trailing-h1.expected"
refute          "tp-trailing-h1.md"   "Trailing H1"
refute          "tp-trailing-h1.md"   "must NOT leak"

# Test Plan as the final section (EOF boundary) still extracts.
assert_case     "tp-last-section.md" 0 "- [ ] Final item at end of file"
refute          "tp-last-section.md" "## Description"

# A "## Test Plan" inside a fenced code example is not the section: the real one is extracted,
# and a body whose only Test Plan heading is fenced emits nothing.
assert_bytes    "tp-fenced-heading.md" "tp-fenced-heading.expected"
assert_empty    "tp-fenced-only.md"
# A line starting with a one-line ```span``` is inline code, not a fence.
assert_bytes    "tp-inline-span.md"    "tp-inline-span.expected"
# A fence line with an info string never closes a block: the bare fence after it does.
assert_bytes    "tp-fence-info-line.md" "tp-fence-info-line.expected"

# No Test Plan section, or a header with an empty body → nothing emitted.
assert_empty    "tp-no-section.md"
assert_empty    "tp-empty-section.md"

# CRLF body → item present and NO carriage return leaks into output.
assert_case     "tp-crlf.md"         0 "- [ ] Criterion authored with CRLF line endings"
crlf_out="$(node "$EXTRACTOR" --file "$FIXTURES/tp-crlf.md" 2>/dev/null)"
if printf '%s' "$crlf_out" | grep -q $'\r'; then
  fail "tp-crlf.md — output contains a carriage return"
else
  pass "tp-crlf.md (no carriage return in output)"
fi

# Missing file and missing --file → usage/IO error, exit 1.
node "$EXTRACTOR" --file "$FIXTURES/does-not-exist.md" >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "missing file (exit 1)"; else fail "missing file — expected exit 1"; fi
node "$EXTRACTOR" >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "missing --file arg (exit 1)"; else fail "missing --file arg — expected exit 1"; fi

echo "$total checks, $fails failed"
[ "$fails" -eq 0 ]
