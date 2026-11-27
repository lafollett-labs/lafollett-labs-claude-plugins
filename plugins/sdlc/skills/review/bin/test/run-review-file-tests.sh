#!/usr/bin/env bash
# Fixture tests for review-file.js — the single owner of the review-file format.
# The goldens were written by hand from the report template and the review skill's
# write/append rules; a byte diff here means the review file a reader sees changed.
# No npm packages — bash + node only. Ends "<n> checks, <m> failed"; exit 1 on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../review-file.js"
FIX="$HERE/fixtures/review-file"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run review-file tests" >&2
  exit 1
fi
if [ ! -f "$CLI" ]; then
  echo "FAIL: review-file.js not found at $CLI" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
total=0
fails=0
SDLC_VERSION="$(node -p 'require(process.argv[1]).version' "$HERE/../../../../.claude-plugin/plugin.json")"
sed "s/@SDLC_VERSION@/$SDLC_VERSION/g" "$FIX/expected-initial.md" > "$TMP/expected-initial.md"
sed "s/@SDLC_VERSION@/$SDLC_VERSION/g" "$FIX/expected-gate2.md" > "$TMP/expected-gate2.md"

pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }

# check <name> <json> <js-boolean-expression over `o`>
check() {
  local name="$1" json="$2" expr="$3"
  if node -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$json" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — got: $json"
  fi
}

# --- render: Gate 1 initial file -------------------------------------------
out="$(node "$CLI" render --file "$TMP/initial.md" < "$FIX/gate1-initial.json")"
code=$?
if [ "$code" -eq 0 ] && cmp -s "$TMP/initial.md" "$TMP/expected-initial.md"; then
  pass "render creates the initial review file (golden)"
else
  fail "render initial file differs from golden (exit $code)"
  diff "$TMP/expected-initial.md" "$TMP/initial.md" | head -20
fi
check "render reports round 1 and the BLOCKED verdict" "$out" 'o.round === 1 && o.verdict === "🚫 BLOCKED"'

# --- render: Gate 2 round appended to a Gate 1-locked file -------------------
cp "$FIX/gate1-locked.md" "$TMP/gate2.md"
out="$(node "$CLI" render --file "$TMP/gate2.md" < "$FIX/gate2-round.json")"
code=$?
if [ "$code" -eq 0 ] && cmp -s "$TMP/gate2.md" "$TMP/expected-gate2.md"; then
  pass "render appends the Gate 2 round (golden)"
else
  fail "render Gate 2 append differs from golden (exit $code)"
  diff "$TMP/expected-gate2.md" "$TMP/gate2.md" | head -20
fi
check "render reports round 4 and APPROVED" "$out" 'o.round === 4 && o.verdict === "✅ APPROVED"'
check "an appended round records the running version without stamping old rounds" \
  "$(node "$CLI" parse --file "$TMP/gate2.md")" \
  "o.rounds.slice(0, -1).every(r => r.sdlc_version === null) && o.latest.sdlc_version === '$SDLC_VERSION'"

# The template's own table of contents never reaches a review file.
if grep -q "Contents" "$TMP/initial.md" "$TMP/gate2.md"; then
  fail "a rendered review file carries the template's Contents"
else
  pass "rendered review files carry no template Contents"
fi

# An invalidated approval: prior round APPROVED at another SHA.
sed 's/"head_sha": "5d6e7f8"/"head_sha": "9f9f9f9"/' "$FIX/gate2-round.json" > "$TMP/newsha.json"
cp "$FIX/gate1-locked.md" "$TMP/invalidated.md"
node "$CLI" render --file "$TMP/invalidated.md" < "$TMP/newsha.json" >/dev/null
if grep -qF "## Review Round 4  🚫 PRIOR ROUND INVALIDATED — re-reviewing post-approval changes" "$TMP/invalidated.md"; then
  pass "render marks a post-approval round on a new SHA as invalidating"
else
  fail "render did not mark the invalidated prior approval"
fi

# A full-SHA head against a short recorded SHA is the same commit: confirmation, not invalidation.
sed 's/"head_sha": "5d6e7f8"/"head_sha": "5d6e7f8a9b0c1d2e3f405162738495a6b7c8d9e0"/' "$FIX/gate2-round.json" > "$TMP/fullsha.json"
cp "$FIX/gate1-locked.md" "$TMP/fullsha.md"
node "$CLI" render --file "$TMP/fullsha.md" < "$TMP/fullsha.json" >/dev/null
if grep -qF "## Review Round 4  🔁 CONFIRMATION ROUND" "$TMP/fullsha.md"; then
  pass "render treats a full SHA matching the prior short SHA as a confirmation round"
else
  fail "render mislabelled a same-commit round (full vs short SHA)"
fi

# A missing parent directory is created, so a ledger-less round is never lost.
node "$CLI" render --file "$TMP/new/docs/code-reviews/42-code-review.md" < "$FIX/gate1-initial.json" >/dev/null 2>&1
if [ -f "$TMP/new/docs/code-reviews/42-code-review.md" ]; then pass "render creates a missing parent directory"; else fail "render did not create the parent directory"; fi

# CRLF files: append still replaces the single footer and keeps one line-ending style.
sed 's/$/\r/' "$FIX/gate1-locked.md" > "$TMP/crlf.md"
node "$CLI" render --file "$TMP/crlf.md" < "$FIX/gate2-round.json" >/dev/null
footers=$(grep -c "Generated with" "$TMP/crlf.md"); crs=$(grep -c $'\r$' "$TMP/crlf.md"); lines=$(wc -l < "$TMP/crlf.md")
if [ "$footers" -eq 1 ] && { [ "$crs" -eq 0 ] || [ "$crs" -eq "$lines" ]; }; then pass "render on a CRLF file keeps one footer and one line-ending style"; else fail "CRLF render: $footers footers, $crs of $lines CR lines"; fi

# Table cells escape pipes and newlines so free text never breaks a row.
node -e 'const r=require(process.argv[1]); r.ac_results=[{ac:"#1 a | b",verdict:"satisfied",evidence:"grep a|b\nsecond"}]; r.title="x | y"; console.log(JSON.stringify(r))' "$FIX/gate1-initial.json" \
  | node "$CLI" render --file "$TMP/pipes.md" >/dev/null
if grep -qF '| #1 a \| b | ✅ satisfied | grep a\|b second |' "$TMP/pipes.md" && grep -qF '| **Title** | x \| y |' "$TMP/pipes.md"; then
  pass "table cells escape | and newlines"
else
  fail "table cells not escaped"
fi

# The PR row links the pull request; the PR author reviewing their own branch is marked self-review.
node -e 'const r=require(process.argv[1]); r.reviewer="octocat"; console.log(JSON.stringify(r))' "$FIX/gate2-round.json" \
  | node "$CLI" render --file "$TMP/pr.md" >/dev/null
if grep -qF '| **PR** | [#7](https://github.com/octo-org/octo-repo/pull/7) |' "$TMP/pr.md" && grep -qF '| **Author** | @octocat |' "$TMP/pr.md"; then
  pass "render links the PR and names its author"
else
  fail "PR row or author missing"
fi
if grep -qF '| **Engineer Reviewer** | @octocat (self-review) |' "$TMP/pr.md"; then pass "the PR author reviewing is marked self-review"; else fail "self-review not marked"; fi
check "parse strips the self-review mark from the reviewer" "$(node "$CLI" parse --file "$TMP/pr.md")" 'o.latest.engineer_reviewer === "octocat"'
if grep -qF '| **PR** | — |' "$TMP/expected-initial.md"; then pass "a round with no PR renders an empty PR row"; else fail "empty PR row missing"; fi

# --- parse ---------------------------------------------------------------------
out="$(node "$CLI" parse --file "$FIX/expected-gate2.md")"
check "parse finds 4 rounds and next_round 5" "$out" 'o.rounds.length === 4 && o.next_round === 5'
check "parse reads the latest round's gate status, SHA, verdict" "$out" \
  'o.latest.n === 4 && o.latest.gate_status.startsWith("MERGEABLE") && o.latest.reviewed_sha === "5d6e7f8" && o.latest.verdict === "✅ APPROVED"'
check "parse reads the latest round's counts and advisory index" "$out" \
  'o.latest.counts.in.INFO === 1 && o.latest.counts.in.MEDIUM === 0 && o.latest.advisory.length === 1 && o.latest.advisory[0].id === "INFO-001"'
check "parse reads the initial block's findings and reviewer" "$out" \
  'o.rounds[0].n === 1 && o.rounds[0].in_scope_findings.map(f => f.id).join() === "HIGH-001,LOW-001" && o.rounds[0].in_scope_findings[0].location === "internal/auth/store.go:14" && o.rounds[0].engineer_reviewer === "octocat" && o.rounds[0].counts.out.MEDIUM === 1'
check "parse reads the latest reviewer" "$out" 'o.latest.engineer_reviewer === "hubot"'

out="$(node "$CLI" parse --file "$FIX/expected-initial.md")"
check "parse of a single-round file uses the top Verdict line" "$out" \
  'o.rounds.length === 1 && o.latest.verdict === "🚫 BLOCKED" && o.latest.gate_status.startsWith("OPEN") && o.next_round === 2'

out="$(node "$CLI" parse --file "$FIX/legacy-gate1-locked.md")"
check "parse tolerates a hand-written Gate 1 file" "$out" \
  'o.latest.n === 5 && o.latest.gate_status.startsWith("LOCKED") && o.latest.verdict === "✅ APPROVED" && o.rounds[0].counts.in.MEDIUM === 4'
out="$(node "$CLI" parse --file "$FIX/legacy-gate2-mergeable.md")"
check "parse tolerates a hand-written Gate 2 file" "$out" \
  'o.latest.n === 5 && o.latest.gate_status.startsWith("MERGEABLE") && o.latest.reviewed_sha === "f5ab030" && o.latest.engineer_reviewer === "monalisa"'

# --- verdict -------------------------------------------------------------------
v() { node "$CLI" verdict <<<"$1"; }
check "verdict: no findings → APPROVED" "$(v '[]')" 'o.verdict === "✅ APPROVED"'
check "verdict: in-scope LOW/INFO only → APPROVED with advisory" \
  "$(v '[{"severity":"LOW","in_scope":true,"title":"a","location":"x:1"},{"severity":"INFO","in_scope":true,"title":"b","location":"x:2"}]')" \
  'o.verdict === "✅ APPROVED" && o.advisory.length === 2 && o.gating.length === 0'
check "verdict: in-scope MEDIUM → CHANGES REQUESTED" \
  "$(v '[{"severity":"MEDIUM","in_scope":true,"title":"a","location":"x:1"}]')" \
  'o.verdict === "⚠️ CHANGES REQUESTED" && o.gating.length === 1 && o.counts.in.MEDIUM === 1'
check "verdict: in-scope HIGH → BLOCKED" \
  "$(v '[{"severity":"HIGH","in_scope":true,"title":"a","location":"x:1"}]')" 'o.verdict === "🚫 BLOCKED"'
check "verdict: in-scope CRITICAL → BLOCKED" \
  "$(v '{"findings":[{"severity":"CRITICAL","in_scope":true,"title":"a","location":"x:1"}]}')" 'o.verdict === "🚫 BLOCKED"'
check "verdict: out-of-scope HIGH never gates" \
  "$(v '[{"severity":"HIGH","in_scope":false,"title":"a","location":"x:1"}]')" \
  'o.verdict === "✅ APPROVED" && o.counts.out.HIGH === 1'

# Fenced snippets in a finding are body text: a quoted round heading or Gate Status row never fakes a round.
cp "$FIX/expected-initial.md" "$TMP/fenced.md"
node -e '
const r = require(process.argv[1]);
const fence = "```";
r.head_sha = "abc1234";
r.findings = [
  { severity: "MEDIUM", in_scope: true, category: "docs", title: "Quotes a round", location: "a.md:1", domains: ["pe-governance"],
    description: ["Quoted:", fence + "markdown", "## Review Round 9", "| **Gate Status** | LOCKED — ready for Gate 2 (PR peer review) |", "### In Scope Findings", fence].join("\n"),
    recommendation: "Fix it." },
  { severity: "LOW", in_scope: true, category: "docs", title: "After the fence", location: "b.md:2", domains: ["pe-governance"], description: "d", recommendation: "Fix it." },
];
console.log(JSON.stringify(r));' "$FIX/gate2-round.json" | node "$CLI" render --file "$TMP/fenced.md" >/dev/null
check "a fenced round heading and LOCKED row fake no round" "$(node "$CLI" parse --file "$TMP/fenced.md")" \
  'o.rounds.length === 2 && o.next_round === 3 && !o.rounds.some(r => String(r.gate_status).startsWith("LOCKED")) && o.latest.in_scope_findings.length === 2'

# Free text that holds a fence never hides a later round: fenced recommendation, rebuttal, receipt, and an
# unclosed fence in a description, each followed by another appended round.
for kind in recommendation rebuttal receipt unclosed; do
  cp "$FIX/expected-initial.md" "$TMP/fence-$kind.md"
  node -e '
const r = require(process.argv[1]); const kind = process.argv[2]; const fence = "```";
const block = fence + "js\nconst x = safe(y);\n" + fence;
r.head_sha = "abc1234";
const f = { severity: "LOW", in_scope: true, category: "docs", title: "T", location: "a.md:1", domains: ["pe-go"], description: "d", recommendation: "Fix." };
if (kind === "recommendation") f.recommendation = block;
if (kind === "unclosed") f.description = "Quoted:\n" + fence + "js\nconst x = 1;";
r.findings = [f];
r.rebuttals = kind === "rebuttal" ? [{ title: "T", evidence: block, outcome: "MAINTAIN" }] : [];
r.receipts = kind === "receipt" ? [{ claim: "positive", title: "R", location: "a.md", attestation: block }] : [];
console.log(JSON.stringify(r));' "$FIX/gate2-round.json" "$kind" | node "$CLI" render --file "$TMP/fence-$kind.md" >/dev/null
  sed 's/"head_sha": "5d6e7f8"/"head_sha": "def5678"/' "$FIX/gate2-round.json" | node "$CLI" render --file "$TMP/fence-$kind.md" >/dev/null
  check "a $kind holding a fence leaves the next round visible" "$(node "$CLI" parse --file "$TMP/fence-$kind.md")" \
    'o.rounds.length === 3 && o.latest.n === 3 && o.latest.reviewed_sha === "def5678" && o.next_round === 4'
  heads=$(grep -c '^## Review Round 3' "$TMP/fence-$kind.md")
  if [ "$heads" -eq 1 ]; then pass "a $kind holding a fence never duplicates a round heading"; else fail "$kind: $heads round-3 headings"; fi
done

# An unclosed fence left by one round never wedges a later fenced round: render closes what free text leaves open.
cp "$FIX/expected-initial.md" "$TMP/wedge.md"
mk() { node -e '
const r = require(process.argv[1]); const fence = "```";
r.head_sha = process.argv[2];
const f = { severity: "LOW", in_scope: true, category: "docs", title: "T", location: "a.md:1", domains: ["pe-go"], description: "d", recommendation: "Fix." };
if (process.argv[3] === "unclosed") f.description = "Quoted:\n" + fence + "js\nconst x = 1;";
else f.recommendation = fence + "js\nfix();\n" + fence;
r.findings = [f]; r.rebuttals = []; r.receipts = [];
console.log(JSON.stringify(r));' "$FIX/gate2-round.json" "$1" "$2"; }
mk abc1234 unclosed | node "$CLI" render --file "$TMP/wedge.md" >/dev/null
mk def5678 fenced | node "$CLI" render --file "$TMP/wedge.md" >/dev/null; code=$?
if [ "$code" -eq 0 ]; then pass "a fenced round after an unclosed fence renders"; else fail "fenced round after unclosed fence exit $code"; fi
check "a fenced round after an unclosed fence is the parsed latest" "$(node "$CLI" parse --file "$TMP/wedge.md")" \
  'o.latest.n === 3 && o.latest.reviewed_sha === "def5678"'

# --- gate2 ---------------------------------------------------------------------
g() { node "$CLI" gate2 --file "$1" --head "$2" <<<"$3"; }
CI_PASSED='"ci":{"state":"passed","reason":"checks on 5d6e7f8 passed"}'
check "gate2: sole peer approves on HEAD → MERGEABLE" \
  "$(g "$FIX/gate1-locked.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED",'"$CI_PASSED"'}')" \
  'o.gate_status === "MERGEABLE — all Gate 2 reviewers approved on current HEAD" && o.ci_hold === false'
check "gate2: a second peer requests changes → OPEN" \
  "$(g "$FIX/expected-gate2.md" 5d6e7f8 '{"reviewer":"monalisa","verdict":"⚠️ CHANGES REQUESTED",'"$CI_PASSED"'}')" \
  'o.gate_status === "OPEN — Gate 2 reviewer(s) outstanding or not on current HEAD"'
check "gate2: an earlier peer approval on an older SHA → OPEN" \
  "$(g "$FIX/expected-gate2.md" 0badf00 '{"reviewer":"monalisa","verdict":"✅ APPROVED",'"$CI_PASSED"'}')" \
  'o.gate_status.startsWith("OPEN")'
check "gate2: the same peer re-approves on the new HEAD → MERGEABLE" \
  "$(g "$FIX/expected-gate2.md" 0badf00 '{"reviewer":"hubot","verdict":"✅ APPROVED",'"$CI_PASSED"'}')" \
  'o.gate_status.startsWith("MERGEABLE")'

check "gate2: a full-SHA head matches another reviewer's short recorded SHA" \
  "$(g "$FIX/expected-gate2.md" 5d6e7f8a9b0c1d2e3f405162738495a6b7c8d9e0 '{"reviewer":"octo-peer","verdict":"✅ APPROVED",'"$CI_PASSED"'}')" \
  'o.gate_status.startsWith("MERGEABLE")'

# --- gate2: CI ----------------------------------------------------------------------
check "gate2: no check ran HEAD's code → today's MERGEABLE, no hold" \
  "$(g "$FIX/gate1-locked.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED","ci":{"state":"none","reason":"no check ran HEAD'"'"'s code"}}')" \
  'o.gate_status.startsWith("MERGEABLE") && o.ci_hold === false'
for s in pending incomplete; do
  check "gate2: CI $s holds an approved round OPEN" \
    "$(g "$FIX/gate1-locked.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED","ci":{"state":"'$s'","reason":"checks on 5d6e7f8 are running"}}')" \
    'o.gate_status === "OPEN — Gate 2 waiting on CI: checks on 5d6e7f8 are running" && o.ci_hold === true'
done
check "gate2: unreadable CI is never MERGEABLE" \
  "$(g "$FIX/gate1-locked.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED","ci":{"state":"unreadable","reason":"gh api timed out"}}')" \
  'o.gate_status === "OPEN — Gate 2 CI status unreadable: gh api timed out" && o.ci_hold === true'
check "gate2: failed CI is never MERGEABLE, even with an approved verdict" \
  "$(g "$FIX/gate1-locked.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED","ci":{"state":"failed","reason":"checks on 5d6e7f8 failed: build"}}')" \
  'o.gate_status === "OPEN — Gate 2 CI failed: checks on 5d6e7f8 failed: build" && o.ci_hold === true'
check "gate2: a CI reason cannot break the status table cell" \
  "$(g "$FIX/gate1-locked.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED","ci":{"state":"unreadable","reason":"a|b\nc"}}')" \
  'o.gate_status === "OPEN — Gate 2 CI status unreadable: a\\|b c"'
out="$(g "$FIX/gate1-locked.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED"}' 2>/dev/null)"; code=$?
if [ "$code" -eq 2 ]; then pass "gate2: a missing ci input fails closed (exit 2)"; else fail "gate2 missing ci (exit $code): $out"; fi
out="$(g "$FIX/gate1-locked.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED","ci":{"state":"green"}}' 2>/dev/null)"; code=$?
if [ "$code" -eq 2 ]; then pass "gate2: an unknown ci state fails closed (exit 2)"; else fail "gate2 unknown ci state (exit $code): $out"; fi
# A held round is still a Gate 2 round when the next reviewer runs: its BLOCKED verdict keeps the gate OPEN.
cp "$FIX/gate1-locked.md" "$TMP/held.md"
node -e 'const r=require(process.argv[1]); r.reviewer="monalisa"; r.head_sha="5d6e7f8"; r.gate_status="OPEN — Gate 2 waiting on CI: checks on 5d6e7f8 are running"; r.findings=[{severity:"HIGH",in_scope:true,category:"correctness",title:"Peer issue",location:"a.go:1",domains:["pe-go"],description:"d",recommendation:"Fix it."}]; console.log(JSON.stringify(r))' "$FIX/gate2-round.json" \
  | node "$CLI" render --file "$TMP/held.md" >/dev/null
check "gate2: a later round still counts a held round as a Gate 2 round" \
  "$(g "$TMP/held.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED",'"$CI_PASSED"'}')" \
  'o.gate_status === "OPEN — Gate 2 reviewer(s) outstanding or not on current HEAD"'
# A peer's recorded OPEN Gate 2 round (changes requested) keeps the gate OPEN when another peer approves.
cp "$FIX/expected-gate2.md" "$TMP/open-peer.md"
node -e 'const r=require(process.argv[1]); r.reviewer="monalisa"; r.gate_status="OPEN — Gate 2 reviewer(s) outstanding or not on current HEAD"; r.findings=[{severity:"MEDIUM",in_scope:true,category:"correctness",title:"Peer issue",location:"a.go:1",domains:["pe-go"],description:"d",recommendation:"Fix it."}]; console.log(JSON.stringify(r))' "$FIX/gate2-round.json" \
  | node "$CLI" render --file "$TMP/open-peer.md" >/dev/null
check "gate2: a peer's OPEN round blocks MERGEABLE" \
  "$(g "$TMP/open-peer.md" 5d6e7f8 '{"reviewer":"hubot","verdict":"✅ APPROVED",'"$CI_PASSED"'}')" \
  'o.gate_status.startsWith("OPEN")'

# --- consumer contract: the fields deliver and pull-request read -----------------
# Both skills take verdict, round, and SHA from `latest`; pull-request's Gate 1 lock is "any round
# whose gate_status starts LOCKED", which must hold after a Gate 2 round supersedes the lock.
VERDICTS='["✅ APPROVED", "⚠️ CHANGES REQUESTED", "🚫 BLOCKED"]'
for f in expected-initial gate1-locked expected-gate2 legacy-gate1-locked legacy-gate2-mergeable; do
  check "consumer fields are present and typed in $f" "$(node "$CLI" parse --file "$FIX/$f.md")" \
    "$VERDICTS.includes(o.latest.verdict) && Number.isInteger(o.latest.n) && /^[0-9a-f]{7,40}\$/.test(o.latest.reviewed_sha) && typeof o.latest.gate_status === 'string' && ['CRITICAL','HIGH','MEDIUM','LOW','INFO'].every(k => Number.isInteger(o.latest.counts.in[k])) && Array.isArray(o.latest.in_scope_findings) && Array.isArray(o.latest.advisory)"
done
check "in-scope findings carry their recommendation" "$(node "$CLI" parse --file "$FIX/expected-initial.md")" \
  'o.latest.in_scope_findings.some(f => f.id === "HIGH-001" && f.recommendation === "Pass the username to QueryRowContext as a bind parameter.")'
check "legacy bullet-style recommendations parse" "$(node "$CLI" parse --file "$FIX/legacy-gate2-mergeable.md")" \
  'o.rounds.flatMap(r => r.in_scope_findings).every(f => typeof f.recommendation === "string" && f.recommendation.length > 0)'
# A recommendation keeps its fenced code: fence-only and text-plus-fence both round-trip through render → parse.
for kind in only mixed; do
  rm -f "$TMP/rec-$kind.md"
  # shellcheck disable=SC2016  # $1 is a SQL bind placeholder inside the node -e body
  node -e '
const r = require(process.argv[1]); const kind = process.argv[2]; const fence = "```";
const code = [fence + "go", "row := db.QueryRowContext(ctx, \"SELECT id FROM users WHERE name = $1\", name)", "  // bound, never concatenated", "## not a heading", fence].join("\n");
const f = r.findings.find((x) => x.severity === "HIGH");
f.recommendation = kind === "only" ? code : "Bind the username:\n" + code;
console.log(JSON.stringify(r));' "$FIX/gate1-initial.json" "$kind" | node "$CLI" render --file "$TMP/rec-$kind.md" >/dev/null
  check "a $kind-fence recommendation keeps its code" "$(node "$CLI" parse --file "$TMP/rec-$kind.md")" \
    'o.latest.in_scope_findings.length === 2 && o.latest.in_scope_findings.some((f) => f.id === "HIGH-001" && f.recommendation !== null && f.recommendation.includes("QueryRowContext(ctx") && f.recommendation.includes("\n  // bound, never concatenated\n") && f.recommendation.includes("## not a heading") && f.recommendation.trim().endsWith("```") && f.location === "internal/auth/store.go:14")'
done
check "any-round Gate 1 lock survives a later Gate 2 round" "$(node "$CLI" parse --file "$FIX/expected-gate2.md")" \
  '!o.latest.gate_status.startsWith("LOCKED") && o.rounds.some(r => r.gate_status.startsWith("LOCKED"))'
check "a lockless single-round file has no Gate 1 lock" "$(node "$CLI" parse --file "$FIX/expected-initial.md")" \
  '!o.rounds.some(r => r.gate_status.startsWith("LOCKED")) && o.latest.n === 1'

# --- parse --root/--name: the repo store ------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/docs/code-reviews"
cp "$TMP/expected-gate2.md" "$REPO/docs/code-reviews/42-code-review.md"
check "parse --root/--name reads docs/code-reviews/<key_slug>-code-review.md" "$(node "$CLI" parse --root "$REPO" --name 42)" \
  'o.rounds.length === 4 && o.latest.gate_status.startsWith("MERGEABLE") && o.markdown_path.endsWith("/docs/code-reviews/42-code-review.md") && o.ledger_path.endsWith("/docs/code-reviews/42-findings-ledger.json")'
check "parse --root/--name with no review yet starts at round 1" "$(node "$CLI" parse --root "$REPO" --name LT-02)" \
  'o.rounds.length === 0 && o.latest === null && o.next_round === 1 && o.version_advisories.findings === null && o.version_advisories.gate2 === null && o.markdown_path.endsWith("/LT-02-code-review.md")'
for bad in '../42' '..' 'a/b'; do
  node "$CLI" parse --root "$REPO" --name "$bad" >/dev/null 2>&1; code=$?
  if [ "$code" -eq 2 ]; then pass "parse --name rejects \"$bad\" (exit 2)"; else fail "parse --name accepted \"$bad\" (exit $code)"; fi
done
node "$CLI" parse --root "$REPO" >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "parse --root without --name exits 2"; else fail "parse --root without --name (exit $code)"; fi

# --- version advisories ------------------------------------------------------------
# Each round is rendered in turn, then its SDLC Version row is rewritten (or removed, for an unknown version).
if node - "$CLI" "$FIX/gate1-initial.json" "$TMP/version-advisories.md" "$SDLC_VERSION" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const [cli, fixture, file, current] = process.argv.slice(2);
const open = JSON.parse(fs.readFileSync(fixture, 'utf8'));
const [major, minor] = current.split('.').map(Number);
const older = `${major - 1}.999.0`;
const newer = `${major}.${minor + 1}.0`;
const findings = version => ({ round: open, version });
const locked = version => ({ round: { ...open, findings: [], gate_status: 'LOCKED' }, version });
const peer = { round: { ...open, findings: [], gate_status: 'MERGEABLE' }, version: newer };
function read(...rounds) {
  fs.rmSync(file, { force: true });
  for (const { round } of rounds) execFileSync(process.execPath, [cli, 'render', '--file', file], { input: JSON.stringify(round) });
  let i = 0;
  const text = fs.readFileSync(file, 'utf8').replace(/^\| \*\*SDLC Version\*\* \| .* \|\n/gm, () => {
    const v = rounds[i++].version;
    return v === null ? '' : `| **SDLC Version** | ${v} |\n`;
  });
  assert.equal(i, rounds.length);
  fs.writeFileSync(file, text);
  return JSON.parse(execFileSync(process.execPath, [cli, 'parse', '--file', file])).version_advisories;
}
assert.deepEqual(read(findings(current)), { findings: null, gate2: null });
assert.match(read(findings(older)).findings, /Round 1.*SDLC/);
assert.match(read(findings(newer)).findings, /Round 1.*SDLC/);
assert.match(read(findings(null)).findings, /version is unknown/);
assert.deepEqual(read(locked(older), peer), { findings: null, gate2: null });
assert.equal(read(locked(current)).gate2, null);
assert.match(read(locked(newer), peer).gate2, /Gate 1 round 1.*newer/);
assert.match(read(locked(null), peer).gate2, /version is unknown/);
JS
then
  pass "version advisories distinguish findings and the Gate 1 lock"
else
  fail "version advisories distinguish findings and the Gate 1 lock"
fi

# --- fail closed ---------------------------------------------------------------
out="$(node "$CLI" render --file "$TMP/bad.md" <<<'not json' 2>/dev/null)"; code=$?
if [ "$code" -eq 2 ] && [ ! -f "$TMP/bad.md" ]; then pass "render rejects invalid JSON with exit 2 and writes nothing"; else fail "render invalid JSON (exit $code)"; fi
check "render error is reported as JSON" "$out" 'typeof o.error === "string"'
out="$(sed '/"head_sha"/d' "$FIX/gate1-initial.json" | node "$CLI" render --file "$TMP/bad.md" 2>/dev/null)"; code=$?
if [ "$code" -eq 2 ] && [ ! -f "$TMP/bad.md" ]; then pass "render rejects a round without head_sha"; else fail "render missing head_sha (exit $code)"; fi
node "$CLI" parse --file "$TMP/missing.md" >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "parse of a missing file exits 2"; else fail "parse missing file (exit $code)"; fi
node "$CLI" bogus >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "unknown command exits 2"; else fail "unknown command (exit $code)"; fi

echo "=================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] && [ "$fails" -eq 0 ]
