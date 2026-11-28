#!/usr/bin/env bash
# Fixture tests for findings.js — PE output schema validation and cross-PE de-duplication.
# No npm packages — bash + node only. Ends "<n> checks, <m> failed"; exit 1 on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../findings.js"
CONVERGENCE="$HERE/../convergence.js"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run findings tests" >&2
  exit 1
fi
if [ ! -f "$CLI" ]; then
  echo "FAIL: findings.js not found at $CLI" >&2
  exit 1
fi

total=0
fails=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
check() {
  local name="$1" json="$2" expr="$3"
  if node -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$json" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — got: $json"
  fi
}
valraw() { node "$CLI" validate <<<"$1"; }
# val — as valraw, with a complete moves_coverage added to every output that has none (the moves cases use valraw)
COV='[{"move":"M1","status":"applied","checked":"1 contract → 2 consumers grepped","note":""},{"move":"M2","status":"n/a","checked":"","note":"no state"},{"move":"M3","status":"n/a","checked":"","note":"no branch"},{"move":"M4","status":"n/a","checked":"","note":"no guard"},{"move":"M5","status":"n/a","checked":"","note":"no failing call"},{"move":"M6","status":"n/a","checked":"","note":"no test"},{"move":"M7","status":"n/a","checked":"","note":"no claim"}]'
val() {
  node -e 'const i = JSON.parse(process.argv[1]); const cov = JSON.parse(process.argv[2]);
    for (const o of Object.values(i.outputs || {})) if (o && typeof o === "object" && !("moves_coverage" in o)) o.moves_coverage = cov;
    process.stdout.write(JSON.stringify(i));' "$1" "$COV" | node "$CLI" validate
}
dd() { node "$CLI" dedup <<<"$1"; }

GOOD='{"severity":"MEDIUM","in_scope":true,"category":"correctness","title":"Off by one","location":"src/a.ts:3","description":"d","recommendation":"Use < instead of <=.","verification_receipt":"r"}'

# --- validate ------------------------------------------------------------------
check "a clean output passes with nothing to re-dispatch" \
  "$(val '{"outputs":{"pe-go-r1-shard1":{"pe":"pe-go","expert":"pe-go","findings":['"$GOOD"'],"verification_receipts":[]}}}')" \
  'o.redispatch.length === 0 && o.outputs["pe-go-r1-shard1"].findings.length === 1'

# --- moves_coverage (references/review-moves.md) ---------------------------------
check "a complete moves_coverage passes; a finding's move is kept, an unknown one reads as none" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":['"${GOOD%\}}"',"move":"m4"},'"${GOOD%\}}"',"move":"M9","title":"Other"}]}}}')" \
  'o.redispatch.length === 0 && o.outputs.t1.findings[0].move === "M4" && o.outputs.t1.findings[1].move === "none" && o.coverage_gaps.length === 0'
check "a missing moves_coverage re-dispatches once with the moves note" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[]}}}')" \
  'o.redispatch.length === 1 && o.redispatch[0].kinds.join() === "moves" && /moves_coverage missing/.test(o.redispatch[0].note) && /M1\.\.M7/.test(o.redispatch[0].note)'
short="$(node -e 'const c = JSON.parse(process.argv[1]); process.stdout.write(JSON.stringify(c.filter((e) => e.move !== "M6")))' "$COV")"
check "a moves_coverage short of a move names it" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[],"moves_coverage":'"$short"'}}}')" \
  'o.redispatch.length === 1 && /M6 missing/.test(o.redispatch[0].note)'
for bad in '"checked":"","note":""' '"checked":"<what> → <n>","note":""' '"checked":"the whole diff","note":""' '"checked":"2 changed contracts → 9 consumers, 3 doc restatements; 1 fix → 4 sibling sites grepped","note":""'; do
  cov="$(node -e 'const c = JSON.parse(process.argv[1]); c[0] = Object.assign({move: "M1", status: "applied"}, JSON.parse("{" + process.argv[2] + "}")); process.stdout.write(JSON.stringify(c))' "$COV" "$bad")"
  check "an applied move without a counted checked re-dispatches ($bad)" \
    "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[],"moves_coverage":'"$cov"'}}}')" \
    'o.redispatch.length === 1 && /M1 applied without a counted checked/.test(o.redispatch[0].note)'
done
cov="$(node -e 'const c = JSON.parse(process.argv[1]); c[1].note = ""; c.push(c[2]); c[3].status = "skipped"; process.stdout.write(JSON.stringify(c))' "$COV")"
check "an n/a without a note, a duplicate move and an unknown status are each named" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[],"moves_coverage":'"$cov"'}}}')" \
  'o.redispatch.length === 1 && /M2 n\/a without a note/.test(o.redispatch[0].note) && /M3 listed 2 times/.test(o.redispatch[0].note) && /M4 status .skipped. is not applied \| n\/a/.test(o.redispatch[0].note)'
check "after its one re-dispatch, an incomplete moves_coverage keeps the findings and is recorded as a gap" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":['"$GOOD"']}},"redispatched":{"moves":["t1"]}}')" \
  'o.redispatch.length === 0 && o.outputs.t1.findings.length === 1 && o.coverage_gaps.length === 1 && /^t1: moves_coverage incomplete after one re-dispatch/.test(o.coverage_gaps[0])'
check "a moves gap waits while another kind is still pending, so nothing is half-applied" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"LOW","category":"docs","title":"x","location":"a:1","recommendation":""}]}},"redispatched":{"moves":["t1"]}}')" \
  'o.redispatch.length === 1 && o.redispatch[0].kinds.join() === "recommendation" && o.coverage_gaps.length === 0'

check "a vague recommendation re-dispatches that teammate once" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"LOW","category":"docs","title":"x","location":"a:1","recommendation":"Consider renaming it"}]}}}')" \
  'o.redispatch.length === 1 && o.redispatch[0].name === "t1" && o.redispatch[0].kinds.includes("recommendation") && /concrete fix/.test(o.redispatch[0].note)'
for rec in 'Maybe rename it.' 'perhaps cache it' 'Consider: a cache' 'Review whether it leaks'; do
  check "a vague recommendation (\"$rec\") re-dispatches" \
    "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"LOW","category":"docs","title":"x","location":"a:1","recommendation":"'"$rec"'"}]}}}')" \
    'o.redispatch.length === 1 && o.redispatch[0].kinds.includes("recommendation")'
done
check "a concrete recommendation that starts with a vague word's stem passes" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"LOW","category":"docs","title":"x","location":"a:1","recommendation":"Considerations.md gets the new key."}]}}}')" \
  'o.redispatch.length === 0'
check "a vague word mid-sentence is not a vague recommendation" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"LOW","category":"docs","title":"x","location":"a:1","recommendation":"Bound the retry loop; consider a cap of 3."}]}}}')" \
  'o.redispatch.length === 0'
check "after its one re-dispatch, a still-vague finding is demoted to a receipt, not looped" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"LOW","category":"docs","title":"x","location":"a:1","recommendation":""}]}},"redispatched":{"recommendation":["t1"]}}')" \
  'o.redispatch.length === 0 && o.outputs.t1.findings.length === 0 && o.outputs.t1.verification_receipts[0].claim === "below_bar" && o.demoted.length === 1'

check "an unknown category re-dispatches once" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"HIGH","category":"Spelling","title":"x","location":"a:1","recommendation":"Fix it."}]}}}')" \
  'o.redispatch[0].kinds.includes("category")'
check "after its re-dispatch an unknown category falls back to general and is recorded" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"HIGH","category":"","title":"x","location":"a:1","recommendation":"Fix it."}]}},"redispatched":{"category":["t1"]}}')" \
  'o.outputs.t1.findings[0].category === "general" && o.category_fallbacks[0] === "t1: '"'"'x'"'"' — category missing/invalid, recorded as general"'
check "category case and whitespace are normalized without a re-dispatch" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"high","category":" Auth ","title":"x","location":"a:1","recommendation":"Fix it."}]}}}')" \
  'o.redispatch.length === 0 && o.outputs.t1.findings[0].category === "auth" && o.outputs.t1.findings[0].severity === "HIGH"'

check "a receipt with an unknown claim re-dispatches once" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[],"verification_receipts":[{"claim":"maybe","title":"r","location":"src/"}]}}}')" \
  'o.redispatch[0].kinds.includes("claim")'
check "after its re-dispatch an unknown claim fails closed to absence" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[],"verification_receipts":[{"claim":"maybe","title":"r","location":"src/"}]}},"redispatched":{"claim":["t1"]}}')" \
  'o.redispatch.length === 0 && o.outputs.t1.verification_receipts[0].claim === "absence"'
check "an output with no findings list (an error body) re-dispatches, never reads as clean" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","error":"could not run the diff command"}}}')" \
  'o.redispatch.length === 1 && o.redispatch[0].kinds[0] === "findings" && /findings: \[\]/.test(o.redispatch[0].note)'
out="$(val '{"outputs":{"t1":{"pe":"pe-go","findings":null}},"redispatched":{"findings":["t1"]}}')"; code=$?
check "still no findings list after its re-dispatch → exit 2" "$out" 'o.error.includes("no findings list")'
if [ "$code" -eq 2 ]; then pass "  exit 2"; else fail "  exit $code, expected 2"; fi
check "missing verification_receipts defaults to []" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[]}}}')" 'Array.isArray(o.outputs.t1.verification_receipts)'

check "the expert id comes from the dispatched PE, whatever casing the PE wrote" \
  "$(val '{"outputs":{"t1":{"pe":"pe-csharp","expert":"PE-CSharp","findings":['"$GOOD"']}}}')" \
  'o.outputs.t1.expert === "pe-csharp"'

check "several violations on one teammate become one re-dispatch message" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"LOW","category":"nope","title":"x","location":"a:1","recommendation":"think about it"}],"verification_receipts":[{"claim":"?","title":"r","location":"s"}]}}}')" \
  'o.redispatch.length === 1 && o.redispatch[0].kinds.length === 3'

# The category enum matches the findings ledger's, so a validated category never fails convergence.js.
enum_ok="$(node -e '
  const src = require("fs").readFileSync(process.argv[1], "utf8");
  const m = src.match(/const CATEGORIES = new Set\(\[([\s\S]*?)\]\)/);
  const list = [...m[1].matchAll(/'"'"'([a-z-]+)'"'"'/g)].map(x => x[1]);
  console.log(JSON.stringify(list));' "$CONVERGENCE")"
if [ "$(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$enum_ok")" -lt 13 ]; then
  fail "could not read the category enum from convergence.js"
fi
for c in $(node -e 'JSON.parse(process.argv[1]).forEach(c => console.log(c))' "$enum_ok"); do
  out="$(val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"LOW","category":"'"$c"'","title":"x","location":"a:1","recommendation":"Fix it."}]}}}')"
  if ! node -e 'process.exit(JSON.parse(process.argv[1]).redispatch.length ? 1 : 0)' "$out"; then
    fail "category '$c' from convergence.js is rejected by findings.js"
  fi
done
pass "every convergence.js category is accepted"

EMOJI_CRIT='{"severity":"🔴 CRITICAL","in_scope":true,"category":"security","title":"SQL injection","location":"a.go:1","description":"d","recommendation":"Use parameterized queries.","verification_receipt":"r"}'
check "an emoji-labelled severity normalizes instead of re-dispatching" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":['"$EMOJI_CRIT"']}}}')" \
  'o.redispatch.length === 0 && o.outputs.t1.findings[0].severity === "CRITICAL"'
SEV1='{"severity":"Sev1","in_scope":true,"category":"security","title":"Bad sev","location":"a.go:1","description":"d","recommendation":"Fix it now.","verification_receipt":"r"}'
check "an unknown severity re-dispatches with a severity note" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":['"$SEV1"']}}}')" \
  'o.redispatch[0].kinds.join() === "severity" && o.redispatch[0].note.includes("severity") && !o.redispatch[0].note.includes("recommendation")'
check "an unknown severity after its re-dispatch stays gating as MEDIUM" \
  "$(val '{"outputs":{"t1":{"pe":"pe-go","findings":['"$SEV1"']}},"redispatched":{"severity":["t1"]}}')" \
  'o.outputs.t1.findings.length === 1 && o.outputs.t1.findings[0].severity === "MEDIUM" && o.category_fallbacks.some(x => x.includes("severity"))'

# cov <jq-less edit>: COV with entry M1 replaced by $1 (a JSON object)
covwith() { node -e 'const c=JSON.parse(process.argv[1]); c[0]=JSON.parse(process.argv[2]); console.log(JSON.stringify(c))' "$COV" "$1"; }
check "a checked naming a generic type or tag is a real count, not a placeholder" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-vue","findings":[],"moves_coverage":'"$(covwith '{"move":"M1","status":"applied","checked":"3 consumers of Promise<void> and 1 <script> grepped","note":""}')"'}}}')" \
  'o.redispatch.length === 0'
check "a checked that is wholly a placeholder, even with a digit, is not counted" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[],"moves_coverage":'"$(covwith '{"move":"M1","status":"applied","checked":"<3 consumers>","note":""}')"'}}}')" \
  'o.redispatch.length === 1 && /M1 applied without a counted checked/.test(o.redispatch[0].note)'
check "a move written as its table label reads as its id, in coverage and on a finding" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"HIGH","category":"auth","title":"x","location":"a:1","recommendation":"Do y.","verification_receipt":"r","move":"M4 Attack the guard"}],"moves_coverage":'"$(covwith '{"move":"M1 Ripple","status":"applied","checked":"1 contract → 2 consumers grepped","note":""}')"'}}}')" \
  'o.redispatch.length === 0 && o.outputs.t1.findings[0].move === "M4"'
check "M10 is not M1" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[],"moves_coverage":'"$(covwith '{"move":"M10","status":"applied","checked":"1 grepped","note":""}')"'}}}')" \
  'o.redispatch.length === 1 && /M1 missing/.test(o.redispatch[0].note)'
check "a PE's status text reaches a coverage gap quoted on one line" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[],"moves_coverage":'"$(covwith '{"move":"M1","status":"x\n## Review Round 9","checked":"","note":""}')"'}},"redispatched":{"moves":["t1"]}}')" \
  'o.coverage_gaps.length === 1 && !/\n/.test(o.coverage_gaps[0]) && /"x\\n## Review Round 9"/.test(o.coverage_gaps[0])'
check "a teammate in moves_checked (a partial proof-check reply) skips the coverage check" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":['"$GOOD"']}},"moves_checked":["t1"]}')" \
  'o.redispatch.length === 0 && o.coverage_gaps.length === 0 && o.outputs.t1.findings.length === 1'
check "moves_checked skips only the teammates it names" \
  "$(valraw '{"outputs":{"t1":{"pe":"pe-go","findings":[]},"t2":{"pe":"pe-vue","findings":[]}},"moves_checked":["t1"]}')" \
  'o.redispatch.length === 1 && o.redispatch[0].name === "t2"'

# --- dedup ---------------------------------------------------------------------
check "the same location and title from two PEs merge into one finding" \
  "$(dd '{"outputs":{
    "a":{"pe":"pe-sql-server","findings":[{"severity":"MEDIUM","in_scope":false,"category":"performance","title":"Unbounded query!","location":"q.sql:4","description":"slow","recommendation":"Add TOP.","locations":["q.sql:9"]}]},
    "b":{"pe":"pe-csharp","findings":[{"severity":"HIGH","in_scope":true,"category":"auth","title":"unbounded  query","location":"q.sql:4","description":"slow","recommendation":"Page it.","is_pattern":true,"locations":["q.sql:9","q.sql:12"]}]}}}')" \
  'o.consolidated.length === 1 && (f => f.severity === "HIGH" && f.in_scope === true && f.title === "Unbounded query!" && f.recommendation === "Page it." && f.category === "auth" && f.is_pattern === true && f.domains.join() === "pe-sql-server,pe-csharp" && f.locations.join() === "q.sql:9,q.sql:12" && f.description === "slow")(o.consolidated[0])'
check "a floor category from any contributor wins the merged category" \
  "$(dd '{"outputs":{
    "a":{"pe":"pe-go","findings":[{"severity":"LOW","category":"secrets","title":"t","location":"x:1","recommendation":"r1"}]},
    "b":{"pe":"pe-github-actions","findings":[{"severity":"HIGH","category":"correctness","title":"t","location":"x:1","recommendation":"r2"}]}}}')" \
  'o.consolidated[0].category === "secrets" && o.consolidated[0].recommendation === "r2"'
for c in data-integrity migration auth secrets; do
  check "the category floor lifts a LOW $c finding to MEDIUM once, keeping the PE's rating" \
    "$(dd '{"outputs":{"a":{"pe":"pe-go","findings":[{"severity":"LOW","category":"'"$c"'","title":"t","location":"x:1","recommendation":"r"}]}}}')" \
    'o.consolidated[0].severity === "MEDIUM" && o.consolidated[0].severity_reported === "LOW"'
done
check "the floor lifts INFO too, and a merged floor category floors the merged finding" \
  "$(dd '{"outputs":{
    "a":{"pe":"pe-go","findings":[{"severity":"INFO","category":"correctness","title":"t","location":"x:1","recommendation":"r1"}]},
    "b":{"pe":"pe-vue","findings":[{"severity":"INFO","category":"auth","title":"t","location":"x:1","recommendation":"r2"}]}}}')" \
  'o.consolidated[0].severity === "MEDIUM" && o.consolidated[0].severity_reported === "INFO" && o.consolidated[0].category === "auth"'
check "a floor category at MEDIUM or above is unchanged and carries no severity_reported" \
  "$(dd '{"outputs":{"a":{"pe":"pe-go","findings":[{"severity":"HIGH","category":"auth","title":"t","location":"x:1","recommendation":"r"},{"severity":"LOW","category":"docs","title":"u","location":"y:1","recommendation":"r"}]}}}')" \
  'o.consolidated[0].severity === "HIGH" && !("severity_reported" in o.consolidated[0]) && o.consolidated[1].severity === "LOW"'
check "distinct findings stay separate and each gets its PE as its domain" \
  "$(dd '{"outputs":{"a":{"pe":"pe-go","findings":['"$GOOD"']},"b":{"pe":"pe-vue","findings":[{"severity":"LOW","category":"docs","title":"other","location":"b:1","recommendation":"r"}]}}}')" \
  'o.consolidated.length === 2 && o.consolidated[0].domains.join() === "pe-go" && o.consolidated[1].domains.join() === "pe-vue"'

# --- lineage (references/review-moves.md § Finding Keys) --------------------------
# lin <finding-extra-json> [top-level-extra] — validate one pe-go finding carrying the extra keys
lin() { val '{"outputs":{"t1":{"pe":"pe-go","findings":[{"severity":"HIGH","category":"auth","title":"x","location":"a:1","recommendation":"Do y.","verification_receipt":"r"'"$1"'}]}}'"${2:-}"'}'; }
check "siblings as a list of path:line passes, and is kept" "$(lin ',"siblings":["b:2","c:3"]')" \
  'o.redispatch.length === 0 && o.outputs.t1.findings[0].siblings.join() === "b:2,c:3"'
check "siblings that is not a list of strings re-dispatches for lineage" "$(lin ',"siblings":"b:2"')" \
  'o.redispatch.length === 1 && o.redispatch[0].kinds.join() === "lineage" && /Finding Keys/.test(o.redispatch[0].note)'
check "round 1 (no prior_ids) never asks for introduced_by" "$(lin '')" 'o.redispatch.length === 0'
check "round 2+: a missing introduced_by re-dispatches" "$(lin '' ',"prior_ids":["HIGH-001"]')" \
  'o.redispatch.length === 1 && o.redispatch[0].kinds.join() === "lineage"'
for by in HIGH-001 still-present new missed pre-existing; do
  check "round 2+: introduced_by $by passes" "$(lin ',"introduced_by":"'"$by"'"' ',"prior_ids":["HIGH-001"]')" 'o.redispatch.length === 0'
done
check "round 2+: an id the prior round never had is not lineage" "$(lin ',"introduced_by":"HIGH-009"' ',"prior_ids":["HIGH-001"]')" \
  'o.redispatch.length === 1'
check "after its one re-dispatch, bad lineage is cleared, kept as a finding and recorded as a gap" \
  "$(lin ',"siblings":7,"introduced_by":"bogus"' ',"prior_ids":["HIGH-001"],"redispatched":{"lineage":["t1"]}')" \
  'o.redispatch.length === 0 && o.outputs.t1.findings.length === 1 && o.outputs.t1.findings[0].siblings.length === 0 && o.outputs.t1.findings[0].introduced_by === null && /^t1: lineage missing after one re-dispatch/.test(o.coverage_gaps[0])'
check "a teammate in moves_checked skips the lineage check" "$(lin '' ',"prior_ids":["HIGH-001"],"moves_checked":["t1"]')" \
  'o.redispatch.length === 0 && o.coverage_gaps.length === 0'
L='"category":"auth","title":"x","location":"a:1","recommendation":"r"'
check "dedup unions siblings and keeps the top-severity copy's lineage" \
  "$(dd '{"outputs":{"a":{"pe":"pe-go","findings":[{"severity":"MEDIUM",'"$L"',"siblings":["b:2"],"introduced_by":"new","move":"M1"}]},"b":{"pe":"pe-vue","findings":[{"severity":"HIGH",'"$L"',"siblings":["c:3","b:2"],"introduced_by":"missed","move":"M4"}]}}}')" \
  'o.consolidated.length === 1 && o.consolidated[0].siblings.join() === "b:2,c:3" && o.consolidated[0].introduced_by === "missed" && o.consolidated[0].move === "M4"'
check "dedup on a severity tie prefers a prior finding id" \
  "$(dd '{"outputs":{"a":{"pe":"pe-go","findings":[{"severity":"HIGH",'"$L"',"introduced_by":"new"}]},"b":{"pe":"pe-vue","findings":[{"severity":"HIGH",'"$L"',"introduced_by":"MEDIUM-004"}]}}}')" \
  'o.consolidated[0].introduced_by === "MEDIUM-004"'

# --- fail closed ---------------------------------------------------------------
node "$CLI" validate <<<'nope' >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "invalid JSON exits 2"; else fail "invalid JSON exit $code"; fi
node "$CLI" validate <<<'{"outputs":{"t1":{"findings":[]}}}' >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "an output without its dispatched pe exits 2"; else fail "missing pe exit $code"; fi

check "distinct non-ASCII titles at one location stay separate" \
  "$(dd '{"outputs":{"a":{"pe":"pe-go","findings":[{"severity":"HIGH","title":"空のリストで例外","location":"a.go:1","category":"correctness"},{"severity":"LOW","title":"コメントが古い","location":"a.go:1","category":"docs"}]}}}')" \
  'o.consolidated.length === 2'

echo "=================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] && [ "$fails" -eq 0 ]
