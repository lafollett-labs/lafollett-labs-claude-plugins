#!/usr/bin/env bash
# Fixture tests for plan-review.js — the incident-mode plan gate's verdict parser and issue comment renderer.
# Each case feeds a reviewer reply (fixtures/plan-review/*.md) or a parse result and asserts the JSON or markdown out.
# No npm packages — bash + node only. Ends with "<n> checks, <m> failed"; exit 1 on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../plan-review.js"
FX="$HERE/fixtures/plan-review"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run plan-review tests" >&2
  exit 1
fi
if [ ! -f "$CLI" ]; then
  echo "FAIL: plan-review.js not found at $CLI" >&2
  exit 1
fi

checks=0
fails=0
pass() { checks=$((checks + 1)); echo "PASS: $1"; }
fail() { checks=$((checks + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }

# check <name> <json> <js-boolean-expression over `o`>
check() {
  local name="$1" json="$2" expr="$3"
  if node -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$json" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — got: $json"
  fi
}
# contains <name> <text> <fixed-string>
contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 — missing '$3' in: $2" ;; esac
}
# expect_code <name> <got> <want>
expect_code() {
  if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1 — exit $2 (want $3)"; fi
}
parse() { node "$CLI" parse --round "$2" < "$FX/$1"; }

# --- happy paths -----------------------------------------------------------------
check "APPROVE with passing checks, a rollback and a prevention follow-up approves" "$(parse approve.md 1)" \
  'o.decision === "approve" && o.verdict === "APPROVE" && o.round === 1 && o.adjustments.length === 1 && o.rollback !== "" && o.follow_ups.length === 1 && o.errors.length === 0'
check "REVISE in round 1 asks for a revision and keeps the removed scope as a follow-up" "$(parse revise.md 1)" \
  'o.decision === "revise" && o.adjustments.length === 2 && o.follow_ups.some(f => f.kind === "scope")'
check "ESCALATE carries its reasons and concern" "$(parse escalate-business-rule.md 1)" \
  'o.decision === "escalate" && o.reasons.join() === "business-rule-semantics" && /overdue fines round/.test(o.concern)'

# --- round cap -------------------------------------------------------------------
check "REVISE in round 2 escalates as non-convergence" "$(parse revise.md 2)" \
  'o.decision === "escalate" && o.verdict === "REVISE" && o.reasons.includes("non-convergence") && o.concern !== ""'
check "APPROVE in round 2 still approves" "$(parse approve.md 2)" 'o.decision === "approve" && o.round === 2'

# --- fail closed: unreadable replies ---------------------------------------------
for f in no-block two-blocks bad-json unknown-verdict other-fence missing-check bad-follow-up; do
  check "$f escalates as malformed with an error and a concern" "$(parse "$f.md" 1)" \
    'o.decision === "escalate" && o.reasons.includes("malformed") && o.errors.length > 0 && o.concern !== ""'
done

# --- fail closed: inconsistent verdicts ------------------------------------------
check "APPROVE with a failed check escalates" "$(parse approve-failed-check.md 1)" \
  'o.decision === "escalate" && o.reasons.includes("inconsistent-verdict") && /evidence/.test(o.errors.join(" "))'
check "APPROVE without a rollback escalates" "$(parse approve-no-rollback.md 1)" \
  'o.decision === "escalate" && o.reasons.includes("inconsistent-verdict") && /rollback/.test(o.errors.join(" "))'
check "APPROVE without a prevention follow-up escalates" "$(parse approve-no-prevention.md 1)" \
  'o.decision === "escalate" && o.reasons.includes("inconsistent-verdict") && /prevention/.test(o.errors.join(" "))'
check "REVISE without adjustments escalates" "$(parse revise-no-adjustments.md 1)" \
  'o.decision === "escalate" && o.reasons.includes("inconsistent-verdict")'
check "ESCALATE without a concern still escalates, as unspecified" "$(parse escalate-no-concern.md 1)" \
  'o.decision === "escalate" && o.reasons.includes("unspecified") && o.concern !== ""'
check "ESCALATE with an unknown reason still escalates, as unspecified, keeping the concern" "$(parse escalate-unknown-reason.md 1)" \
  'o.decision === "escalate" && o.reasons.includes("unspecified") && o.concern === "feels risky"'
check "ESCALATE keeps its known reasons beside an unknown one" "$(parse escalate-mixed-reasons.md 1)" \
  'o.decision === "escalate" && o.reasons.join() === "business-rule-semantics"'

# --- usage -------------------------------------------------------------------------
for args in "parse" "parse --round 3" "parse --round x" "bogus"; do
  # shellcheck disable=SC2086
  out="$(node "$CLI" $args < "$FX/approve.md")"; code=$?
  expect_code "'$args' exits 2" "$code" 2
  check "'$args' prints an error object" "$out" 'typeof o.error === "string"'
done

# --- comment -------------------------------------------------------------------------
results() {  # <fixture:round>... → a JSON array of parse results
  local sep="" spec
  printf '['
  for spec in "$@"; do printf '%s' "$sep"; parse "${spec%%:*}" "${spec##*:}"; sep=","; done
  printf ']'
}
body="$(results revise.md:1 approve.md:2 | node "$CLI" comment)"; code=$?
expect_code "comment exits 0" "$code" 0
contains "comment heads with the final decision and round" "$body" "Incident plan review — APPROVED (round 2 of 2)"
contains "comment numbers the adjustments" "$body" "- **1.** Name the failing test after the incident symptom"
n="$(printf '%s\n' "$body" | grep -c '^[0-9][0-9]*\. ')"
expect_code "comment numbers adjustments as bold bullets, never an ordered list" "$n" 0
contains "comment names the rollback" "$body" "revert the PR; no data migration"
contains "comment lists every round's follow-ups, unfiled" "$body" "Proposed follow-ups — not filed"
contains "comment keeps the removed scope from round 1" "$body" "Extract FineCalculator into a shared service"
contains "comment shows the round history" "$body" "Round 1: REVISE"
n="$(printf '%s\n' "$body" | grep -c 'Add a monitor on overdue-notice job duration')"
expect_code "comment lists a repeated follow-up once" "$n" 1

body="$(results escalate-business-rule.md:1 | node "$CLI" comment)"
contains "an escalated comment heads with ESCALATED" "$body" "Incident plan review — ESCALATED (round 1 of 2)"
contains "an escalated comment shows the concern" "$body" "a person must decide the fine rule"
contains "an escalated comment says a person decides" "$body" "interactive plan gate"
body="$(results escalate-with-adjustments.md:1 | node "$CLI" comment)"
contains "an escalated comment shows the reviewer's adjustments" "$body" "- **1.** Drop the 25-cent fine cap; it goes to a follow-up"
contains "an escalated comment shows every adjustment" "$body" "- **2.** Keep the current fine rounding unchanged"
body="$(results revise.md:1 revise.md:2 | node "$CLI" comment)"
contains "a non-convergence escalation shows the adjustments still asked for" "$body" "- **1.** Drop the FineCalculator extraction; it goes to a follow-up"

# the heading names the gate decision, so a parser-forced escalation never reads as the reviewer's verdict
body="$(results approve-no-prevention.md:1 | node "$CLI" comment)"
contains "an inconsistent APPROVE heads as ESCALATED" "$body" "Incident plan review — ESCALATED (round 1 of 2)"
contains "an inconsistent APPROVE keeps the reviewer's verdict in the round history" "$body" "Round 1: APPROVE → escalate"
body="$(results revise.md:1 revise.md:2 | node "$CLI" comment)"
contains "a round-2 REVISE heads as ESCALATED" "$body" "Incident plan review — ESCALATED (round 2 of 2)"
case "$body" in *"review — APPROVE"*|*"review — REVISE"*) fail "a forced escalation heading names the raw verdict" ;; *) pass "a forced escalation heading never names the raw verdict" ;; esac

out="$(printf '[{"decision":"escalate","round":1,"verdict":null,"reasons":["malformed"],"concern":"x"}]' | node "$CLI" comment)"; code=$?
expect_code "comment accepts a round without follow_ups or adjustments" "$code" 0

out="$(printf '[]' | node "$CLI" comment)"; code=$?
expect_code "comment with no rounds exits 2" "$code" 2
out="$(printf 'nope' | node "$CLI" comment)"; code=$?
expect_code "comment with non-JSON input exits 2" "$code" 2

echo "$checks checks, $fails failed"
[ "$fails" -eq 0 ]
