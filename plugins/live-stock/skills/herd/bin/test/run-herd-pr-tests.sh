#!/usr/bin/env bash
# Fixture tests for herd-pr.js — the ready verdict (approval on or after the last code commit, checks, mergeability,
# threads, changes requested, --after holds), the head-SHA-guarded merge and the reviewer re-request.
# gh is stub-gh.js; sdlc's bin/pr-checks.js is a stub in a fake sdlc root. No network.
# No npm packages — bash + node only. Exit 0 = all cases pass, 1 = any fail.
# shellcheck disable=SC2015 # pass and fail always return 0, so A && pass || fail is an if/else
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../herd-pr.js"
NODE="$(command -v node)"
[ -n "$NODE" ] || { echo "FAIL: node not on PATH — cannot run herd-pr tests" >&2; exit 1; }
[ -f "$CLI" ] || { echo "FAIL: herd-pr.js not found at $CLI" >&2; exit 1; }

TMP="$(cd "$(mktemp -d)" && pwd -P)" # resolved, so the pr-checks stub's cwd matches it
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

REPO='octo-org/octo-repo'
P="repos/$REPO/pulls/42"
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
D=dddddddddddddddddddddddddddddddddddddddd
DOCS='[{"filename":"docs/code-reviews/42-code-review.md","status":"modified"}]'
CODE='[{"filename":"src/app.js","status":"modified"}]'
NO_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'

newcase() {
  CASE="$TMP/case$RANDOM$RANDOM"
  mkdir -p "$CASE/home" "$CASE/bin" "$CASE/fx" "$CASE/checkout" "$CASE/sdlc/.claude-plugin" "$CASE/sdlc/bin"
  ln -s "$HERE/stub-gh.js" "$CASE/bin/gh"
  ln -s "$NODE" "$CASE/bin/node"
  printf '{"name":"sdlc","version":"9.9.9"}' > "$CASE/sdlc/.claude-plugin/plugin.json"
  cat > "$CASE/sdlc/bin/pr-checks.js" <<'JS'
const fs = require('fs');
const d = process.env.HERD_FIXTURES;
fs.appendFileSync(`${d}/checks-calls.log`, `${JSON.stringify({ cwd: process.cwd(), argv: process.argv.slice(2),
  gh: process.env.SDLC_GH || null, timeout: process.env.SDLC_GH_TIMEOUT_MS || null, repo: process.env.GH_REPO || null })}\n`);
const f = `${d}/checks.json`;
if (!fs.existsSync(f)) { process.stdout.write('{"error":"stub: no checks fixture"}'); process.exit(2); }
process.stdout.write(fs.readFileSync(f, 'utf8'));
JS
  cat > "$CASE/config.json" <<JSON
{"projects":{"octo":{"repo":"$REPO","checkout":"$CASE/checkout","main_push":"pr-only","merge_method":"squash"}},
 "review_request_authors":[],"defaults":{}}
JSON
  : > "$CASE/fx/routes"
  threads "$NO_THREADS"
}
# route <ERE over gh's args> <reply>... — reply is JSON or a stub-gh token (EXIT:n HTTP:n RATE SLEEP:s), or
# HTTPF|ERRF|OUTF:<code>:<text>; several replies are served in order. Replaces any earlier route with the same ERE.
route() {
  local key="$1" r f replies=""; shift
  awk -F'\t' -v k="$key" '$1 != k' "$CASE/fx/routes" > "$CASE/fx/routes.tmp" && mv "$CASE/fx/routes.tmp" "$CASE/fx/routes"
  for r in "$@"; do
    case "$r" in
      EXIT:*|HTTP:*|RATE|SLEEP:*) ;;
      HTTPF:*|ERRF:*|OUTF:*) f="r$RANDOM$RANDOM.json"; printf '%s' "${r#*:*:}" > "$CASE/fx/$f"; r="${r%%:*}:$(cut -d: -f2 <<<"$r"):$f" ;;
      *) f="r$RANDOM$RANDOM.json"; printf '%s' "$r" > "$CASE/fx/$f"; r="$f" ;;
    esac
    replies="$replies${replies:+,}$r"
  done
  printf '%s\t%s\n' "$key" "$replies" >> "$CASE/fx/routes"
}
# pr <state> <head> [isDraft] [mergeable] [mergeStateStatus] [baseRefName]
pr() {
  route "^pr view 42 -R $REPO --json number," \
    "{\"number\":42,\"state\":\"$1\",\"isDraft\":${3:-false},\"headRefOid\":\"$2\",\"headRefName\":\"feat/42-x\",\"baseRefName\":\"${6-main}\",\"mergeable\":\"${4:-MERGEABLE}\",\"mergeStateStatus\":\"${5:-CLEAN}\",\"mergeCommit\":null,\"url\":\"https://github.com/$REPO/pull/42\"}"
}
other()     { route "^pr view $1 -R $REPO --json state\$" "{\"state\":\"$2\"}"; }
commits()   { route "^api $P/commits --paginate --slurp\$" "[[$1]]"; }
files_of()  { route "^api repos/$REPO/commits/$1\$" "{\"sha\":\"$1\",\"files\":$2}"; }
reviews()   { route "^api $P/reviews --paginate --slurp\$" "[[$1]]"; }
threads()   { route '^api graphql .*reviewThreads' "$@"; }
# mq <reply> — the merge-queue check: mq yes | mq no | mq <token or JSON>
mq() {
  case "$1" in
    yes) route '^api graphql .*mergeQueue' '{"data":{"repository":{"mergeQueue":{"id":"MQ_kwDOtest"}}}}' ;;
    no)  route '^api graphql .*mergeQueue' '{"data":{"repository":{"mergeQueue":null}}}' ;;
    *)   route '^api graphql .*mergeQueue' "$1" ;;
  esac
}
checks()    { printf '{"state":"%s","head":"%s","checks":[],"failed_checks":[],"reason":"stub"}' "$1" "${2:-$A}" > "$CASE/fx/checks.json"; }
merge_put() { route "^api $P/merge -X PUT " "$@"; }
merged_view() { route "^pr view 42 -R $REPO --json mergeCommit\$" "$@"; }
c()   { printf '{"sha":"%s","commit":{"message":"m"}}' "$1"; }
# rv <login> <state> <commit> [review id]
rv()  { printf '{"id":%s,"user":{"login":"%s"},"state":"%s","commit_id":"%s","submitted_at":"2026-11-20T10:00:00Z"}' "${4:-1}" "$1" "$2" "$3"; }
# thr <isResolved>...
thr() {
  local n="" t
  for t in "$@"; do n="$n${n:+,}{\"isResolved\":$t}"; done
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[%s],"pageInfo":{"hasNextPage":%s,"endCursor":"cur1"}}}}}}' "$n" "${MORE:-false}"
}

# ok_head — one code commit A, octocat approved A, checks passed, no threads
ok_head() {
  newcase; pr OPEN "$A"; commits "$(c $A)"; files_of "$A" "$CODE"; reviews "$(rv octocat APPROVED $A)"; checks passed
}
# ok_tail — code A approved, then review-record B is the head
ok_tail() {
  newcase; pr OPEN "$B"; commits "$(c $A),$(c $B)"; files_of "$B" "$DOCS"; files_of "$A" "$CODE"
  reviews "$(rv octocat APPROVED $A)"; checks passed "$B"
}
run() {
  out="$(cd "$CASE" && env -i HOME="$CASE/home" PATH="$CASE/bin" HERD_FIXTURES="$CASE/fx" HERD_CONFIG="$CASE/config.json" \
    HERD_SDLC_ROOT="$CASE/sdlc" HERD_GH_TIMEOUT_MS=2000 "$NODE" "$CLI" "$@" 2>/dev/null)"
  code=$?
}
check() {
  local name="$1" want="$2" expr="$3"
  if [ "$code" -eq "$want" ] && "$NODE" -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$out" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — exit $code, got: $out"
  fi
}
calls()   { cat "$CASE/fx/gh-calls.log" 2>/dev/null; }
writes()  { grep -cE '"(PUT|POST|PATCH|DELETE)"|"merge"' "$CASE/fx/gh-calls.log" 2>/dev/null || true; }
unrouted() { [ ! -s "$CASE/fx/gh-unrouted.log" ]; }

# --- ready ------------------------------------------------------------------
ok_head; run ready --pr 'octo#42' --reviewer octocat
check "approved at the head → ready" 0 "o.verdict === 'ready' && o.target === '$A' && o.head === '$A' && o.pr === 'octo#42' && o.base === 'main' && o.reasons.length === 0"
grep -q "\"cwd\":\"$CASE/checkout\"" "$CASE/fx/checks-calls.log" && grep -q "\"argv\":\[\"check\",\"--pr\",\"42\",\"--head\",\"$A\",\"--settle\",\"20\"\]" "$CASE/fx/checks-calls.log" \
  && pass "pr-checks runs from the project checkout with check --pr N --head SHA --settle 20" || fail "pr-checks runs from the project checkout — $(cat "$CASE/fx/checks-calls.log")"
grep -q '"timeout":"2000"' "$CASE/fx/checks-calls.log" && pass "pr-checks gets herd's gh timeout" || fail "pr-checks gets herd's gh timeout"
grep -q "\"repo\":\"$REPO\"" "$CASE/fx/checks-calls.log" && pass "pr-checks gets GH_REPO = the configured repo" || fail "pr-checks gets GH_REPO — $(cat "$CASE/fx/checks-calls.log")"

ok_head; run ready --pr 'octo#42' --reviewer OctoCat
check "--reviewer matches review logins case-insensitively" 0 "o.verdict === 'ready' && o.checks.approval.ok === true && o.checks.approval.reviewer === 'OctoCat'"

ok_head; reviews "$(rv OctoCat APPROVED $A 31),$(rv octocat CHANGES_REQUESTED $A 32)"; run ready --pr 'octo#42' --reviewer octocat
check "reviews by one login in different cases share one decisive review" 0 \
  "o.verdict === 'blocked' && o.checks.approval.ok === false && o.checks.changes_requested.by.length === 1 && o.checks.changes_requested.by[0].review_id === 32"
unrouted && pass "ready makes only the contract's gh calls" || fail "ready makes only the contract's gh calls — $(cat "$CASE/fx/gh-unrouted.log")"
calls | grep -q '"-F","number=42"' && calls | grep -q '"-f","owner=octo-org"' && calls | grep -q '"-f","repo=octo-repo"' \
  && pass "the threads query names owner, repo and number" || fail "the threads query names owner, repo and number — $(calls)"

ok_head; run ready --pr 'octo#42' --reviewer octocat
(cd "$CASE" && env -i HOME="$CASE/home" PATH="$CASE/bin" HERD_FIXTURES="$CASE/fx" HERD_CONFIG="$CASE/config.json" \
  HERD_SDLC_ROOT="$CASE/sdlc" HERD_GH="$CASE/bin/gh" "$NODE" "$CLI" ready --pr 'octo#42' --reviewer octocat >/dev/null 2>&1)
tail -1 "$CASE/fx/checks-calls.log" | grep -q "\"gh\":\"$CASE/bin/gh\"" && pass "pr-checks uses HERD_GH as SDLC_GH" || fail "pr-checks uses HERD_GH as SDLC_GH"

ok_tail; run ready --pr 'octo#42' --reviewer octocat
check "only review-record commits after the approval → ready" 0 "o.verdict === 'ready' && o.target === '$A' && o.head === '$B'"

newcase; pr OPEN "$C"; commits "$(c $A),$(c $C)"; files_of "$C" "$CODE"; files_of "$A" "$CODE"
reviews "$(rv octocat APPROVED $A)"; checks passed "$C"
run ready --pr 'octo#42' --reviewer octocat
check "a code commit after the approval → wait" 0 \
  "o.verdict === 'wait' && o.target === '$C' && o.checks.approval.ok === false && /predates the target cccccccc/.test(o.reasons[0])"

ok_tail; reviews "$(rv octocat APPROVED $B)"; run ready --pr 'octo#42' --reviewer octocat
check "an approval on a review-record commit after the target → ready" 0 "o.verdict === 'ready' && o.checks.approval.commit === '$B'"

newcase; pr OPEN "$B"; commits "$(c $A),$(c $B)"; files_of "$B" "$DOCS"; files_of "$A" "$DOCS"
reviews "$(rv octocat APPROVED $A)"; checks passed "$B"
run ready --pr 'octo#42' --reviewer octocat
check "no commit touches code → the oldest commit is the target" 0 "o.verdict === 'ready' && o.target === '$A'"

ok_tail; files_of "$B" '[{"filename":"docs/code-reviews/app.js","previous_filename":"src/app.js","status":"renamed"}]'
run ready --pr 'octo#42' --reviewer octocat
check "a rename out of a code path counts as code" 0 "o.verdict === 'wait' && o.target === '$B'"

ok_tail; files_of "$B" '[]'; run ready --pr 'octo#42' --reviewer octocat
check "a commit with no files is not a code commit" 0 "o.verdict === 'ready' && o.target === '$A'"

ok_head; reviews ""; run ready --pr 'octo#42' --reviewer octocat
check "no approval → wait" 0 "o.verdict === 'wait' && o.checks.approval.ok === false && o.reasons[0] === 'octocat has not approved'"

ok_head; reviews "$(rv hubot APPROVED $A)"; run ready --pr 'octo#42' --reviewer octocat
check "an approval by someone else does not count" 0 "o.verdict === 'wait'"

ok_head; reviews "$(rv octocat DISMISSED $A)"; run ready --pr 'octo#42' --reviewer octocat
check "a dismissed approval → wait" 0 "o.verdict === 'wait' && o.checks.approval.review_state === 'DISMISSED' && /dismissed/.test(o.reasons[0])"

ok_head; reviews "$(rv octocat APPROVED $A),$(rv octocat DISMISSED $A)"; run ready --pr 'octo#42' --reviewer octocat
check "a later DISMISSED review cancels the approval" 0 "o.verdict === 'wait' && o.checks.approval.ok === false"

ok_head; reviews "$(rv octocat APPROVED $A 11),$(rv octocat CHANGES_REQUESTED $A 12)"; run ready --pr 'octo#42' --reviewer octocat
check "a later CHANGES_REQUESTED from the reviewer cancels the approval → blocked" 0 \
  "o.verdict === 'blocked' && o.checks.approval.ok === false && o.checks.changes_requested.by.map((b) => b.login).join() === 'octocat'"

ok_head; reviews "$(rv octocat CHANGES_REQUESTED $A),$(rv octocat APPROVED $A)"; run ready --pr 'octo#42' --reviewer octocat
check "a re-approval after requesting changes → ready" 0 "o.verdict === 'ready' && o.checks.changes_requested.ok === true"

ok_head; reviews "$(rv octocat APPROVED $A),$(rv octocat COMMENTED $A)"; run ready --pr 'octo#42' --reviewer octocat
check "a later COMMENTED review keeps the approval" 0 "o.verdict === 'ready'"

ok_head; reviews "$(rv octocat APPROVED $D)"; run ready --pr 'octo#42' --reviewer octocat
check "an approval on a commit no longer in the PR (force-push) → wait, saying so" 0 \
  "o.verdict === 'wait' && o.checks.approval.ok === false && o.reasons[0] === 'octocat\'s approval is on a commit no longer in the PR (dddddddd)'"

ok_head; checks failed; run ready --pr 'octo#42' --reviewer octocat
check "failed checks → blocked" 0 "o.verdict === 'blocked' && o.checks.ci.ok === false && o.reasons.includes('checks at the head are failed')"

ok_head; checks pending; run ready --pr 'octo#42' --reviewer octocat
check "pending checks → wait" 0 "o.verdict === 'wait' && o.checks.ci.state === 'pending'"

ok_head; checks none; run ready --pr 'octo#42' --reviewer octocat
check "no checks at the head → blocked" 0 "o.verdict === 'blocked'"

ok_head; checks incomplete; run ready --pr 'octo#42' --reviewer octocat
check "canceled checks → blocked" 0 "o.verdict === 'blocked'"

ok_head; checks bogus; run ready --pr 'octo#42' --reviewer octocat
check "an unknown checks state → exit 2" 2 "/unknown state/.test(o.error) && o.verdict === undefined"

ok_head; threads "$(thr true false true)"; run ready --pr 'octo#42' --reviewer octocat
check "an unresolved thread → blocked" 0 \
  "o.verdict === 'blocked' && o.checks.threads.ok === false && o.checks.threads.unresolved === 1 && o.reasons.includes('unresolved threads')"

ok_head; threads "$(thr true true)"; run ready --pr 'octo#42' --reviewer octocat
check "resolved threads → ready" 0 "o.verdict === 'ready' && o.checks.threads.ok === true && o.checks.threads.unresolved === 0"

ok_head; threads "$(MORE=true thr true)" "$(thr false)"; run ready --pr 'octo#42' --reviewer octocat
check "an unresolved thread on the second page → blocked" 0 "o.verdict === 'blocked' && o.checks.threads.unresolved === 1"
calls | grep -q '"-f","after=cur1"' && pass "the second threads page passes the cursor" || fail "the second threads page passes the cursor — $(calls)"

ok_head; threads '{"errors":[{"message":"bad field"}]}'; run ready --pr 'octo#42' --reviewer octocat
check "a GraphQL error → exit 2 naming it" 2 "/bad field/.test(o.error) && o.verdict === undefined"

ok_head; threads '{"data":{"repository":{"pullRequest":null}}}'; run ready --pr 'octo#42' --reviewer octocat
check "a missing pullRequest in GraphQL → exit 2" 2 "/review threads/.test(o.error)"

ok_head; reviews "$(rv octocat APPROVED $A),$(rv hubot CHANGES_REQUESTED $A 21)"; run ready --pr 'octo#42' --reviewer octocat
check "changes requested by any reviewer → blocked" 0 "o.verdict === 'blocked' && o.checks.changes_requested.by.map((b) => b.login).join() === 'hubot'"

ok_tail; reviews "$(rv octocat APPROVED $B),$(rv hubot CHANGES_REQUESTED $A 21),$(rv Copilot COMMENTED $B 22),$(rv hubot CHANGES_REQUESTED $B 23),$(rv mona CHANGES_REQUESTED $A 24)"
run ready --pr 'octo#42' --reviewer octocat
check "changes_requested names each reviewer's decisive review id and commit" 0 \
  "JSON.stringify(o.checks.changes_requested) === JSON.stringify({ ok: false, by: [{ login: 'hubot', review_id: 23, commit_id: '$B' }, { login: 'mona', review_id: 24, commit_id: '$A' }] }) && o.reasons.includes('changes requested by hubot, mona')"

ok_head; reviews "$(rv octocat APPROVED $A),$(rv hubot CHANGES_REQUESTED $A),$(rv hubot APPROVED $A)"; run ready --pr 'octo#42' --reviewer octocat
check "a reviewer who approved after requesting changes no longer blocks" 0 "o.verdict === 'ready'"

ok_head; pr OPEN "$A" true; run ready --pr 'octo#42' --reviewer octocat
check "a draft → blocked" 0 "o.verdict === 'blocked' && o.reasons.includes('PR is a draft') && o.checks.state.draft === true"

ok_head; pr MERGED "$A"; run ready --pr 'octo#42' --reviewer octocat
check "a merged PR → blocked" 0 "o.verdict === 'blocked' && o.checks.state.state === 'MERGED' && o.reasons.includes('PR is merged') && o.target === null"

ok_head; pr CLOSED "$A"; run ready --pr 'octo#42' --reviewer octocat
check "a closed PR → blocked" 0 "o.verdict === 'blocked' && o.reasons.includes('PR is closed')"

ok_head; pr OPEN "$A" false MERGEABLE BEHIND; run ready --pr 'octo#42' --reviewer octocat
check "a branch behind its base (BEHIND) → blocked need_rebase" 0 \
  "o.verdict === 'blocked' && o.checks.mergeable.ok === false && o.reasons.includes('branch is not mergeable: need_rebase')"

ok_head; pr OPEN "$A" false CONFLICTING DIRTY; run ready --pr 'octo#42' --reviewer octocat
check "conflicts (CONFLICTING) → blocked" 0 "o.verdict === 'blocked' && o.reasons.includes('branch is not mergeable: conflicts')"

ok_head; pr OPEN "$A" false MERGEABLE DIRTY; run ready --pr 'octo#42' --reviewer octocat
check "a DIRTY merge state → blocked conflicts" 0 "o.verdict === 'blocked' && o.reasons.includes('branch is not mergeable: conflicts')"

ok_head; pr OPEN "$A" false UNKNOWN UNKNOWN; run ready --pr 'octo#42' --reviewer octocat
check "mergeability still computing (UNKNOWN) → wait" 0 "o.verdict === 'wait' && o.checks.mergeable.ok === false && o.checks.mergeable.mergeable === 'UNKNOWN'"

ok_head; pr OPEN "$A" false MERGEABLE BLOCKED; run ready --pr 'octo#42' --reviewer octocat
check "a BLOCKED merge state alone (branch protection) does not block the gate" 0 "o.verdict === 'ready' && o.checks.mergeable.merge_state === 'BLOCKED'"

ok_head; other 43 OPEN; run ready --pr 'octo#42' --reviewer octocat --after 'octo#43'
check "an unmerged --after → hold" 0 \
  "o.verdict === 'hold' && o.checks.after[0].pr === 'octo#43' && o.checks.after[0].ok === false && o.reasons[0] === 'octo#43 is open, not merged'"

ok_head; other 43 MERGED; other 44 MERGED; run ready --pr 'octo#42' --reviewer octocat --after 'octo#43' --after 'octo#44'
check "every --after merged → ready" 0 "o.verdict === 'ready' && o.checks.after.length === 2"

ok_head; checks failed; other 43 OPEN; run ready --pr 'octo#42' --reviewer octocat --after 'octo#43'
check "blocked outranks hold" 0 "o.verdict === 'blocked'"

ok_head; reviews ""; other 43 CLOSED; run ready --pr 'octo#42' --reviewer octocat --after 'octo#43'
check "hold outranks wait" 0 "o.verdict === 'hold'"

ok_head; run ready --pr 'octo#42' --reviewer octocat --after 'octo!43'
check "a malformed --after → exit 2" 2 "/--after/.test(o.error)"

ok_head; : > "$CASE/fx/routes"; route '^pr view 42 ' SLEEP:10
start=$SECONDS; run ready --pr 'octo#42' --reviewer octocat
[ $((SECONDS - start)) -lt 8 ] || fail "gh timeout is bounded"
check "a gh timeout → exit 2, never ready" 2 "/timed out/.test(o.error) && o.verdict === undefined"

ok_head; : > "$CASE/fx/routes"; route '^pr view 42 ' EXIT:1
run ready --pr 'octo#42' --reviewer octocat
check "a gh failure → exit 2" 2 "/failed/.test(o.error)"

ok_head; : > "$CASE/fx/routes"; route '^pr view 42 ' RATE
run ready --pr 'octo#42' --reviewer octocat
check "a rate limit → exit 2 naming it" 2 "/rate limit/.test(o.error) && o.verdict === undefined"

ok_head; route "^pr view 42 -R $REPO --json number," '{"number":42}'; run ready --pr 'octo#42' --reviewer octocat
check "a PR view without state or head → exit 2" 2 "/no state, head or base/.test(o.error)"

ok_head; pr OPEN "$A" false MERGEABLE CLEAN ""; run ready --pr 'octo#42' --reviewer octocat
check "a PR view without a base → exit 2" 2 "/no state, head or base/.test(o.error) && o.verdict === undefined"

ok_head; pr OPEN "$A" false MERGEABLE CLEAN release/2.x; run ready --pr 'octo#42' --reviewer octocat
check "ready reports the PR's base branch" 0 "o.verdict === 'ready' && o.base === 'release/2.x'"

ok_head; pr MERGED "$A" false MERGEABLE CLEAN release/2.x; run ready --pr 'octo#42' --reviewer octocat
check "a closed or merged PR still reports its base" 0 "o.verdict === 'blocked' && o.base === 'release/2.x'"

ok_head; route "^api $P/commits --paginate --slurp\$" HTTP:404; run ready --pr 'octo#42' --reviewer octocat
check "an unreadable commit list → exit 2" 2 "/failed/.test(o.error) && o.verdict === undefined"

ok_head; commits "$(c $B)"; run ready --pr 'octo#42' --reviewer octocat
check "a commit list that does not end at the head (250 cap) → exit 2" 2 "/does not end at its head/.test(o.error)"

ok_head; route "^api repos/$REPO/commits/$A\$" HTTP:500; run ready --pr 'octo#42' --reviewer octocat
check "an unreadable commit → exit 2, never ready" 2 "/failed/.test(o.error) && o.verdict === undefined"

ok_head; route "^api repos/$REPO/commits/$A\$" "{\"sha\":\"$A\"}"; run ready --pr 'octo#42' --reviewer octocat
check "a commit without a file list → exit 2" 2 "/no file list/.test(o.error)"

ok_head; route "^api $P/reviews --paginate --slurp\$" RATE; run ready --pr 'octo#42' --reviewer octocat
check "an unreadable review list → exit 2" 2 "/rate limit/.test(o.error) && o.verdict === undefined"

ok_head; route '^api graphql .*reviewThreads' EXIT:1; run ready --pr 'octo#42' --reviewer octocat
check "an unreadable thread list → exit 2" 2 "/failed/.test(o.error) && o.verdict === undefined"

ok_head; rm "$CASE/fx/checks.json"; run ready --pr 'octo#42' --reviewer octocat
check "a pr-checks error → exit 2" 2 "/checks/.test(o.error) && o.verdict === undefined"

ok_head; rm "$CASE/sdlc/.claude-plugin/plugin.json"; run ready --pr 'octo#42' --reviewer octocat
check "no sdlc plugin → exit 2" 2 "/sdlc plugin not found/.test(o.error)"

ok_head; run ready --pr 'zz#42' --reviewer octocat
check "an unknown project → exit 2" 2 "/zz/.test(o.error)"

ok_head; run ready --pr 'octo!42' --reviewer octocat
check "a project!n --pr → exit 2" 2 "/--pr must look like <project>#<n>/.test(o.error)"

ok_head; run ready --pr '42' --reviewer octocat
check "a malformed --pr → exit 2" 2 "/--pr/.test(o.error)"

ok_head; run ready --pr 'octo#42'
check "a missing --reviewer → exit 2" 2 "/reviewer/.test(o.error)"

ok_head; run ready --mr 'octo#42' --reviewer octocat
check "the old --mr flag → exit 2" 2 "/unknown option --mr/.test(o.error)"

# replay: a synthetic octo#42 — code C3 after a changes-requested round, octocat re-approved review record C4,
# Copilot only commented, hubot's review was dismissed, head C5 is a review record
R="$HERE/fixtures/herd-pr/octo-42"
newcase; cp "$R"/*.json "$CASE/fx/"
C3=80ea3bd71f9cc687650ca059f963d7716d652d7a C4=1a456159657e2a1c9aecd798108955157f486891 C5=a87e4241f294c7a1ec7a30426f2e266693b4657c
cat > "$CASE/fx/routes" <<ROUTES
^pr view 42 -R $REPO --json number,	pr.json
^api $P/commits --paginate --slurp\$	commits.json
^api $P/reviews --paginate --slurp\$	reviews.json
^api graphql .*reviewThreads	threads.json
^api repos/$REPO/commits/$C5\$	commit-$C5.json
^api repos/$REPO/commits/$C4\$	commit-$C4.json
^api repos/$REPO/commits/$C3\$	commit-$C3.json
ROUTES
run ready --pr 'octo#42' --reviewer octocat
check "replay of a synthetic octo#42 → ready on C3, approved at C4" 0 \
  "o.verdict === 'ready' && o.base === 'main' && o.target === '$C3' && o.head === '$C5' && o.checks.approval.commit === '$C4' && o.checks.changes_requested.by.length === 0"
unrouted && pass "the replay reads no commit older than the target" || fail "the replay reads no commit older than the target — $(cat "$CASE/fx/gh-unrouted.log")"

# --- merge ------------------------------------------------------------------
MERGED_SHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
ok_head; merge_put "{\"merged\":true,\"sha\":\"$MERGED_SHA\",\"message\":\"Pull Request successfully merged\"}"
merged_view "{\"mergeCommit\":{\"oid\":\"$D\"}}"
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "merge at the ready head → merged, merge commit from gh pr view" 0 "o.result === 'merged' && o.merge_commit_sha === '$D' && o.sha === '$A' && o.base === 'main'"

ok_head; pr OPEN "$A" false MERGEABLE CLEAN release/2.x
merge_put "{\"merged\":true,\"sha\":\"$MERGED_SHA\"}"; merged_view "{\"mergeCommit\":{\"oid\":\"$D\"}}"
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "merge reports the PR's base branch" 0 "o.result === 'merged' && o.base === 'release/2.x'"
put="$(calls | grep '"PUT"')"
grep -q "\"sha=$A\"" <<<"$put" && grep -q '"merge_method=squash"' <<<"$put" \
  && pass "the merge PUT carries the head SHA and the project's merge_method" || fail "the merge PUT carries the head SHA and merge_method — $(calls)"

ok_head; sed -i.bak 's/"merge_method":"squash"/"merge_method":"rebase"/' "$CASE/config.json"
merge_put "{\"merged\":true,\"sha\":\"$MERGED_SHA\"}"; merged_view "{\"mergeCommit\":{\"oid\":\"$D\"}}"
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
calls | grep '"PUT"' | grep -q '"merge_method=rebase"' && pass "merge_method follows the config" || fail "merge_method follows the config — $(calls)"

ok_head; merge_put "{\"merged\":true,\"sha\":\"$MERGED_SHA\"}"; merged_view EXIT:1
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "an unreadable follow-up view falls back to the PUT's merge sha" 0 "o.result === 'merged' && o.merge_commit_sha === '$MERGED_SHA'"

ok_head; merge_put '{"merged":true}'; merged_view EXIT:1
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "merged with no readable merge commit → exit 2" 2 "/merged, but/.test(o.error)"

ok_head; merge_put HTTP:409
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a 409 from the merge → refused, head moved" 0 "o.result === 'refused' && /head moved/.test(o.reason)"

ok_head; merge_put '{"merged":true}'
run merge --pr 'octo#42' --reviewer octocat --sha "$C"
check "a --sha that is not the head → refused" 0 "o.result === 'refused' && /head is $A/.test(o.reason)"
[ "$(writes)" = 0 ] && pass "no merge call when the SHA differs" || fail "no merge call when the SHA differs — $(calls)"

ok_head; reviews ""; merge_put '{"merged":true}'
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "merge when not ready → refused with the verdict" 0 "o.result === 'refused' && o.verdict === 'wait' && /has not approved/.test(o.reason) && o.base === 'main'"
[ "$(writes)" = 0 ] && pass "no merge call when not ready" || fail "no merge call when not ready — $(calls)"

ok_head; merge_put 'HTTPF:405:{"message":"Repository rule violations found"}'; mq yes
route "^pr merge 42 " '{}'
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a 405 on a base with a merge queue → queued, whatever the message says" 0 "o.result === 'queued' && o.merge_commit_sha === undefined"
calls | grep 'mergeQueue' | grep -q '"-f","branch=main"' && calls | grep 'mergeQueue' | grep -q '"-f","owner=octo-org"' \
  && pass "the merge-queue check asks about the PR's base branch" || fail "the merge-queue check asks about the PR's base branch — $(calls)"
calls | grep '"merge","42"' | grep -q "\"--auto\",\"--match-head-commit\",\"$A\",\"--squash\"" \
  && pass "the queue call pins the head and the merge method" || fail "the queue call pins the head and the merge method — $(calls)"

ok_head; merge_put 'HTTPF:405:{"message":"Changes must be made through the merge queue"}'; mq yes
route "^pr merge 42 " 'ERRF:1:GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)'
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a failed merge-queue enqueue → refused with gh's message" 0 "o.result === 'refused' && /merge queue/.test(o.reason) && /Auto merge is not allowed/.test(o.reason)"

ok_head; merge_put 'HTTPF:405:{"message":"Changes must be made through the merge queue"}'; mq yes
route "^pr merge 42 " RATE
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a rate-limited merge-queue enqueue → exit 2" 2 "/rate limit/.test(o.error)"

ok_head; merge_put 'HTTPF:405:{"message":"Required status check \"test\" is expected."}'; mq no
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "another 405 → refused with GitHub's message" 0 "o.result === 'refused' && /405/.test(o.reason) && /Required status check/.test(o.reason)"
calls | grep -q '"merge","42"' && fail "no enqueue for a 405 on a base without a merge queue" || pass "no enqueue for a 405 on a base without a merge queue"

ok_head; merge_put 'HTTPF:405:{"message":"Changes must be made through the merge queue"}'; mq no
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a 405 that names a merge queue on a base without one → refused, not guessed" 0 "o.result === 'refused' && /HTTP 405/.test(o.reason)"

ok_head; pr OPEN "$A" false MERGEABLE CLEAN release/2.x; merge_put 'HTTPF:405:{"message":"x"}'; mq yes; route "^pr merge 42 " '{}'
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "the merge-queue check follows a non-main base" 0 "o.result === 'queued' && o.base === 'release/2.x'"
calls | grep 'mergeQueue' | grep -q '"-f","branch=release/2.x"' && pass "the merge-queue check names release/2.x" || fail "the merge-queue check names release/2.x — $(calls)"

for bad in EXIT:1 RATE '{"errors":[{"message":"Field mergeQueue does not exist"}]}' '{"data":{"repository":null}}'; do
  ok_head; merge_put 'HTTPF:405:{"message":"Changes must be made through the merge queue"}'; mq "$bad"; route "^pr merge 42 " '{}'
  run merge --pr 'octo#42' --reviewer octocat --sha "$A"
  check "an unreadable merge-queue check ($bad) → exit 2, never queued or refused" 2 "typeof o.error === 'string' && !/non-JSON/.test(o.error) && o.result === undefined"
  calls | grep -q '"merge","42"' && fail "no enqueue when the merge-queue check fails ($bad)" || pass "no enqueue when the merge-queue check fails ($bad)"
done

ok_head; merge_put 'HTTPF:422:{"message":"Merge method squash is not allowed on this repository"}'
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a 422 → refused with GitHub's message" 0 "o.result === 'refused' && /not allowed/.test(o.reason)"

ok_head; merge_put HTTP:502
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a 5xx from the merge (outcome unknown) → exit 2" 2 "/failed/.test(o.error) && o.result === undefined"

ok_head; merge_put RATE
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a rate-limited merge → exit 2" 2 "/rate limit/.test(o.error) && o.result === undefined"

ok_head; merge_put '{"merged":false,"message":"Pull Request is not mergeable"}'
run merge --pr 'octo#42' --reviewer octocat --sha "$A"
check "a merge reply with merged false → refused" 0 "o.result === 'refused' && /not mergeable/.test(o.reason)"

ok_head; run merge --pr 'octo#42' --reviewer octocat --sha 'not-a-sha'
check "a malformed --sha → exit 2" 2 "/sha/.test(o.error)"

# --- rerequest --------------------------------------------------------------
RR="^api $P/requested_reviewers -X POST "
newcase; route "$RR" '{"number":42,"requested_reviewers":[{"login":"Copilot"},{"login":"octocat"}]}'
run rerequest --pr 'octo#42' --user octocat
check "rerequest returns every requested reviewer" 0 "o.reviewers.join() === 'Copilot,octocat' && o.pr === 'octo#42'"
[ "$(calls | wc -l | tr -d ' ')" = 1 ] && calls | grep -q '"-f","reviewers\[\]=octocat"' \
  && pass "rerequest makes one POST naming only --user, so other reviewers stay" || fail "rerequest makes one POST naming only --user — $(calls)"

newcase; route "$RR" 'HTTPF:422:{"message":"Reviews may only be requested from collaborators."}'
run rerequest --pr 'octo#42' --user stranger
check "a refused rerequest → exit 2" 2 "/failed/.test(o.error)"

newcase; route "$RR" '{"number":42}'
run rerequest --pr 'octo#42' --user octocat
check "a rerequest reply without requested_reviewers → exit 2" 2 "/no requested reviewers/.test(o.error)"

newcase; run rerequest --pr 'octo#42'
check "a missing --user → exit 2" 2 "/--user/.test(o.error)"

newcase; run bogus
check "an unknown command → usage error" 2 "/usage/.test(o.error)"

echo
if [ "$fails" -eq 0 ]; then echo "All herd-pr tests passed"; exit 0; fi
echo "$fails herd-pr test(s) failed"; exit 1
