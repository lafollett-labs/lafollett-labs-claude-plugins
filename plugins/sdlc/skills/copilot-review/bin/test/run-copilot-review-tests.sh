#!/usr/bin/env bash
# Tests for copilot-review.js against the shared stub gh and synthetic fixtures. Offline. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../copilot-review.js"
STUB="$(cd "$HERE/../../../../bin/test" && pwd)/stub-gh.sh"
FIX="$HERE/fixtures"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

for tool in node jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool not on PATH" >&2; exit 1; }
done

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc

total=0
fails=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); fails=$((fails + 1)); echo "FAIL: $1 — $2"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] expected [$3]"; fi; }

export GIT_CEILING_DIRECTORIES="$W" GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$W/cwd"
CWD="$W/cwd"

# stub <route>...: a fresh STUB_GH_DIR holding the fixtures and these routes. A route is "ERE|exit|files".
N=0
stub() {
  N=$((N + 1)); S="$W/s$N"
  mkdir -p "$S"; cp "$FIX"/* "$S/"; : > "$S/calls"
  local r; : > "$S/routes"
  for r in "$@"; do printf '%s\n' "$r" | awk -F'|' '{ print $1 "\t" $2 "\t" $3 }' >> "$S/routes"; done
}
# run <args>...: exit code on stdout; JSON in $W/out, stderr in $W/err.
run() { (cd "$CWD" && SDLC_GH="$STUB" STUB_GH_DIR="$S" node "$CLI" "$@") > "$W/out" 2> "$W/err"; echo $?; }
j() { jq -r "$1" "$W/out" 2>/dev/null; }
calls() { grep -c -- "$1" "$S/calls" || true; }

PRA='^pr view 7 |0|pr-view-a.json'
PRB='^pr view 7 |0|pr-view-b.json'
USER='^api user|0|user.json'
THREADS='reviewThreads\(first|0|threads-pages.jsonl'
POST='^api -X POST repos/\{owner\}/\{repo\}/pulls/7/copilot-code-review'

echo "=== copilot-review tests ==="

# --- request ---
stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-old.json' "$POST|0|requested.json"
check "request: no Copilot review at head → exit 0" "$(run request --pr 7)" 0
check "  status requested" "$(j .status)" requested
check "  head_sha is the PR head" "$(j .head_sha)" "$A"
check "  POSTs copilot-code-review once" "$(calls 'copilot-code-review')" 1
check "  no effort field by default" "$(calls 'review_effort')" 0

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-human.json' "$POST -f review_effort=balanced\$|0|requested.json"
check "request --effort balanced → exit 0" "$(run request --pr 7 --effort balanced)" 0
check "  sends review_effort=balanced" "$(calls '-f review_effort=balanced')" 1

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json' "$POST|0|requested.json"
check "request: Copilot already reviewed the head → exit 0" "$(run request --pr 7)" 0
check "  status already_reviewed" "$(j .status)" already_reviewed
check "  names the review" "$(j .review_id)" 103
check "  spends no quota (no POST)" "$(calls 'copilot-code-review')" 0

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json' "$POST|0|requested.json"
check "request --force re-requests at a reviewed head" "$(run request --pr 7 --force)" 0
check "  status requested" "$(j .status)" requested
check "  --force skips the reviews read" "$(calls '/reviews')" 0

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-human.json' "$POST|1|quota.stderr"
check "request: 422 NO_QUOTA_REMAINING → exit 1" "$(run request --pr 7)" 1
check "  status quota_exhausted" "$(j .status)" quota_exhausted
check "  message carries gh's line" "$(j '.message | test("NO_QUOTA_REMAINING")')" true

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-human.json' "$POST|1|quota-message.stderr"
check "request: 422 with a quota message → exit 1" "$(run request --pr 7)" 1
check "  status quota_exhausted" "$(j .status)" quota_exhausted

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-human.json' "$POST|1|unavailable.stderr"
check "request: another 422 is an error → exit 2" "$(run request --pr 7)" 2
check "  error names gh's reason" "$(j '.error | test("not enabled")')" true

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-human.json' "$POST|1|quota-token.json"
check "request: NO_QUOTA_REMAINING without a 422 → exit 1" "$(run request --pr 7)" 1
check "  status quota_exhausted" "$(j .status)" quota_exhausted

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-human.json' "$POST|1|rate-limit.stderr"
check "request: a quota word outside a 422 is an error → exit 2" "$(run request --pr 7)" 2

# --- wait ---
stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-old.json,reviews-a.json'
check "wait: review lands on the second poll → exit 0" "$(run wait --pr 7 --interval 0 --timeout 60)" 0
check "  status complete" "$(j .status)" complete
check "  review is Copilot's at the head" "$(j '.review.id')" 103
check "  review.commit_id is the head" "$(j '.review.commit_id')" "$A"
check "  polled twice" "$(calls '/reviews')" 2
check "  progress went to stderr" "$(grep -c 'waiting for Copilot on #7' "$W/err")" 1

stub '^api --paginate .*/pulls/7/reviews|0|reviews-old.json'
check "wait: no review at head by the timeout → exit 1" "$(run wait --pr 7 --head "$A" --interval 0 --timeout 0)" 1
check "  status timeout" "$(j .status)" timeout
check "  reports the sha Copilot last reviewed" "$(j .latest_reviewed_sha)" "$C"
check "  --head skips pr view" "$(calls '^pr view')" 0

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-paged.jsonl'
check "wait: reviews across two pages → exit 0" "$(run wait --pr 7 --interval 0 --timeout 0)" 0
check "  finds the review on page 1 of 2" "$(j '.review.id')" 103

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-split.jsonl'
check "wait: Copilot's review on page 2 of 2 → exit 0" "$(run wait --pr 7 --interval 0 --timeout 0)" 0
check "  finds it" "$(j '.review.id')" 103

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-human.json'
check "wait: a human review at head does not count" "$(run wait --pr 7 --interval 0 --timeout 0)" 1
check "  latest_reviewed_sha is null" "$(j .latest_reviewed_sha)" null

# --- threads ---
stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json' "$USER" "$THREADS"
check "threads → exit 0" "$(run threads --pr 7)" 0
check "  keeps only Copilot threads, across pages" "$(j '[.threads[].thread_id] | map(tostring) | join(",")')" "PRRT_t1,PRRT_t2,PRRT_t4,PRRT_t5"
check "  t1 is on the current head" "$(j '.threads[0].current_head')" true
check "  t1 suggestion extracted" "$(j '.threads[0].suggestion')" "  if (!timingSafeEqual(a, b)) return false;"
check "  t1 body has the suggestion stripped" "$(j '.threads[0].body')" "The password is compared with \`==\`; use a constant-time comparison."
check "  t1 comment_id" "$(j '.threads[0].comment_id')" 5001
check "  t2 is outdated, not on the head" "$(j '[.threads[1].outdated, .threads[1].current_head] | map(tostring) | join(",")')" "true,false"
check "  t2 line falls back to originalLine" "$(j '.threads[1].line')" 30
check "  t2 answered by me" "$(j '.threads[1].answered_by_me')" true
check "  t2 reply author" "$(j '.threads[1].replies[0].author')" octocat
check "  t4 resolved, [bot] login accepted" "$(j '.threads[2].resolved')" true
check "  t5 outdated at the head commit is not current" "$(j '.threads[3].current_head')" false
check "  review is the latest Copilot review" "$(j '.review.id')" 103
check "  reviewed_head" "$(j .reviewed_head)" true
check "  coverage partial 3 of 4" "$(j '[.coverage.reviewed, .coverage.total, .coverage.partial] | map(tostring) | join(",")')" "3,4,true"
check "  outside a checkout: on_pr false" "$(j '.local.on_pr')" false
check "  GraphQL paginated with {owner}/{repo}" "$(calls '^api graphql --paginate -F owner={owner} -F repo={repo} -F number=7 ')" 1

stub "$PRB" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json' "$USER" "$THREADS"
check "threads after a push → exit 0" "$(run threads --pr 7)" 0
check "  reviewed_head false" "$(j .reviewed_head)" false
check "  t1 no longer on the head" "$(j '.threads[0].current_head')" false

R="$W/repo"
git init -q -b feat/42-add-login "$R" && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
H="$(git -C "$R" rev-parse HEAD)"
stub '^pr view 7 |0|pr-view-live.json' '^api --paginate .*/pulls/7/reviews|0|reviews-a.json' "$USER" "$THREADS"
printf '{"number":7,"headRefOid":"%s","headRefName":"feat/42-add-login","baseRefName":"main","state":"OPEN"}\n' "$H" > "$S/pr-view-live.json"
CWD="$R"
check "threads in the PR's checkout → exit 0" "$(run threads --pr 7)" 0
check "  on_pr true" "$(j '.local.on_pr')" true
check "  local.branch" "$(j '.local.branch')" feat/42-add-login
CWD="$W/cwd"

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json' "$USER" 'reviewThreads\(first|0|threads-no-pr.json'
check "threads: PR unknown to GraphQL → exit 2" "$(run threads --pr 7)" 2

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json' "$USER" 'reviewThreads\(first|0|graphql-errors.json'
check "threads: GraphQL errors → exit 2" "$(run threads --pr 7)" 2
check "  error carries the GraphQL message" "$(j '.error | test("Could not resolve")')" true

# --- reply / resolve ---
printf 'Fixed in abc1234.\n' > "$W/body.md"
stub 'addPullRequestReviewThreadReply|0|reply-ok.json'
check "reply → exit 0" "$(run reply --thread PRRT_t1 --body-file "$W/body.md")" 0
check "  comment_id" "$(j .comment_id)" 9001
check "  url" "$(j .url)" "https://github.com/octo-org/octo-repo/pull/7#discussion_r9001"
check "  sends the thread id" "$(calls ' -f threadId=PRRT_t1 -f body=Fixed in abc1234\.$')" 1

: > "$W/empty.md"
stub 'addPullRequestReviewThreadReply|0|reply-ok.json'
check "reply: empty body file → exit 2" "$(run reply --thread PRRT_t1 --body-file "$W/empty.md")" 2
check "  no gh call" "$(calls 'graphql')" 0

stub 'addPullRequestReviewThreadReply|0|reply-ok.json'
check "reply: unsafe thread id → exit 2" "$(run reply --thread 'PRRT_t1;rm' --body-file "$W/body.md")" 2

stub 'addPullRequestReviewThreadReply|1|forbidden.stderr'
check "reply: gh fails → exit 2" "$(run reply --thread PRRT_t1 --body-file "$W/body.md")" 2
check "  error names the call, not the query" "$(j .error)" "gh api graphql addPullRequestReviewThreadReply failed: gh: Resource not accessible by integration (HTTP 403)"

stub 'resolveReviewThread|0|resolve-ok.json'
check "resolve → exit 0" "$(run resolve --thread PRRT_t1)" 0
check "  resolved" "$(j .resolved)" true

stub 'resolveReviewThread|0|graphql-errors.json'
check "resolve: GraphQL error → exit 2" "$(run resolve --thread PRRT_gone)" 2

# --- pushed ---
stub "$PRB" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json'
check "pushed: PR head is local HEAD, past Copilot's review → exit 0" "$(run pushed --pr 7 --head "$B")" 0
check "  pushed true, moved true" "$(j '[.pushed, .moved] | map(tostring) | join(",")')" "true,true"
check "  reviewed_sha" "$(j .reviewed_sha)" "$A"

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json'
check "pushed: the push did not land" "$(run pushed --pr 7 --head "$B")" 0
check "  pushed false, moved false" "$(j '[.pushed, .moved] | map(tostring) | join(",")')" "false,false"

stub "$PRB" '^api --paginate .*/pulls/7/reviews|0|reviews-a.json'
check "pushed: local HEAD is ahead of the PR head" "$(run pushed --pr 7 --head "$C")" 0
check "  pushed false, moved true" "$(j '[.pushed, .moved] | map(tostring) | join(",")')" "false,true"

stub "$PRB" '^api --paginate .*/pulls/7/reviews|0|reviews-b.json'
check "pushed: Copilot already reviewed the new head" "$(run pushed --pr 7 --head "$B")" 0
check "  pushed false, moved false" "$(j '[.pushed, .moved] | map(tostring) | join(",")')" "false,false"

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|reviews-human.json'
check "pushed: no Copilot review yet" "$(run pushed --pr 7 --head "$A")" 0
check "  pushed true, moved true, reviewed_sha null" "$(j '[.pushed, .moved, .reviewed_sha] | map(tostring) | join(",")')" "true,true,null"

stub '^pr view 7 |0|pr-view-live.json' '^api --paginate .*/pulls/7/reviews|0|reviews-a.json'
printf '{"number":7,"headRefOid":"%s","headRefName":"feat/42-add-login","baseRefName":"main","state":"OPEN"}\n' "$H" > "$S/pr-view-live.json"
CWD="$R"
check "pushed: local HEAD by default" "$(run pushed --pr 7)" 0
check "  head is the checkout's HEAD" "$(j .head)" "$H"
CWD="$W/cwd"

# --- usage and gh failures ---
stub "$PRA"
check "unknown command → exit 2" "$(run fetch --pr 7)" 2
check "--pr must be a positive integer" "$(run threads --pr 7x)" 2
check "--pr 0 is refused" "$(run threads --pr 0)" 2
check "--head must be a full sha" "$(run wait --pr 7 --head abc123)" 2
check "unknown option → exit 2" "$(run threads --pr 7 --issue 7)" 2
check "missing value → exit 2" "$(run threads --pr)" 2
check "--interval must be non-negative" "$(run wait --pr 7 --head "$A" --interval -1)" 2
check "usage errors call no gh" "$(calls '.')" 0

stub "$PRA" '^api --paginate .*/pulls/7/reviews|0|not-json.txt'
check "non-JSON from gh → exit 2" "$(run wait --pr 7 --timeout 0)" 2
check "  says so" "$(j .error)" "gh api pulls/reviews returned non-JSON"

printf '#!/usr/bin/env bash\nexec sleep 5\n' > "$W/slow-gh"; chmod +x "$W/slow-gh"
code="$( (cd "$CWD" && SDLC_GH="$W/slow-gh" SDLC_GH_TIMEOUT_MS=200 node "$CLI" threads --pr 7) > "$W/out" 2>/dev/null; echo $?)"
check "a hung gh is killed → exit 2" "$code" 2
check "  error says timed out" "$(j '.error | test("timed out after 200 ms")')" true

code="$( (cd "$CWD" && SDLC_GH="$W/no-such-gh" node "$CLI" threads --pr 7) > "$W/out" 2>/dev/null; echo $?)"
check "gh missing → exit 2" "$code" 2
check "  error says not runnable" "$(j '.error | test("gh not runnable")')" true

echo "$total checks, $fails failed"
[ "$fails" -eq 0 ]
