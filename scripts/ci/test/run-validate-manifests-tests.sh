#!/usr/bin/env sh
# Dependency-free test harness for the manifest + frontmatter validator.
# Runs validate-manifests.js against fixture repos under fixtures/ and asserts its
# exit code + a message signature. POSIX sh + node only — no npm packages, no
# network. Exit 0 = all cases pass, 1 = any fail.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VALIDATOR="$HERE/../validate-manifests.js"
FIXTURES="$HERE/fixtures"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run validator tests" >&2
  exit 1
fi
if [ ! -f "$VALIDATOR" ]; then
  echo "FAIL: validator not found at $VALIDATOR" >&2
  exit 1
fi

fails=0

# assert_case <fixture_dir> <expected_exit> <grep_signature|-->
# grep_signature: a substring that MUST appear in output ("--" to skip the content check).
# Malformed fixtures assert on a signature that names the offending file AND the violation.
assert_case() {
  fixture="$1"; expected_exit="$2"; signature="$3"
  out="$(node "$VALIDATOR" --root "$FIXTURES/$fixture" 2>&1)"
  code=$?

  if [ "$code" -ne "$expected_exit" ]; then
    echo "FAIL: $fixture — expected exit $expected_exit, got $code"
    echo "----- output -----"; echo "$out"; echo "------------------"
    fails=$((fails + 1))
    return
  fi
  if [ "$signature" != "--" ] && ! printf '%s' "$out" | grep -qF "$signature"; then
    echo "FAIL: $fixture — exit $code OK but missing signature: $signature"
    echo "----- output -----"; echo "$out"; echo "------------------"
    fails=$((fails + 1))
    return
  fi
  echo "PASS: $fixture (exit $code)"
}

echo "=== manifest + frontmatter validator tests ==="

# a well-formed repository passes cleanly (folded-scalar description included).
assert_case "good"                          0 "All manifest and frontmatter checks passed"
assert_case "good-toplevel-version"         0 "All manifest and frontmatter checks passed"

# plugin.json: existence, valid JSON, name present, semver version.
assert_case "bad-plugin-missing-json"       1 "plugin.json is missing"
assert_case "bad-plugin-invalid-json"       1 "is not valid JSON"
assert_case "bad-plugin-no-name"            1 "missing a non-empty \"name\""
assert_case "bad-plugin-bad-semver"         1 "is not valid semver"

# marketplace: valid JSON, semver metadata.version (top-level fallback), bidirectional plugin<->source consistency.
assert_case "bad-marketplace-invalid-json"  1 "is not valid JSON"
assert_case "bad-marketplace-bad-version"   1 "is not valid semver"
assert_case "bad-marketplace-unlisted-plugin" 1 "is not listed in marketplace.json"
assert_case "bad-marketplace-dangling-source" 1 "source path does not exist"

# frontmatter: parseable, name + description present (folded-scalar-safe).
assert_case "bad-skill-no-frontmatter"      1 "has no YAML frontmatter"
assert_case "bad-skill-missing-description" 1 "missing a non-empty \"description\""
assert_case "bad-skill-empty-folded"        1 "missing a non-empty \"description\""
assert_case "bad-skill-no-name"             1 "missing a non-empty \"name\""
assert_case "bad-agent-missing-description" 1 "missing a non-empty \"description\""

# name matches its directory (hyphen-case).
assert_case "bad-plugin-name-mismatch"      1 "does not match its directory"
assert_case "bad-skill-name-mismatch"       1 "does not match its directory"

# A marketplace.json that parses to a falsy JSON scalar (null/false/0/"")
#           must fail closed, not silently bypass every marketplace check.
assert_case "bad-marketplace-null"          1 "must be a JSON object"
# Inline YAML `#` comments: a valid value with a trailing comment still
#           validates; a comment-only value resolves to empty and must fail.
assert_case "good-inline-comment"           0 "All manifest and frontmatter checks passed"
assert_case "bad-skill-comment-only-description" 1 "missing a non-empty \"description\""
# Direct regression guards for agent name/frontmatter + marketplace-missing.
assert_case "bad-agent-no-name"             1 "missing a non-empty \"name\""
assert_case "bad-agent-no-frontmatter"      1 "has no YAML frontmatter"
assert_case "bad-marketplace-missing"       1 "marketplace.json is missing"

echo "=============================================="
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "$fails CASE(S) FAILED"
exit 1
