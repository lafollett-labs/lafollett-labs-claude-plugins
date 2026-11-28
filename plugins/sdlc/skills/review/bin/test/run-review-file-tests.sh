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

# Hermetic git for the same-code repos: no user/system config, fixed identity.
export HOME="$TMP/home"
export USERPROFILE="$HOME"   # os.homedir() reads USERPROFILE, not HOME, on Windows
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# Offline gh: gate2 reads the PR's reviews through the shared stub.
export SDLC_GH="$HERE/../../../../bin/test/stub-gh.sh"
export STUB_GH_DIR="$TMP/gh"
mkdir -p "$STUB_GH_DIR"
: > "$STUB_GH_DIR/routes"

# A repo with three commits: A, then B touching only docs/code-reviews/ (same code as A), then C changing code.
G="$TMP/same-code"
mkdir -p "$G/docs/code-reviews"
git -C "$G" init -q
echo 'package auth' > "$G/store.go"; git -C "$G" add -A; git -C "$G" commit -qm a
A="$(git -C "$G" rev-parse HEAD)"
echo '# review' > "$G/docs/code-reviews/42-code-review.md"; git -C "$G" add -A; git -C "$G" commit -qm b
B="$(git -C "$G" rev-parse HEAD)"
echo '// changed' >> "$G/store.go"; git -C "$G" commit -qam c
C="$(git -C "$G" rev-parse HEAD)"
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

# --- render: moves coverage gaps ----------------------------------------------
node -e 'const r=require(process.argv[1]); r.coverage_gaps=["pe-go-r1: moves_coverage incomplete after one re-dispatch — M6 missing"]; console.log(JSON.stringify(r))' \
  "$FIX/gate1-initial.json" | node "$CLI" render --file "$TMP/gaps.md" >/dev/null
if grep -qx -- '- pe-go-r1: moves_coverage incomplete after one re-dispatch — M6 missing' "$TMP/gaps.md" \
   && grep -q 'Review Moves Coverage Gaps' "$TMP/gaps.md"; then
  pass "a moves coverage gap is rendered under its own heading"
else
  fail "a moves coverage gap is not rendered"
fi
node -e 'const r=require(process.argv[1]); r.findings[0].move="M4"; console.log(JSON.stringify(r))' \
  "$FIX/gate1-initial.json" | node "$CLI" render --file "$TMP/move.md" >/dev/null
if grep -q '· \*\*Move:\*\* M4' "$TMP/move.md" && ! grep -q '\*\*Move:\*\*' "$TMP/initial.md"; then
  pass "a finding's move is rendered beside its category, and none renders nothing"
else
  fail "a finding's move is not rendered"
fi
if grep -q 'Review Moves Coverage Gaps' "$TMP/initial.md"; then fail "a round with no gaps renders the gaps heading"
else pass "a round with no gaps renders no gaps heading"; fi

# --- render: lineage (siblings, introduced_by, Fix Cascade, Ripple Receipts) ------------
cp "$FIX/gate1-locked.md" "$TMP/lineage.md"
node -e 'const r=require(process.argv[1]); r.findings=[
  {severity:"HIGH",in_scope:true,category:"auth",title:"Caused",location:"a.go:1",description:"d",recommendation:"Fix.",siblings:["b.go:2","c.md:3"],introduced_by:"MEDIUM-004"},
  {severity:"MEDIUM",in_scope:true,category:"docs",title:"Fresh",location:"d.go:4",description:"d",recommendation:"Fix.",introduced_by:"new"},
  {severity:"LOW",in_scope:false,category:"docs",title:"Old",location:"e.go:5",description:"d",recommendation:"Fix.",introduced_by:"MEDIUM-001"}];
  r.ripple_receipts={spot_checked:2,dropped:1}; console.log(JSON.stringify(r))' "$FIX/gate2-round.json" \
  | node "$CLI" render --file "$TMP/lineage.md" >/dev/null
# shellcheck disable=SC2016 # backticks are the rendered markdown under test
for want in '**Siblings:** `b.go:2`, `c.md:3`' '**Introduced by:** MEDIUM-004' '| **Fix Cascade** | 1 / 2 |' \
            '| **Ripple Receipts** | 2 spot-checked, 1 dropped — no hex SHA of the reviewed commit |' '`a.go:1` + 2 siblings'; do
  if grep -qF -- "$want" "$TMP/lineage.md"; then pass "lineage renders: $want"; else fail "lineage does not render: $want"; fi
done
check "a round with lineage still parses" "$(node "$CLI" parse --file "$TMP/lineage.md")" \
  'o.latest.in_scope_findings.length === 2 && o.latest.in_scope_findings[0].recommendation === "Fix."'
node -e 'const r=require(process.argv[1]); r.ripple_receipts={spot_checked:0,dropped:0}; console.log(JSON.stringify(r))' "$FIX/gate2-round.json" > "$TMP/r0.json"
cp "$FIX/gate1-locked.md" "$TMP/ripple0.md"; node "$CLI" render --file "$TMP/ripple0.md" < "$TMP/r0.json" >/dev/null
if grep -qF "| **Ripple Receipts** | none — M1 ran exhaustive over the fix diff's rules |" "$TMP/ripple0.md"; then
  pass "no ripple receipts renders the exhaustive note"; else fail "no ripple receipts does not render the exhaustive note"; fi
if grep -q 'Fix Cascade\|Ripple Receipts' "$TMP/gate2.md"; then fail "a round without ripple_receipts renders lineage rows"
else pass "a round without ripple_receipts renders no lineage rows"; fi

# The template's own table of contents never reaches a review file.
if grep -q "Contents" "$TMP/initial.md" "$TMP/gate2.md"; then
  fail "a rendered review file carries the template's Contents"
else
  pass "rendered review files carry no template Contents"
fi

# --- round heading notes: only a Gate 1 round after a clean, still-open Gate 1 round -------
# clean <head> [gate_status] — a clean Gate 1 round at <head>
clean() { node -e 'const r=require(process.argv[1]); r.findings=[]; r.head_sha=process.argv[2]; r.gate_status=process.argv[3]; console.log(JSON.stringify(r))' \
  "$FIX/gate1-initial.json" "$1" "${2:-OPEN — need 1 more consecutive clean round(s)}"; }
heading() { grep -m1 '^## Review Round 2' "$1"; }
clean "$A" | node "$CLI" render --file "$TMP/note-same.md" >/dev/null
clean "$B" | node "$CLI" render --file "$TMP/note-same.md" --root "$G" >/dev/null
if heading "$TMP/note-same.md" | grep -qF '🔁 CONFIRMATION ROUND — same code'; then
  pass "a round whose code matches the clean prior round (review-doc commit between) is a confirmation"
else
  fail "same code after a review-doc commit not marked confirmation: $(heading "$TMP/note-same.md")"
fi
clean "$A" | node "$CLI" render --file "$TMP/note-changed.md" >/dev/null
clean "$C" | node "$CLI" render --file "$TMP/note-changed.md" --root "$G" >/dev/null
if heading "$TMP/note-changed.md" | grep -qF '🚫 PRIOR ROUND INVALIDATED'; then pass "a round after a code change invalidates the prior approval"; else fail "code change not marked invalidated"; fi
clean "${A:0:7}" | node "$CLI" render --file "$TMP/note-sha.md" >/dev/null
clean "$A" | node "$CLI" render --file "$TMP/note-sha.md" >/dev/null
if heading "$TMP/note-sha.md" | grep -qF 'CONFIRMATION ROUND'; then pass "without --root, a full SHA matching the prior short SHA is a confirmation"; else fail "full vs short SHA mislabelled"; fi
clean "$A" | node "$CLI" render --file "$TMP/note-noroot.md" >/dev/null
clean "$B" | node "$CLI" render --file "$TMP/note-noroot.md" >/dev/null
if heading "$TMP/note-noroot.md" | grep -qF 'INVALIDATED'; then pass "without --root, another SHA is a change"; else fail "another SHA without --root not marked"; fi
node "$CLI" render --file "$TMP/note-gate2.md" < "$FIX/gate2-round.json" >/dev/null
node "$CLI" render --file "$TMP/note-gate2.md" < "$FIX/gate2-round.json" >/dev/null
if [ "$(heading "$TMP/note-gate2.md")" = "## Review Round 2" ]; then pass "a Gate 2 round carries no Gate 1 note"; else fail "Gate 2 round heading: $(heading "$TMP/note-gate2.md")"; fi
cp "$FIX/gate1-locked.md" "$TMP/note-locked.md"
clean 5d6e7f8 "OPEN — need 2 more consecutive clean round(s)" | node "$CLI" render --file "$TMP/note-locked.md" >/dev/null
if grep -qx '## Review Round 4' "$TMP/note-locked.md"; then pass "a round after a locked round carries no note"; else fail "round after a lock carries a note"; fi

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

# Round 1's verdict is its own row: the top line follows the latest round and never stands in for round 1.
node "$CLI" render --file "$TMP/r1.md" < "$FIX/gate1-initial.json" >/dev/null
clean 1b2b3c4 | node "$CLI" render --file "$TMP/r1.md" >/dev/null
clean 1b2b3c4 | node "$CLI" render --file "$TMP/r1.md" >/dev/null
check "round 1's BLOCKED verdict survives two later approvals" "$(node "$CLI" parse --file "$TMP/r1.md")" \
  'o.rounds.length === 3 && o.rounds[0].verdict === "🚫 BLOCKED" && o.latest.verdict === "✅ APPROVED"'
check "an older multi-round file without the row has no round 1 verdict" "$(node "$CLI" parse --file "$FIX/gate1-locked.md")" \
  'o.rounds[0].verdict === null && o.latest.verdict === "✅ APPROVED"'
grep -v '^| \*\*Verdict\*\* |' "$TMP/expected-initial.md" > "$TMP/no-row.md"
check "a single-round file without the row reads the top Verdict line" "$(node "$CLI" parse --file "$TMP/no-row.md")" \
  'o.rounds.length === 1 && o.latest.verdict === "🚫 BLOCKED"'
check "parse reads each finding's domains" "$(node "$CLI" parse --file "$FIX/expected-initial.md")" \
  'o.latest.in_scope_findings.find(f => f.id === "HIGH-001").domains.join() === "pe-go"'

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

# Free text that holds a fence never hides a later round: fenced recommendation, dismissal, receipt, and an
# unclosed fence in a description, each followed by another appended round.
for kind in recommendation dismissal receipt unclosed; do
  cp "$FIX/expected-initial.md" "$TMP/fence-$kind.md"
  node -e '
const r = require(process.argv[1]); const kind = process.argv[2]; const fence = "```";
const block = fence + "js\nconst x = safe(y);\n" + fence;
r.head_sha = "abc1234";
const f = { severity: "LOW", in_scope: true, category: "docs", title: "T", location: "a.md:1", domains: ["pe-go"], description: "d", recommendation: "Fix." };
if (kind === "recommendation") f.recommendation = block;
if (kind === "unclosed") f.description = "Quoted:\n" + fence + "js\nconst x = 1;";
r.findings = [f];
r.dismissed = kind === "dismissal" ? [{ title: "T", rationale: block, original_severity: "MEDIUM", outcome: "dismissed" }] : [];
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
r.findings = [f]; r.receipts = [];
console.log(JSON.stringify(r));' "$FIX/gate2-round.json" "$1" "$2"; }
mk abc1234 unclosed | node "$CLI" render --file "$TMP/wedge.md" >/dev/null
mk def5678 fenced | node "$CLI" render --file "$TMP/wedge.md" >/dev/null; code=$?
if [ "$code" -eq 0 ]; then pass "a fenced round after an unclosed fence renders"; else fail "fenced round after unclosed fence exit $code"; fi
check "a fenced round after an unclosed fence is the parsed latest" "$(node "$CLI" parse --file "$TMP/wedge.md")" \
  'o.latest.n === 3 && o.latest.reviewed_sha === "def5678"'

# --- gate2: MERGEABLE comes from the PR's reviews ----------------------------------------
# reviews <json-array> — the next `gh pr view 7 --json author,reviews` answers with these reviews (author octocat)
reviews() {
  printf '{"author":{"login":"octocat"},"reviews":%s}\n' "$1" > "$STUB_GH_DIR/view.json"
  printf 'pr view 7 --json author,reviews\t0\tview.json\n' > "$STUB_GH_DIR/routes"
}
rv() { printf '{"author":{"login":"%s"},"state":"%s","commit":{"oid":"%s"},"submittedAt":"%s"}' "$1" "$2" "$3" "$4"; }
g() { node "$CLI" gate2 --pr 7 --head "$1" --root "$G" <<<"$2"; }
CI_PASSED='"ci":{"state":"passed","reason":"checks passed"}'
ME_OK='{"reviewer":"monalisa","verdict":"✅ APPROVED",'"$CI_PASSED"'}'

reviews '[]'
check "gate2: the sole reviewer approves → MERGEABLE" "$(g "$C" "$ME_OK")" \
  'o.gate_status === "MERGEABLE — all Gate 2 reviewers approved on current HEAD" && o.ci_hold === false && o.reviewers.length === 1 && o.reviewers[0].current'
reviews "[$(rv hubot APPROVED "$A" 2026-10-12T10:00:00Z)]"
check "gate2: an approval before a review-doc commit still counts (same code)" "$(g "$B" "$ME_OK")" \
  'o.gate_status.startsWith("MERGEABLE")'
check "gate2: an approval before a code change does not" "$(g "$C" "$ME_OK")" \
  'o.gate_status.startsWith("OPEN — Gate 2 reviewer(s) outstanding") && o.gate_status.includes("@hubot (approved '"${A:0:7}"', not the current code)")'
reviews "[$(rv hubot APPROVED "$B" 2026-10-12T10:00:00Z),$(rv hubot CHANGES_REQUESTED "$B" 2026-10-12T11:00:00Z)]"
check "gate2: a peer's later changes-requested stands over their earlier approval" "$(g "$B" "$ME_OK")" \
  'o.gate_status.includes("@hubot (changes requested)")'
reviews "[$(rv hubot APPROVED "$C" 2026-10-12T12:00:00Z),$(rv hubot CHANGES_REQUESTED "$A" 2026-10-12T09:00:00Z)]"
check "gate2: the latest review by time wins, whatever the list order" "$(g "$C" "$ME_OK")" 'o.gate_status.startsWith("MERGEABLE")'
reviews "[$(rv hubot APPROVED "$C" 2026-10-12T10:00:00Z),$(rv hubot COMMENTED "$C" 2026-10-12T11:00:00Z)]"
check "gate2: a later comment does not withdraw an approval" "$(g "$C" "$ME_OK")" 'o.gate_status.startsWith("MERGEABLE")'
reviews "[$(rv hubot APPROVED "$C" 2026-10-12T10:00:00Z),$(rv hubot DISMISSED "$C" 2026-10-12T11:00:00Z)]"
check "gate2: a dismissed review is not an approval" "$(g "$C" "$ME_OK")" 'o.gate_status.includes("@hubot (dismissed)")'
reviews "[$(rv octocat CHANGES_REQUESTED "$A" 2026-10-12T10:00:00Z),$(rv hubot APPROVED "$C" 2026-10-12T10:00:00Z)]"
check "gate2: the PR author's own reviews never count" "$(g "$C" "$ME_OK")" \
  'o.gate_status.startsWith("MERGEABLE") && !o.reviewers.some(r => r.login === "octocat")'
check "gate2: this round's changes-requested keeps the gate OPEN" \
  "$(g "$C" '{"reviewer":"monalisa","verdict":"⚠️ CHANGES REQUESTED",'"$CI_PASSED"'}')" \
  'o.gate_status.includes("@monalisa (this round: ⚠️ CHANGES REQUESTED)")'
reviews "[$(rv MonaLisa CHANGES_REQUESTED "$A" 2026-10-12T10:00:00Z),$(rv hubot APPROVED "$B" 2026-10-12T10:00:00Z)]"
check "gate2: this round supersedes the reviewer's own earlier review (login case-insensitive)" "$(g "$B" "$ME_OK")" \
  'o.gate_status.startsWith("MERGEABLE") && o.reviewers.length === 2'
reviews "[$(rv hubot APPROVED 0123456789abcdef0123456789abcdef01234567 2026-10-12T10:00:00Z)]"
check "gate2: an approval on a commit this clone lacks is not the current code" "$(g "$C" "$ME_OK")" 'o.gate_status.includes("not the current code")'
printf 'pr view 7\t1\tfail.stderr\n' > "$STUB_GH_DIR/routes"; echo 'HTTP 502' > "$STUB_GH_DIR/fail.stderr"
out="$(g "$C" "$ME_OK" 2>/dev/null)"; code=$?
if [ "$code" -eq 2 ]; then pass "gate2: a gh failure fails closed (exit 2)"; else fail "gate2 gh failure (exit $code): $out"; fi
for bad in '' ',"reviews":"x"'; do
  printf '{"author":{"login":"octocat"}%s}\n' "$bad" > "$STUB_GH_DIR/view.json"
  printf 'pr view 7 --json author,reviews\t0\tview.json\n' > "$STUB_GH_DIR/routes"
  out="$(g "$C" "$ME_OK" 2>/dev/null)"; code=$?
  if [ "$code" -eq 2 ]; then pass "gate2: a PR view without a reviews list fails closed (exit 2): {$bad}"; else fail "gate2 without a reviews list (exit $code): $out"; fi
done
reviews "[$(rv hubot APPROVED --output=x 2026-10-12T10:00:00Z)]"
check "gate2: an option-shaped commit oid never reaches git (not the current code)" "$(cd "$TMP" && g "$C" "$ME_OK")" \
  'o.gate_status.includes("@hubot (approved --outpu, not the current code)")'
if [ ! -e "$TMP/x" ] && [ ! -e "$G/x" ]; then pass "gate2: an option-shaped oid writes no file"; else fail "gate2 passed an option-shaped oid to git"; fi
node "$CLI" gate2 --pr 7 --head HEAD --root "$G" <<<"$ME_OK" >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "gate2: a non-SHA --head exits 2"; else fail "gate2 --head HEAD (exit $code)"; fi
out="$(node "$CLI" gate2 --pr 7 --head "$C" --root "$TMP/no-such-dir" <<<"$ME_OK" 2>/dev/null)"; code=$?
if [ "$code" -eq 2 ] && printf '%s' "$out" | grep -qF 'does not exist'; then pass "gate2: a --root that does not exist exits 2 before any gh call"; else fail "gate2 --root missing (exit $code): $out"; fi

# --- gate2: CI holds before any review is read ---------------------------------------
: > "$STUB_GH_DIR/calls"
check "gate2: no check ran HEAD's code (none) reads the reviews" \
  "$(reviews '[]'; g "$C" '{"reviewer":"monalisa","verdict":"✅ APPROVED","ci":{"state":"none","reason":"no checks"}}')" \
  'o.gate_status.startsWith("MERGEABLE") && o.ci_hold === false'
: > "$STUB_GH_DIR/calls"
for s in pending incomplete; do
  check "gate2: CI $s holds an approved round OPEN" \
    "$(g "$C" '{"reviewer":"monalisa","verdict":"✅ APPROVED","ci":{"state":"'$s'","reason":"checks on 5d6e7f8 are running"}}')" \
    'o.gate_status === "OPEN — Gate 2 waiting on CI: checks on 5d6e7f8 are running" && o.ci_hold === true'
done
check "gate2: unreadable CI is never MERGEABLE" \
  "$(g "$C" '{"reviewer":"monalisa","verdict":"✅ APPROVED","ci":{"state":"unreadable","reason":"gh api timed out"}}')" \
  'o.gate_status === "OPEN — Gate 2 CI status unreadable: gh api timed out" && o.ci_hold === true'
check "gate2: failed CI is never MERGEABLE, even with an approved verdict" \
  "$(g "$C" '{"reviewer":"monalisa","verdict":"✅ APPROVED","ci":{"state":"failed","reason":"checks on 5d6e7f8 failed: build"}}')" \
  'o.gate_status === "OPEN — Gate 2 CI failed: checks on 5d6e7f8 failed: build" && o.ci_hold === true'
check "gate2: a CI reason cannot break the status table cell" \
  "$(g "$C" '{"reviewer":"monalisa","verdict":"✅ APPROVED","ci":{"state":"unreadable","reason":"a|b\nc"}}')" \
  'o.gate_status === "OPEN — Gate 2 CI status unreadable: a\\|b c"'
if [ ! -s "$STUB_GH_DIR/calls" ]; then pass "gate2: a CI hold reads no reviews"; else fail "gate2 called gh under a CI hold: $(cat "$STUB_GH_DIR/calls")"; fi
for bad in '{"reviewer":"monalisa","verdict":"✅ APPROVED"}' '{"reviewer":"monalisa","verdict":"✅ APPROVED","ci":{"state":"green"}}' \
           '{"reviewer":"monalisa","verdict":"LGTM",'"$CI_PASSED"'}'; do
  out="$(g "$C" "$bad" 2>/dev/null)"; code=$?
  if [ "$code" -eq 2 ]; then pass "gate2: bad input fails closed (exit 2): $bad"; else fail "gate2 bad input (exit $code): $out"; fi
done
node "$CLI" gate2 --pr x7 --head "$C" --root "$G" <<<"$ME_OK" >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "gate2: a non-numeric --pr exits 2"; else fail "gate2 --pr x7 (exit $code)"; fi
node "$CLI" gate2 --pr 7 --head "$C" <<<"$ME_OK" >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "gate2: a missing --root exits 2"; else fail "gate2 without --root (exit $code)"; fi

# --- consumer contract: the fields deliver and pull-request read -----------------
# Both skills take verdict, round, and SHA from `latest`, and the Gate 1 lock from `gate1`.
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
# --- gate1: the latest Gate 1 round decides the lock ------------------------------------------
gate1() { node "$CLI" parse --file "$1" | node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(0,"utf8")).gate1))'; }
check "gate1: a single open round" "$(gate1 "$FIX/expected-initial.md")" 'o.state === "open" && o.round === 1 && o.sha === "1a2b3c4"'
check "gate1: a locked round" "$(gate1 "$FIX/gate1-locked.md")" 'o.state === "locked" && o.round === 3 && o.sha === "5d6e7f8"'
check "gate1: a later Gate 2 round does not count" "$(gate1 "$FIX/expected-gate2.md")" 'o.state === "locked" && o.round === 3'
check "gate1: hand-written files" "$(gate1 "$FIX/legacy-gate2-mergeable.md")" 'o.state === "locked" && o.round === 3 && o.sha === "27dab03"'
cp "$FIX/gate1-locked.md" "$TMP/stale.md"
node -e 'const r=require(process.argv[1]); r.head_sha="9f9f9f9"; console.log(JSON.stringify(r))' "$FIX/gate1-initial.json" \
  | node "$CLI" render --file "$TMP/stale.md" >/dev/null
check "gate1: a dirty Gate 1 round after the lock reopens it" "$(gate1 "$TMP/stale.md")" 'o.state === "open" && o.round === 4 && o.sha === "9f9f9f9"'
check "gate1: no review yet" "$(node "$CLI" parse --root "$TMP/nowhere" --name 42)" 'o.gate1.state === "none" && o.gate1.round === null && o.gate1.sha === null'
PARTIAL="OPEN — not a branch review; no findings ledger"
cp "$FIX/gate1-locked.md" "$TMP/partial.md"
clean 6e6e6e6 "$PARTIAL" | node "$CLI" render --file "$TMP/partial.md" >/dev/null
check "gate1: a Staged / Files / Folder / Ad-hoc round after the lock leaves it locked" "$(node "$CLI" parse --file "$TMP/partial.md")" \
  'o.gate1.state === "locked" && o.gate1.round === 3 && o.latest.n === 4 && JSON.stringify(o.partial_rounds) === "[4]"'
if grep -qx '## Review Round 4' "$TMP/partial.md"; then pass "a partial-scope round carries no Gate 1 note"; else fail "partial-scope round heading: $(grep -m1 '^## Review Round 4' "$TMP/partial.md")"; fi
node -e 'const r=require(process.argv[1]); r.head_sha="7f7f7f7"; r.gate_status=process.argv[2]; console.log(JSON.stringify(r))' "$FIX/gate1-initial.json" "$PARTIAL" \
  | node "$CLI" render --file "$TMP/partial.md" >/dev/null
cp "$TMP/partial.md" "$TMP/partial.before"
node "$CLI" override --file "$TMP/partial.md" <<<'{"round":5,"reviewer":"octocat","reason":"x","findings":[{"id":"HIGH-001","title":"Username concatenated into a SQL query"}]}' >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ] && cmp -s "$TMP/partial.md" "$TMP/partial.before"; then pass "override refuses a partial-scope round"; else fail "override of a partial-scope round (exit $code)"; fi
check "gate1: a dirty partial-scope round never reopens the branch lock" "$(node "$CLI" parse --file "$TMP/partial.md")" \
  'o.gate1.state === "locked" && o.gate1.round === 3 && JSON.stringify(o.partial_rounds) === "[4,5]"'
clean 8a8a8a8 | node "$CLI" render --file "$TMP/partial-clean.md" >/dev/null
clean 8a8a8a8 "$PARTIAL" | node "$CLI" render --file "$TMP/partial-clean.md" >/dev/null
if grep -qx '## Review Round 2' "$TMP/partial-clean.md"; then pass "a partial-scope round after a clean branch round carries no note"; else fail "partial round note: $(grep -m1 '^## Review Round 2' "$TMP/partial-clean.md")"; fi
clean 9b9b9b9 "$PARTIAL" | node "$CLI" render --file "$TMP/partial-only.md" >/dev/null
clean 9b9b9b9 | node "$CLI" render --file "$TMP/partial-only.md" >/dev/null; code=$?
if [ "$code" -eq 0 ] && grep -qx '## Review Round 2' "$TMP/partial-only.md"; then
  pass "a branch round after only partial-scope rounds renders with no note"
else
  fail "branch round after only partial rounds (exit $code): $(grep -m1 '^## Review Round 2' "$TMP/partial-only.md")"
fi
cp "$FIX/expected-initial.md" "$TMP/partial-note.md"
clean 8a8a8a8 "$PARTIAL" | node "$CLI" render --file "$TMP/partial-note.md" >/dev/null
clean 8a8a8a8 | node "$CLI" render --file "$TMP/partial-note.md" >/dev/null
if grep -qx '## Review Round 3' "$TMP/partial-note.md"; then pass "a branch round after a clean partial-scope round takes no note from it"; else fail "note taken from a partial round: $(grep -m1 '^## Review Round 3' "$TMP/partial-note.md")"; fi

# --- override: the single writer of an engineer override ----------------------------------------
cp "$TMP/expected-initial.md" "$TMP/ovr.md"
OVR='{"round":1,"reviewer":"@octocat","reason":"ship the fix | track the rest\nin #43","findings":[{"id":"HIGH-001","title":"Username concatenated into a SQL query"}]}'
out="$(node "$CLI" override --file "$TMP/ovr.md" <<<"$OVR")"
check "override reports the new gate status" "$out" 'o.round === 1 && o.gate_status === "OVERRIDDEN — ship the fix | track the rest in #43"'
if grep -qF '| **Gate Status** | OVERRIDDEN — ship the fix \| track the rest in #43 |' "$TMP/ovr.md" \
   && grep -qF -- '- HIGH-001: Username concatenated into a SQL query — overridden by @octocat' "$TMP/ovr.md" \
   && [ "$(grep -c '^## Overridden Findings$' "$TMP/ovr.md")" -eq 1 ] && [ "$(grep -c 'Generated with' "$TMP/ovr.md")" -eq 1 ]; then
  pass "override sets the round's Gate Status and writes one Overridden Findings section before the footer"
else
  fail "override output wrong"; tail -12 "$TMP/ovr.md"
fi
check "gate1: an overridden round" "$(gate1 "$TMP/ovr.md")" 'o.state === "overridden" && o.round === 1'
clean 2c2c2c2 | node "$CLI" render --file "$TMP/ovr.md" >/dev/null
if [ "$(grep -c '^## Overridden Findings$' "$TMP/ovr.md")" -eq 1 ]; then pass "the next round's render keeps the override"; else fail "the next render dropped the override"; fi
check "the overridden round still parses as overridden after the next round" "$(node "$CLI" parse --file "$TMP/ovr.md")" \
  'o.rounds.length === 2 && o.rounds[0].gate_status.startsWith("OVERRIDDEN") && o.gate1.state === "open" && o.gate1.round === 2'
# a middle round: the section lands inside round 2, before round 3
node "$CLI" render --file "$TMP/mid.md" < "$FIX/gate1-initial.json" >/dev/null
node -e 'const r=require(process.argv[1]); r.head_sha="2b2b2b2"; console.log(JSON.stringify(r))' "$FIX/gate1-initial.json" | node "$CLI" render --file "$TMP/mid.md" >/dev/null
clean 3c3c3c3 | node "$CLI" render --file "$TMP/mid.md" >/dev/null
node "$CLI" override --file "$TMP/mid.md" <<<'{"round":2,"reviewer":"octocat","reason":"accepted","findings":[{"id":"HIGH-001","title":"Username concatenated into a SQL query"}]}' >/dev/null
check "override of a middle round changes only that round" "$(node "$CLI" parse --file "$TMP/mid.md")" \
  'o.rounds.length === 3 && o.rounds[1].gate_status === "OVERRIDDEN — accepted" && !o.rounds[0].gate_status.startsWith("OVERRIDDEN") && !o.rounds[2].gate_status.startsWith("OVERRIDDEN")'
if awk '/^### Overridden Findings$/{s=NR} /^## Review Round 3/{r=NR} END{exit !(s && r && s < r)}' "$TMP/mid.md"; then
  pass "the middle round's section sits before round 3"
else
  fail "middle-round override misplaced"
fi
cp "$TMP/mid.md" "$TMP/mid.before"
for bad in '{"round":2,"reviewer":"octocat","reason":"again","findings":[]}' \
           '{"round":1,"reviewer":"octocat\n## Review Round 9","reason":"x","findings":[{"id":"HIGH-001","title":"Username concatenated into a SQL query"}]}' \
           '{"round":1,"reviewer":"octocat","reason":"x","findings":[{"id":"HIGH-009","title":"nope"}]}' \
           '{"round":9,"reviewer":"octocat","reason":"x","findings":[]}' \
           '{"round":1,"reviewer":"octocat","reason":" ","findings":[]}'; do
  node "$CLI" override --file "$TMP/mid.md" <<<"$bad" >/dev/null 2>&1; code=$?
  if [ "$code" -eq 2 ] && cmp -s "$TMP/mid.md" "$TMP/mid.before"; then pass "override refuses $bad and leaves the file"; else fail "override accepted $bad (exit $code)"; fi
done
cp "$TMP/expected-gate2.md" "$TMP/g2.md"
node "$CLI" override --file "$TMP/g2.md" <<<'{"round":4,"reviewer":"hubot","reason":"x","findings":[]}' >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ] && cmp -s "$TMP/g2.md" "$TMP/expected-gate2.md"; then pass "override refuses a Gate 2 round"; else fail "override of a Gate 2 round (exit $code)"; fi

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
LOCAL="$HOME/.claude/sdlc/reviews/octo-org/octo-repo"
node "$CLI" render --file "$LOCAL/42-pr7-code-review.md" < "$FIX/gate2-round.json" >/dev/null
check "parse --local reads the reviewer's own Gate 2 review under ~/.claude, keyed by PR" "$(node "$CLI" parse --local octo-org/octo-repo --pr 7 --name 42)" \
  'o.rounds.length === 1 && o.markdown_path === "'"$LOCAL"'/42-pr7-code-review.md" && o.gate1.state === "none"'
check "parse --local: another PR for the same ticket has its own doc" "$(node "$CLI" parse --local octo-org/octo-repo --pr 8 --name 42)" \
  'o.next_round === 1 && o.markdown_path === "'"$LOCAL"'/42-pr8-code-review.md"'
check "parse --local with no review yet starts at round 1" "$(node "$CLI" parse --local octo-org/other --pr 7 --name 42)" \
  'o.next_round === 1 && o.markdown_path.endsWith("/.claude/sdlc/reviews/octo-org/other/42-pr7-code-review.md")'
for bad in 'octo-org' 'a/b/c' '../x' 'a/..'; do
  node "$CLI" parse --local "$bad" --pr 7 --name 42 >/dev/null 2>&1; code=$?
  if [ "$code" -eq 2 ]; then pass "parse --local rejects \"$bad\" (exit 2)"; else fail "parse --local accepted \"$bad\" (exit $code)"; fi
done
for args in "--local octo-org/octo-repo --name 42" "--local octo-org/octo-repo --pr 0 --name 42" "--local octo-org/octo-repo --pr 7x --name 42" "--root $REPO --pr 7 --name 42"; do
  # shellcheck disable=SC2086 # word-split on purpose: each entry is an argument list
  node "$CLI" parse $args >/dev/null 2>&1; code=$?
  if [ "$code" -eq 2 ]; then pass "parse $args exits 2"; else fail "parse $args (exit $code)"; fi
done
node "$CLI" parse --root "$REPO" --local octo-org/octo-repo --name 42 >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "parse with both --root and --local exits 2"; else fail "parse --root --local (exit $code)"; fi

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
cp "$TMP/expected-initial.md" "$TMP/fake-round.md"
node -e 'const r=require(process.argv[1]); r.head_sha="5e5e5e5"; r.findings[1].description="Quoted:\n## Review Round 99"; console.log(JSON.stringify(r))' "$FIX/gate1-initial.json" \
  | node "$CLI" render --file "$TMP/fake-round.md" >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ] && cmp -s "$TMP/fake-round.md" "$TMP/expected-initial.md"; then
  pass "an appended round that would parse as another round fails closed and leaves the file"
else
  fail "unfenced round heading in a description (exit $code)"
fi
node "$CLI" parse --file "$TMP/missing.md" >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "parse of a missing file exits 2"; else fail "parse missing file (exit $code)"; fi
node "$CLI" bogus >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "unknown command exits 2"; else fail "unknown command (exit $code)"; fi

echo "=================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] && [ "$fails" -eq 0 ]
