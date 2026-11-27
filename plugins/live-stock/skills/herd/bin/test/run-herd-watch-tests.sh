#!/usr/bin/env bash
# Fixture tests for herd-watch.js snapshot and wait — lane events, lane PR/checks/review-request/CI/agent diffs,
# the baseline file, degraded gh polls and the GitHub rate-limit backoff.
# herdr is stub-herdr.js and gh is stub-gh.js; HOME, PATH and the config path point into a temp dir.
# HERD_POLL_MS=50 and HERD_DEBOUNCE_MS=100 keep the suite to seconds. No network, no live herdr.
# No npm packages — bash + node only. Exit 0 = all cases pass, 1 = any fail.
# shellcheck disable=SC2015 # pass and fail always return 0, so A && pass || fail is an if/else
# shellcheck disable=SC2016 # the node -e scripts are single-quoted on purpose: ${} in them is JavaScript
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../herd-watch.js"
NODE="$(command -v node)"
GIT="$(command -v git)"
[ -n "$NODE" ] || { echo "FAIL: node not on PATH — cannot run herd-watch tests" >&2; exit 1; }
[ -n "$GIT" ] || { echo "FAIL: git not on PATH — cannot run herd-watch tests" >&2; exit 1; }
[ -f "$CLI" ] || { echo "FAIL: herd-watch.js not found at $CLI" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# git sees only this config, never the user's or the system's
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Test Lane\n\temail = lane@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

REPO="octo-org/octo-repo"
BR="feat/42-widget"
WT=".sdlc-worktrees/checkout/42"   # lane-a's worktree: herd-lane.js names it after the issue's key slug
SEARCH_RE="^search prs --review-requested=@me --state open "
PRLIST_RE="^pr list -R $REPO --head $BR --state all "
COMMIT_RE="^api repos/$REPO/commits/main$"
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
PIN=abcdef0123456789abcdef0123456789abcdef01

# newcase — fresh fixtures dir with stub gh and herdr, a valid config, no review requests, no agents
newcase() {
  CASE="$TMP/case$RANDOM$RANDOM"
  mkdir -p "$CASE/bin" "$CASE/fx" "$CASE/home" "$CASE/checkout"
  ln -s "$HERE/stub-gh.js" "$CASE/bin/gh"
  ln -s "$HERE/stub-herdr.js" "$CASE/bin/herdr"
  ln -s "$NODE" "$CASE/bin/node"
  ln -s "$GIT" "$CASE/bin/git"
  cp "$HERE/fixtures/herd-watch/"* "$CASE/fx/"
  LANES="lane-a"
  cat > "$CASE/config.json" <<JSON
{"projects":{"octo":{"repo":"$REPO","checkout":"$CASE/checkout","main_push":"pr-only","merge_method":"squash"}},
 "review_request_authors":["hubot"],
 "defaults":{"max_lanes":3,"lane_model":"opus","lane_effort":"high"}}
JSON
  : > "$CASE/fx/routes"; : > "$CASE/fx/herdr-routes"
  groute "$SEARCH_RE" empty-list.json
  hroute "agent list" agents-empty.json
  CI_NONE_MS=""
}

hexkey() { "$NODE" -e 'process.stdout.write(Buffer.from(process.argv[1]).toString("hex").slice(0, 120))' "$1"; }
# groute <ERE> <reply>... — set a stub gh route in place (stub-gh counts replies per line) and restart its sequence
groute() {
  local key="$1"; shift
  local line idx
  line="$(printf '%s\t%s' "$key" "$(IFS=,; echo "$*")")"
  awk -F'\t' -v k="$key" -v l="$line" '$1 == k { print l; f = 1; next } { print } END { if (!f) print l }' \
    "$CASE/fx/routes" > "$CASE/fx/routes.new"; mv "$CASE/fx/routes.new" "$CASE/fx/routes"
  idx="$(awk -F'\t' -v k="$key" '$1 == k { print NR - 1; exit }' "$CASE/fx/routes")"
  rm -f "$CASE/fx/.gh-count-$idx"
}
# hroute <key> <reply>... — replace a stub herdr route and restart its reply sequence
hroute() {
  local key="$1"; shift
  awk -F'\t' -v k="$key" '$1 != k' "$CASE/fx/herdr-routes" > "$CASE/fx/herdr-routes.new"; mv "$CASE/fx/herdr-routes.new" "$CASE/fx/herdr-routes"
  printf '%s\t%s\n' "$key" "$(IFS=,; echo "$*")" >> "$CASE/fx/herdr-routes"
  rm -f "$CASE/fx/.herdr-count-$(hexkey "$key")"
}
# gh_calls_since <n> — the gh calls logged after the first n
gh_calls_since() { tail -n +"$(($1 + 1))" "$CASE/fx/gh-calls.log" 2>/dev/null; }
gh_count() { if [ -f "$CASE/fx/gh-calls.log" ]; then wc -l < "$CASE/fx/gh-calls.log"; else echo 0; fi; }

# lane <name> <status:seq[:state_change_seq]>... — agent get replies in order (seq is a number or null); lane_missing <name> — agent_not_found
lane() {
  local name="$1"; shift
  local files=() i=0 spec st sq scs
  for spec in "$@"; do
    IFS=: read -r st sq scs <<<"$spec"
    printf '{"id":"cli:agent:get","result":{"agent":{"pane_id":"w1:%s","name":"%s","agent_status":"%s","completion_seq":%s,"state_change_seq":%s,"cwd":"/work/%s","workspace_id":"w1"}}}\n' \
      "$name" "$name" "$st" "$sq" "${scs:-$([ "$sq" = null ] && echo 1 || echo "$sq")}" "$name" > "$CASE/fx/get-$name-$i.json"
    files+=("get-$name-$i.json"); i=$((i + 1))
  done
  hroute "agent get $name" "${files[@]}"
}
lane_missing() { hroute "agent get $1" "ERR:agent-not-found.json"; }
# pane_text <lane> <text> — what `agent read` shows for the lane
pane_text() { printf '%s\n' "$2" > "$CASE/fx/read-$1.txt"; hroute "agent read $1" "read-$1.txt"; }
# agents <pane|name|cwd>... — the agent list
agents() {
  local items="" spec p n c
  for spec in "$@"; do
    IFS="|" read -r p n c <<<"$spec"
    items="$items${items:+,}{\"pane_id\":\"$p\",\"name\":\"$n\",\"agent_status\":\"idle\",\"cwd\":\"$c\",\"workspace_id\":\"w1\"}"
  done
  printf '{"id":"cli:agent:list","result":{"agents":[%s]}}\n' "$items" > "$CASE/fx/agents.json"
  hroute "agent list" agents.json
}
# git_wt <dir> <branch> — a git repo at $CASE/<dir> with one commit on <branch>
git_wt() {
  mkdir -p "$CASE/$1"
  "$GIT" -C "$CASE/$1" init -q -b "$2" && "$GIT" -C "$CASE/$1" commit -q --allow-empty -m init \
    || { echo "FAIL: git setup in $CASE/$1" >&2; exit 1; }
}
# lane_wt — lane-a's pane in its worktree $CASE/$WT, a git repo on $BR, with no PR yet
lane_wt() {
  git_wt "$WT" "$BR"
  agents "w1:p1|lane-a|$CASE/$WT"
  groute "$PRLIST_RE" empty-list.json
}

# prs <number|state|sha|status|comments|threads|reviews|checks>... — the PRs gh lists for lane-a's branch, and for each:
#   status   mergeStateStatus (UNKNOWN also makes mergeable UNKNOWN)
#   comments issue comments; threads r<n>/u<n> joined by + (a resolved/unresolved thread with n comments)
#   reviews  login:STATE[:body] joined by + (in submission order)
#   checks   passed | failed | pending | incomplete | none (gh's "no checks reported") | exit8 (pending, JSON on exit 8) | odd (unknown bucket)
prs() {
  "$NODE" -e '
    const fs = require("fs"); const [dir, ...specs] = process.argv.slice(1);
    const w = (f, o) => fs.writeFileSync(`${dir}/${f}`, JSON.stringify(o));
    const ck = { passed: ["pass", "skipping"], failed: ["pass", "fail"], pending: ["pass", "pending"], incomplete: ["pass", "cancel"],
      exit8: ["pass", "pending"], odd: ["weird"] };
    w("prlist.json", specs.map((s) => { const [n, state, sha] = s.split("|");
      return { number: +n, state, headRefOid: sha, url: `https://github.com/octo-org/octo-repo/pull/${n}` }; }));
    for (const s of specs) {
      const [n, state, sha, status, comments, threads, reviews, checks] = s.split("|");
      w(`view-${n}.json`, { number: +n, state, headRefOid: sha, mergeable: status === "UNKNOWN" ? "UNKNOWN" : "MERGEABLE", mergeStateStatus: status });
      w(`reviews-${n}.json`, [(reviews || "").split("+").filter(Boolean).map((r, i) => { const [login, st, body] = r.split(":");
        return { user: { login }, state: st, body: body || "", commit_id: sha, submitted_at: `2026-01-01T00:0${i}:00Z` }; })]);
      const t = (threads || "").split("+").filter(Boolean).map((x) => ({ isResolved: x[0] === "r", comments: { totalCount: +x.slice(1) } }));
      w(`gql-${n}.json`, { data: { repository: { pullRequest: { comments: { totalCount: +comments || 0 }, reviewThreads: { totalCount: t.length, nodes: t } } } } });
      w(`checks-${n}.json`, (ck[checks] || []).map((b, i) => ({ name: `job${i}`, state: b.toUpperCase(), bucket: b })));
    }' "$CASE/fx" "$@"
  groute "$PRLIST_RE" prlist.json
  local spec n checks
  for spec in "$@"; do
    IFS='|' read -r n _ _ _ _ _ _ checks <<<"$spec"
    groute "^pr view $n -R $REPO " "view-$n.json"
    groute "^api repos/$REPO/pulls/$n/reviews " "reviews-$n.json"
    groute "^api graphql .* -F number=$n$" "gql-$n.json"
    case "$checks" in
      none) groute "^pr checks $n -R $REPO " "ERRF:1:no-checks.txt" ;;
      exit8) groute "^pr checks $n -R $REPO " "OUTF:8:checks-$n.json" ;;
      *) groute "^pr checks $n -R $REPO " "checks-$n.json" ;;
    esac
  done
}
# review_requests <owner/name#n|author>... — the open PRs requesting the user's review
review_requests() {
  "$NODE" -e '
    const l = process.argv.slice(1).map((s) => { const [ref, author] = s.split("|"); const [repo, n] = ref.split("#");
      return { number: +n, repository: { name: repo.split("/")[1], nameWithOwner: repo }, author: { login: author },
        url: `https://github.com/${repo}/pull/${n}`, state: "open", updatedAt: "2026-01-01T00:00:00Z" }; });
    process.stdout.write(JSON.stringify(l))' "$@" > "$CASE/fx/rr.json"
  groute "$SEARCH_RE" rr.json
}
# ci_head <sha>... — what main resolves to, one reply per poll
ci_head() {
  local files=() i=0 sha
  for sha in "$@"; do printf '{"sha":"%s","files":[]}' "$sha" > "$CASE/fx/commit-$i.json"; files+=("commit-$i.json"); i=$((i + 1)); done
  groute "$COMMIT_RE" "${files[@]}"
}
# ci_runs <sha> <runs>... — the workflow runs of a commit, one reply per poll; runs = status:conclusion joined by +, or - for none
ci_runs() {
  local sha="$1"; shift
  local files=() i=0 spec
  for spec in "$@"; do
    "$NODE" -e 'process.stdout.write(JSON.stringify((process.argv[1] === "-" ? [] : process.argv[1].split("+")).map((r, i) => {
      const [status, conclusion] = r.split(":"); return { databaseId: 100 + i, status, conclusion: conclusion || "", workflowName: `wf${i}`,
        event: "push", url: `https://github.com/octo-org/octo-repo/actions/runs/${100 + i}` }; })))' "$spec" > "$CASE/fx/runs-${sha:0:4}-$i.json"
    files+=("runs-${sha:0:4}-$i.json"); i=$((i + 1))
  done
  groute "^run list -R $REPO --commit $sha " "${files[@]}"
}

# run [args...] — sets $out and $code
run() {
  out="$(cd "$CASE" && env -i HOME="$CASE/home" PATH="$CASE/bin" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 HERD_FIXTURES="$CASE/fx" HERD_CONFIG="$CASE/config.json" \
    HERD_POLL_MS=50 HERD_DEBOUNCE_MS=100 HERD_GH_TIMEOUT_MS=2000 ${CI_NONE_MS:+HERD_CI_NONE_MS=$CI_NONE_MS} \
    "$NODE" "$CLI" "$@" 2>/dev/null)"
  code=$?
}
# base — take the baseline (a wait that returns at once); wait_run [extra args] — a short wait against it
base() { run wait --lanes "$LANES" --run-dir "$CASE/run" --max 0 "$@"; }
wait_run() { run wait --lanes "$LANES" --run-dir "$CASE/run" --max 0.5 "$@"; }
# A case whose event needs a second poll: wait returns as soon as it fires, so the long ceiling costs nothing on a pass.
wait_event() { run wait --lanes "$LANES" --run-dir "$CASE/run" --max 5 "$@"; }
# check <name> <expected-exit> <js-boolean-expression over `o`>
check() {
  local name="$1" want="$2" expr="$3"
  if [ "$code" -eq "$want" ] && "$NODE" -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$out" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — exit $code, got: $out"
  fi
}
# baseline_ok <name> <js-boolean-expression over `s`, the saved baseline>
baseline_ok() {
  "$NODE" -e "const s = require(process.argv[1]); process.exit(($2) ? 0 : 1)" "$CASE/run/watch-baseline.json" 2>/dev/null \
    && pass "$1" || fail "$1 — $(cat "$CASE/run/watch-baseline.json" 2>/dev/null)"
}
# baseline_set <js statement over `s`> — edit the saved baseline
baseline_set() {
  "$NODE" -e "const s = require(process.argv[1]); $1; require('fs').writeFileSync(process.argv[1], JSON.stringify(s))" "$CASE/run/watch-baseline.json"
}
HB="o.events.length === 1 && o.events[0].type === 'heartbeat'"

# --- usage ------------------------------------------------------------------
newcase
run
check "no subcommand is a usage error" 2 "typeof o.error === 'string'"

run bogus --lanes lane-a
check "unknown subcommand is a usage error" 2 "/bogus|usage/i.test(o.error)"

run snapshot
check "snapshot without --lanes is a usage error" 2 "/--lanes/.test(o.error)"

printf '{"projects":{"octo":{"id":42,"path":"g/r","checkout":"%s","main_push":"mr-only"}},"review_request_authors":[]}' "$CASE/checkout" > "$CASE/config.json"
run wait --lanes lane-a --run-dir "$CASE/run" --max 0
check "an old-format config (id, path, no merge_method) is refused as invalid" 2 "/config invalid/.test(o.error) && /repo/.test(o.error)"

# --- snapshot: lanes --------------------------------------------------------
newcase
lane lane-a working:null
lane lane-b idle:7
lane_missing lane-c
run snapshot --lanes lane-a,lane-b,lane-c
check "snapshot reports each lane, a missing one as gone" 0 \
  "o.lanes['lane-a'].status === 'working' && o.lanes['lane-a'].completion_seq === null && o.lanes['lane-a'].pane_id === 'w1:lane-a' &&
   o.lanes['lane-b'].status === 'idle' && o.lanes['lane-b'].completion_seq === 7 && o.lanes['lane-b'].parked === false &&
   o.lanes['lane-c'].status === 'gone' && Array.isArray(o.degraded) && o.degraded.length === 0 && o.prs.length === 0"

newcase
lane lane-a done:9
pane_text lane-a "build running
  ⏵ 2 shells still running"
run snapshot --lanes lane-a
check "snapshot marks a done lane parked on its own background shells" 0 "o.lanes['lane-a'].parked === true"

newcase
lane lane-a done:9
pane_text lane-a "all done, waiting for you"
run snapshot --lanes lane-a
check "snapshot leaves a plainly finished lane unparked" 0 "o.lanes['lane-a'].parked === false"

# --- snapshot: agents, PRs, review requests ---------------------------------
newcase
lane lane-a working:null
agents "w1:p2|lane-b|/work/b" "w1:p1|lane-a|/work/a"
run snapshot --lanes lane-a
check "snapshot lists agents sorted by pane id" 0 \
  "o.agents.length === 2 && o.agents[0].pane_id === 'w1:p1' && o.agents[0].name === 'lane-a' && o.agents[0].cwd === '/work/a'"

newcase
lane lane-a working:null; lane_wt
prs "9|OPEN|bbbb0009|CLEAN|2|r1|hubot:APPROVED+mona:APPROVED|passed" "3|CLOSED|aaaa0003|BLOCKED|0||hubot:APPROVED|failed"
run snapshot --lanes lane-a
check "snapshot lists the lane's PRs by number: an open one fully read, a closed one from gh pr list only" 0 \
  "o.prs.length === 2 && o.prs[0].number === 3 && o.prs[0].state === 'CLOSED' && o.prs[0].status === null && o.prs[0].checks === null &&
   o.prs[0].approved_by.length === 0 && o.prs[0].lane === 'lane-a' && o.prs[0].branch === '$BR' &&
   o.prs[1].project === 'octo' && o.prs[1].number === 9 && o.prs[1].state === 'OPEN' && o.prs[1].sha === 'bbbb0009' &&
   o.prs[1].status === 'CLEAN' && o.prs[1].comments === 3 && o.prs[1].resolved === true &&
   o.prs[1].approved_by.join() === 'hubot,mona' && o.prs[1].checks.state === 'passed' && /pull\/9$/.test(o.prs[1].url) &&
   o.degraded.length === 0 && !('checks_fired' in o.prs[1])"
grep -q '"view","3"' "$CASE/fx/gh-calls.log" && fail "a closed PR is not read past gh pr list" || pass "a closed PR is not read past gh pr list"
grep -q "\"--head\",\"$BR\",\"--state\",\"all\"" "$CASE/fx/gh-calls.log" && pass "the lane's PRs are listed by its worktree branch, all states" \
  || fail "the lane's PRs are listed by its worktree branch — $(cat "$CASE/fx/gh-calls.log")"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|UNKNOWN|0|u2+r1|monalisa:COMMENTED:why this?+hubot:APPROVED|pending"
run snapshot --lanes lane-a
check "UNKNOWN mergeability reads pending; comments add thread comments and reviews with a body; an open thread is unresolved" 0 \
  "o.prs[0].status === 'pending' && o.prs[0].comments === 4 && o.prs[0].resolved === false && o.prs[0].checks.state === 'pending'"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|BLOCKED|0||hubot:APPROVED+mona:APPROVED+hubot:CHANGES_REQUESTED+mona:COMMENTED+lisa:APPROVED+lisa:DISMISSED|failed"
run snapshot --lanes lane-a
check "approved_by is each user's latest decisive review: changes requested and dismissed drop out, a comment does not" 0 \
  "o.prs[0].approved_by.join() === 'mona' && o.prs[0].checks.state === 'failed'"

for c in "incomplete:incomplete" "none:none" "exit8:pending"; do
  newcase
  lane lane-a working:null; lane_wt
  prs "5|OPEN|aaaa0005|CLEAN|0|||${c%%:*}"
  run snapshot --lanes lane-a
  check "checks ${c%%:*} classify as ${c#*:}" 0 "o.prs[0].checks.state === '${c#*:}' && o.degraded.length === 0"
done

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0|||odd"
run snapshot --lanes lane-a
check "an unknown check bucket degrades the lane's PRs instead of guessing" 0 \
  "o.prs.length === 0 && o.degraded.some((d) => /lane-a/.test(d) && /bucket/.test(d))"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0|||passed"
groute "^pr checks 5 -R $REPO " "EXIT:1"
run snapshot --lanes lane-a
check "a gh pr checks failure that is not 'no checks' degrades instead of reading none" 0 \
  "o.prs.length === 0 && o.degraded.some((d) => /lane-a/.test(d))"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0|r1|"
"$NODE" -e 'const f = process.argv[1]; const o = require(f); o.data.repository.pullRequest.reviewThreads.totalCount = 101; require("fs").writeFileSync(f, JSON.stringify(o))' "$CASE/fx/gql-5.json"
run snapshot --lanes lane-a
check "more review threads than one page degrades instead of reading resolved" 0 \
  "o.prs.length === 0 && o.degraded.some((d) => /review threads/.test(d))"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0||"
groute "^api graphql .* -F number=5$" "graphql-error.json"
run snapshot --lanes lane-a
check "a GraphQL error degrades the lane's PRs" 0 "o.prs.length === 0 && o.degraded.some((d) => /GraphQL/.test(d))"

newcase
lane lane-a working:null
agents "w1:p1|lane-a|$CASE/elsewhere/42"
run snapshot --lanes lane-a
check "a lane whose cwd is not a worktree of a configured project is degraded, no gh call" 0 \
  "o.prs.length === 0 && o.degraded.some((d) => /lane-a/.test(d) && /configured project/.test(d))"
grep -q '"pr"' "$CASE/fx/gh-calls.log" && fail "no gh pr call for a lane outside the projects" || pass "no gh pr call for a lane outside the projects"

newcase
lane lane-a working:null
git_wt "$WT" "$BR"; "$GIT" -C "$CASE/$WT" checkout -q --detach || fail "detach the worktree's HEAD"
agents "w1:p1|lane-a|$CASE/$WT"
run snapshot --lanes lane-a
check "a lane worktree on a detached HEAD is degraded" 0 "o.prs.length === 0 && o.degraded.some((d) => /detached HEAD/.test(d))"
grep -q '"pr"' "$CASE/fx/gh-calls.log" 2>/dev/null && fail "no gh pr list for a detached HEAD" || pass "no gh pr list for a detached HEAD"

newcase
lane lane-a working:null
mkdir -p "$CASE/$WT"; "$GIT" -C "$CASE/$WT" init -q -b "$BR" || fail "init the unborn worktree"
agents "w1:p1|lane-a|$CASE/$WT"
run snapshot --lanes lane-a
check "a lane worktree on an unborn branch is degraded like a detached HEAD" 0 "o.prs.length === 0 && o.degraded.some((d) => /no commit at HEAD/.test(d))"
grep -q '"pr"' "$CASE/fx/gh-calls.log" 2>/dev/null && fail "no gh pr list for an unborn branch" || pass "no gh pr list for an unborn branch"

newcase
lane lane-a working:null
review_requests "octo-org/octo-repo#7|hubot" "other-org/tool#8|monalisa"
run snapshot --lanes lane-a
check "snapshot keeps only review requests from allowlisted authors" 0 \
  "o.review_requests.length === 1 && o.review_requests[0].ref === 'octo-org/octo-repo#7' && o.review_requests[0].author === 'hubot' &&
   o.review_requests[0].state === 'open' && /pull\/7$/.test(o.review_requests[0].url)"

newcase
lane lane-a working:null; lane_wt
groute "$PRLIST_RE" "EXIT:1"
run snapshot --lanes lane-a
check "snapshot survives a gh failure and names the lane in degraded" 0 \
  "o.prs.length === 0 && o.degraded.length === 1 && /prs lane-a/.test(o.degraded[0])"

newcase
lane lane-a working:null
sed -i.bak 's/"hubot"/"HuBot"/' "$CASE/config.json"
review_requests "octo-org/octo-repo#7|hubot"
run snapshot --lanes lane-a
check "the review-request allowlist ignores login case" 0 "o.review_requests.length === 1 && o.review_requests[0].author === 'hubot'"

# --- wait: usage, run-dir, baseline, heartbeat -----------------------------
newcase
lane lane-a working:null
run wait --lanes lane-a --run-dir "$CASE/run"
check "wait without --max is a usage error" 2 "/--max/.test(o.error)"

run wait --lanes lane-a --max 1
check "wait without --run-dir is a usage error" 2 "/--run-dir/.test(o.error)"

run wait --lanes lane-a --run-dir "$CASE/run" --max 1 --bogus x
check "wait with an unknown option is a usage error" 2 "/bogus/.test(o.error)"

run wait --lanes lane-a --run-dir "$CASE/run" --max 1 --pipelines octo:main
check "the old --pipelines option is gone" 2 "/pipelines/.test(o.error)"

newcase
lane lane-a working:null
run wait --lanes lane-a --run-dir "$CASE/run/nested" --max 0.3
check "a quiet wait ends in a heartbeat at --max" 0 \
  "o.events.length === 1 && o.events[0].type === 'heartbeat' && o.events[0].quiet_min === 0 && o.waited_s >= 0.3 && Array.isArray(o.degraded)"
if [ -f "$CASE/run/nested/watch-baseline.json" ]; then pass "the first wait creates the run-dir and its baseline"; else fail "the first wait creates the run-dir and its baseline"; fi

# --- wait: lane events -----------------------------------------------------
newcase
lane lane-a idle:5; base
lane lane-a idle:8
wait_run
check "an advanced completion_seq is a lane_settled event" 0 \
  "o.events.length === 1 && o.events[0].type === 'lane_settled' && o.events[0].lane === 'lane-a' &&
   o.events[0].status === 'idle' && o.events[0].completion_seq === 8"
wait_run
check "a lane_settled event is not repeated once the baseline is saved" 0 "$HB"

newcase
lane lane-a idle:5; base
wait_run
check "an unchanged completion_seq raises nothing" 0 "$HB"

newcase
lane lane-a idle:5; base
lane lane-a done:9
pane_text lane-a "waiting
  · 2 shells still running"
wait_run
check "a lane parked on its own background shells is skipped" 0 "$HB"

newcase
lane lane-a working:null; base
lane_missing lane-a
wait_run
check "a missing agent is a lane_gone event" 0 "o.events.length === 1 && o.events[0].type === 'lane_gone' && o.events[0].lane === 'lane-a'"
wait_run
check "a lane that stays gone fires lane_gone once; the next wait is a heartbeat" 0 "$HB"
lane lane-a idle:12
wait_run
lane_missing lane-a
wait_run
check "a lane that comes back and goes again fires lane_gone again" 0 "o.events.some((e) => e.type === 'lane_gone' && e.lane === 'lane-a')"

newcase
lane lane-a idle:3; base
lane lane-b idle:7
LANES="lane-a,lane-b"
wait_run
check "a lane added after the baseline was written reports its first settle" 0 "o.events.length === 1 && o.events[0].type === 'lane_settled' && o.events[0].lane === 'lane-b' && o.events[0].completion_seq === 7"

newcase
lane lane-a working:null; base
lane lane-a blocked:null working:null
wait_run
check "a blocked lane that reads working after the debounce raises nothing" 0 "$HB"

newcase
lane lane-a working:null; base
lane lane-a blocked:null
wait_run
check "a lane still blocked after the debounce is a lane_blocked event" 0 \
  "o.events.length === 1 && o.events[0].type === 'lane_blocked' && o.events[0].lane === 'lane-a'"
if [ "$(grep -c '"agent","get","lane-a"' "$CASE/fx/herdr-calls.log")" -ge 4 ]; then pass "the blocked lane was re-read for the debounce"; else fail "the blocked lane was re-read for the debounce"; fi

newcase
lane lane-a working:null; base
lane lane-a blocked:null:50
wait_run
check "a lane blocked at a new state_change_seq fires lane_blocked" 0 "o.events.length === 1 && o.events[0].type === 'lane_blocked'"
wait_run
check "the same blocked state_change_seq does not fire lane_blocked again" 0 "$HB"
lane lane-a idle:null:55 blocked:null:60
wait_event
check "a lane that leaves blocked and blocks again (new state_change_seq) fires again" 0 \
  "o.events.length === 1 && o.events[0].type === 'lane_blocked'"

newcase
lane lane-a working:null; base
lane lane-a working:null idle:null
wait_event
check "without completion_seq, working then not working is a lane_settled event" 0 \
  "o.events.length === 1 && o.events[0].type === 'lane_settled' && o.events[0].status === 'idle' && o.events[0].completion_seq === null"

newcase
lane lane-a idle:null; base
wait_run
check "without completion_seq, a lane never seen working raises nothing" 0 "$HB"

# --- wait: review rounds from a lane's findings ledger ------------------------
# ledger <worktree> <slug> <round>... — a findings ledger with these rounds in $CASE/<worktree>/docs/code-reviews
ledger() {
  local wt="$1" key="$2"; shift 2
  mkdir -p "$CASE/$wt/docs/code-reviews"
  "$NODE" -e 'process.stdout.write(JSON.stringify({ schema_version: 1, target: "b", counters: {},
    rounds: process.argv.slice(1).map((r) => ({ round: +r, clean: false, findings: [] })) }))' "$@" \
    > "$CASE/$wt/docs/code-reviews/$key-findings-ledger.json"
}

newcase
lane lane-a working:null; lane_wt; ledger "$WT" 42 1; base
ledger "$WT" 42 1 2
wait_run
check "a round added to a lane's findings ledger is a review_round event" 0 \
  "o.events.length === 1 && o.events[0].type === 'review_round' && o.events[0].lane === 'lane-a' && o.events[0].round === 2 &&
   o.events[0].ledger.endsWith('docs/code-reviews/42-findings-ledger.json') && o.degraded.length === 0"
wait_run
check "a review round is reported once" 0 "$HB"

newcase
lane lane-a working:null; lane_wt; ledger "$WT" 42 1 2; base
wait_run
check "rounds already in the ledger at the baseline raise nothing" 0 "$HB"

newcase
lane lane-a working:null; lane_wt; base
ledger "$WT" 42 1
wait_run
check "a lane's first review round is a review_round event" 0 \
  "o.events.length === 1 && o.events[0].type === 'review_round' && o.events[0].round === 1"

newcase
lane lane-a working:null
mkdir -p "$CASE/.sdlc-worktrees/checkout/LT-02"
agents "w1:p1|lane-a|$CASE/.sdlc-worktrees/checkout/LT-02"; base
ledger .sdlc-worktrees/checkout/LT-02 LT-02 1
wait_run
check "a story-code lane worktree (LT-02) reads its own ledger" 0 \
  "o.events.some((e) => e.type === 'review_round' && e.round === 1 && e.ledger.endsWith('/LT-02-findings-ledger.json'))"

newcase
lane lane-a working:null; lane_wt
agents "w1:p1|lane-a|$CASE/$WT" "w1:p2|other|$CASE/.sdlc-worktrees/checkout/43"; base
ledger .sdlc-worktrees/checkout/43 43 1
wait_run
check "a round in a pane that is not a watched lane raises nothing" 0 "$HB"

newcase
lane lane-a working:null; lane_wt; base
mkdir -p "$CASE/$WT/docs/code-reviews"; printf '{"rounds":[{"round":' > "$CASE/$WT/docs/code-reviews/42-findings-ledger.json"
wait_run
check "an unreadable ledger degrades the wait instead of failing it" 0 \
  "o.events[0].type === 'heartbeat' && o.degraded.some((d) => /lane-a/.test(d) && /ledger/.test(d))"

newcase
lane lane-a working:null; lane_wt; ledger "$WT" 7 $(seq 1 22); base
ledger "$WT" 42 1
wait_run
check "a merged issue's ledger with more rounds does not mask the lane's own round" 0 \
  "o.events.length === 1 && o.events[0].type === 'review_round' && o.events[0].round === 1 && o.events[0].ledger.endsWith('/42-findings-ledger.json')"
ledger "$WT" 9 1 2 3
wait_run
check "a merged issue's ledger arriving after the baseline (merge main) raises nothing" 0 "$HB"

newcase
lane lane-a working:null; base
lane_wt; ledger "$WT" 7 $(seq 1 22)
wait_run
check "a lane that joins after the baseline raises nothing for a merged issue's ledger" 0 \
  "!o.events.some((e) => e.type === 'review_round')"

newcase
lane lane-a working:null
agents "w1:p1|lane-a|$CASE/elsewhere"; base
wait_run
check "a lane whose cwd is not a lane worktree degrades the wait" 0 \
  "o.events[0].type === 'heartbeat' && o.degraded.some((d) => /lane-a/.test(d) && /worktree/.test(d))"

newcase
lane lane-a working:null; lane_wt; base
mkdir -p "$CASE/$WT/docs/code-reviews"; printf '{"rounds":{}}' > "$CASE/$WT/docs/code-reviews/42-findings-ledger.json"
wait_run
check "a ledger whose rounds is not a list degrades the wait" 0 \
  "o.events[0].type === 'heartbeat' && o.degraded.some((d) => /ledger/.test(d))"

# --- wait: agents, PRs, review requests ---------------------------------------
newcase
lane lane-a working:null
agents "w1:p1|lane-a|/work/a"; base
agents "w1:p1|lane-a|/work/a" "w1:p2|lane-b|/work/b"
wait_run
check "a pane id not in the baseline is an agent_new event" 0 \
  "o.events.length === 1 && o.events[0].type === 'agent_new' && o.events[0].pane_id === 'w1:p2' &&
   o.events[0].name === 'lane-b' && o.events[0].cwd === '/work/b'"

newcase
lane lane-a working:null; lane_wt; base
prs "5|OPEN|aaaa0005|BLOCKED|0||"
wait_run
check "an open PR not in the baseline is a pr_opened event" 0 \
  "o.events.length === 1 && o.events[0].type === 'pr_opened' && o.events[0].project === 'octo' && o.events[0].number === 5 &&
   o.events[0].branch === '$BR' && o.events[0].lane === 'lane-a'"
wait_run
check "pr_opened is raised once" 0 "$HB"

newcase
lane lane-a working:null; lane_wt; base
prs "4|CLOSED|aaaa0004|BLOCKED|0||"
wait_run
check "a closed PR first seen on the branch is recorded without an event" 0 "$HB"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|UNKNOWN|0||"; base
prs "5|OPEN|aaaa0005|UNKNOWN|0||"
"$NODE" -e 'const f = process.argv[1]; const o = require(f); o.mergeStateStatus = "BLOCKED"; require("fs").writeFileSync(f, JSON.stringify(o))' "$CASE/fx/view-5.json"
wait_run
check "UNKNOWN mergeability stays pending whatever mergeStateStatus says, so it raises nothing" 0 "$HB"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|UNKNOWN|0||"; base
prs "5|OPEN|aaaa0005|BEHIND|0||"
wait_run
check "a real merge-state change is a pr_change status event" 0 \
  "o.events.length === 1 && o.events[0].type === 'pr_change' && o.events[0].number === 5 && o.events[0].lane === 'lane-a' &&
   o.events[0].changes.length === 1 && o.events[0].changes[0].field === 'status' &&
   o.events[0].changes[0].from === 'pending' && o.events[0].changes[0].to === 'BEHIND'"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|BLOCKED|0|r1|"; base
prs "5|OPEN|bbbb0005|BLOCKED|2|r1+u1|hubot:APPROVED"
wait_run
check "sha, comments, resolved and approvals changes are listed together on one pr_change" 0 \
  "o.events.length === 1 && o.events[0].changes.map((c) => c.field).join() === 'sha,comments,resolved,approved_by' &&
   o.events[0].changes[1].from === 1 && o.events[0].changes[1].to === 4 &&
   o.events[0].changes[3].from.length === 0 && o.events[0].changes[3].to.join() === 'hubot'"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|1||hubot:APPROVED|passed"; base
prs "5|MERGED|aaaa0005|CLEAN|1||hubot:APPROVED|passed"
before=$(gh_count)
wait_run
check "an open PR that merges is a pr_change of state only" 0 \
  "o.events.length === 1 && o.events[0].type === 'pr_change' && o.events[0].changes.length === 1 &&
   o.events[0].changes[0].field === 'state' && o.events[0].changes[0].from === 'OPEN' && o.events[0].changes[0].to === 'MERGED'"
gh_calls_since "$before" | grep -q '"view"' && fail "a merged PR is not read past gh pr list" || pass "a merged PR is not read past gh pr list"
wait_run
check "the merge is reported once" 0 "$HB"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0||"; base
prs "6|OPEN|cccc0006|BLOCKED|0||" "5|CLOSED|aaaa0005|CLEAN|0||"
wait_run
check "a PR closed and replaced on the same branch: pr_opened for the new one, pr_change to CLOSED for the old" 0 \
  "o.events.length === 2 && o.events.some((e) => e.type === 'pr_opened' && e.number === 6) &&
   o.events.some((e) => e.type === 'pr_change' && e.number === 5 && e.changes[0].field === 'state' && e.changes[0].to === 'CLOSED')"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0||"; base
groute "$PRLIST_RE" "EXIT:1"
wait_run
check "a gh failure keeps the baseline PRs: no event, degraded names the lane" 0 \
  "$HB && o.degraded.length === 1 && /prs lane-a/.test(o.degraded[0])"
baseline_ok "the failed poll left the PR open in the baseline" "s.prs.length === 1 && s.prs[0].state === 'OPEN'"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0||"; base
printf '{"message":"odd"}' > "$CASE/fx/not-a-list.json"; groute "$PRLIST_RE" not-a-list.json
wait_run
check "a gh pr list that is not a list is degraded, never read as no PRs" 0 "$HB && o.degraded.some((d) => /did not return a list/.test(d))"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0||"; base
groute "^pr view 5 -R $REPO " "HTTP:502"
wait_run
check "an unreadable open PR is degraded, never a closed or merged event" 0 "$HB && o.degraded.some((d) => /502/.test(d))"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|CLEAN|0||"; base
agents
wait_run
check "a lane whose pane left the agent list keeps its PRs: no event" 0 "$HB"
baseline_ok "the paneless lane's PR stays in the baseline" "s.prs.length === 1 && s.prs[0].number === 5"

newcase
lane lane-a working:null; lane_wt
lane lane-b working:null
prs "5|OPEN|aaaa0005|CLEAN|0||"; base
LANES="lane-b"
wait_run
check "a lane dropped from --lanes drops its PRs without an event" 0 "$HB"
baseline_ok "the dropped lane's PRs leave the baseline" "s.prs.length === 0"

# --- wait: PR head checks -----------------------------------------------------
newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|BLOCKED|0|||pending"; base
prs "5|OPEN|aaaa0005|BLOCKED|0|||passed"
wait_run
check "an open PR's head checks that pass are a pr_checks event" 0 \
  "o.events.length === 1 && o.events[0].type === 'pr_checks' && o.events[0].project === 'octo' && o.events[0].number === 5 &&
   o.events[0].sha === 'aaaa0005' && o.events[0].state === 'passed' && o.events[0].lane === 'lane-a'"
wait_run
check "passed checks are raised once" 0 "$HB"
prs "5|OPEN|aaaa0005|BLOCKED|0|||pending"; wait_run
prs "5|OPEN|aaaa0005|BLOCKED|0|||passed"; wait_run
check "checks re-run to passed on the same head are not raised again (once per head and state)" 0 "$HB"
prs "5|OPEN|aaaa0005|BLOCKED|0|||failed"; wait_run
check "the same head reaching another state is raised" 0 "o.events.length === 1 && o.events[0].type === 'pr_checks' && o.events[0].state === 'failed'"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|BLOCKED|0|||passed"; base
prs "5|OPEN|bbbb0005|BLOCKED|0|||failed"
wait_run
check "a new head whose checks failed is a pr_checks event beside the pr_change" 0 \
  "o.events.some((e) => e.type === 'pr_checks' && e.state === 'failed' && e.sha === 'bbbb0005') && o.events.some((e) => e.type === 'pr_change')"
prs "5|OPEN|cccc0005|BLOCKED|0|||passed"; wait_run
check "passed on yet another head is raised again" 0 "o.events.some((e) => e.type === 'pr_checks' && e.state === 'passed' && e.sha === 'cccc0005')"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|BLOCKED|0|||pending"; base
prs "5|OPEN|aaaa0005|BLOCKED|0|||incomplete"
wait_run
check "cancelled checks are a pr_checks incomplete event" 0 "o.events.length === 1 && o.events[0].type === 'pr_checks' && o.events[0].state === 'incomplete'"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|BLOCKED|0|||pending"; base
wait_run
check "pending checks raise nothing" 0 "$HB"
prs "5|OPEN|aaaa0005|BLOCKED|0|||none"; wait_run
check "no checks reported raises nothing" 0 "$HB"

newcase
lane lane-a working:null; lane_wt; base
prs "5|OPEN|aaaa0005|BLOCKED|0|||passed"
wait_run
check "a PR first seen with passed checks is only pr_opened" 0 "o.events.length === 1 && o.events[0].type === 'pr_opened'"
wait_run
check "and its passed checks are not raised on the next poll" 0 "$HB"

# --- wait: GitHub rate limit -------------------------------------------------
newcase
lane lane-a working:null; lane_wt; base
groute "$PRLIST_RE" "RATE"
before=$(gh_count)
wait_run
check "a GitHub rate limit is named in degraded with the backoff" 0 \
  "o.events[0].type === 'heartbeat' && o.degraded.some((d) => /rate limit/.test(d) && /next GitHub poll/.test(d))"
gh_calls_since "$before" | grep -q '"search"' \
  && fail "after a rate limit the rest of the tick's GitHub calls are skipped" || pass "after a rate limit the rest of the tick's GitHub calls are skipped"
baseline_ok "the backoff is kept in the baseline for the next wait" "s.github_backoff >= 2 && s.github_quiet_until > Date.now() - 5000"
groute "$PRLIST_RE" empty-list.json
baseline_set "s.github_quiet_until = Date.now() + 60000"
before=$(gh_count)
run wait --lanes "$LANES" --run-dir "$CASE/run" --max 0
[ -z "$(gh_calls_since "$before")" ] && pass "a wait re-armed inside the backoff makes no GitHub call" || fail "a wait re-armed inside the backoff makes no GitHub call"
check "the paused poll is named in degraded" 0 "o.degraded.some((d) => /paused/.test(d))"
baseline_set "s.github_quiet_until = 0"
run wait --lanes "$LANES" --run-dir "$CASE/run" --max 0
baseline_ok "a clean GitHub poll after the backoff resets it" "!s.github_backoff && !s.github_quiet_until"

newcase
lane lane-a working:null; lane_wt; base
groute "$SEARCH_RE" "HTTP:429"
wait_run
check "HTTP 429 on the review-request search is a rate limit too" 0 "o.degraded.some((d) => /next GitHub poll/.test(d))"

newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|BLOCKED|0|||pending" "6|CLOSED|bbbb0006|BLOCKED|0||"; base
prs "5|OPEN|aaaa0005|BLOCKED|0|||passed" "6|OPEN|bbbb0006|BLOCKED|0||"
groute "^api repos/$REPO/pulls/6/reviews " "RATE"
wait_run
check "a lane whose PR poll is rate-limited partway raises no PR event that tick" 0 "!o.events.some((e) => /^pr_/.test(e.type))"
baseline_ok "a lane whose PR poll fails partway keeps one baseline entry per PR, all from before" \
  "s.prs.map((m) => m.number).join() === '5,6' && s.prs[0].checks.state === 'pending' && s.prs[1].state === 'CLOSED'"
groute "^api repos/$REPO/pulls/6/reviews " "reviews-6.json"
baseline_set "s.github_quiet_until = 0"
wait_run
check "the clean poll after a partial failure raises the checks change once" 0 \
  "o.events.filter((e) => e.type === 'pr_checks').length === 1 && o.events.some((e) => e.type === 'pr_checks' && e.number === 5 && e.state === 'passed')"
wait_run
check "the checks change is not raised again on the next poll" 0 "$HB"

# --- wait: a baseline that could not read a source ----------------------------
newcase
lane lane-a working:null; lane_wt
prs "5|OPEN|aaaa0005|BLOCKED|0|||passed"
groute "$PRLIST_RE" "RATE"
base
baseline_ok "a rate-limited first wait lists the sources it could not read" \
  "s.unread.includes('prs:lane-a') && s.unread.includes('review_requests') && s.prs.length === 0"
groute "$PRLIST_RE" prlist.json
review_requests "octo-org/octo-repo#7|hubot"
baseline_set "s.github_quiet_until = 0"
wait_run
check "the first clean read after a degraded baseline raises no pr_opened or review_request for what was already there" 0 "$HB"
baseline_ok "the clean read becomes the baseline and leaves unread" \
  "s.unread.length === 0 && s.prs.length === 1 && s.prs[0].number === 5 && s.review_requests.length === 1"
prs "5|OPEN|bbbb0005|BLOCKED|0|||passed"
review_requests "octo-org/octo-repo#7|hubot" "octo-org/octo-repo#8|hubot"
wait_run
check "changes after that baseline are raised as usual" 0 \
  "o.events.some((e) => e.type === 'pr_change' && e.changes[0].field === 'sha') &&
   o.events.some((e) => e.type === 'review_request' && e.ref === 'octo-org/octo-repo#8') && !o.events.some((e) => e.ref === 'octo-org/octo-repo#7')"

newcase
lane lane-a working:null
groute "$SEARCH_RE" "EXIT:1"
base
baseline_ok "a failed first review-request search is listed as unread" "s.unread.includes('review_requests')"
review_requests "octo-org/octo-repo#7|hubot"
wait_run
check "the first clean review-request search after it raises nothing" 0 "$HB"
groute "$SEARCH_RE" "EXIT:1"; wait_run
review_requests "octo-org/octo-repo#7|hubot" "octo-org/octo-repo#9|hubot"; wait_run
check "a failure after the review requests were baselined keeps them, and a new request is raised" 0 \
  "o.events.length === 1 && o.events[0].type === 'review_request' && o.events[0].ref === 'octo-org/octo-repo#9'"

newcase
lane lane-a working:null; base
baseline_ok "a lane without a pane at the baseline is listed as unread" "s.unread.includes('prs:lane-a')"
lane_wt; prs "5|OPEN|aaaa0005|BLOCKED|0||"
wait_run
check "its PRs, first read when its pane appears, become its baseline quietly" 0 "!o.events.some((e) => /^pr_/.test(e.type))"
prs "5|OPEN|aaaa0005|CLEAN|0||"; wait_run
check "and its later PR changes are raised" 0 "o.events.length === 1 && o.events[0].type === 'pr_change' && o.events[0].changes[0].to === 'CLEAN'"

newcase
lane lane-a working:null
lane_wt; groute "$PRLIST_RE" "EXIT:1"
base
wait_run
baseline_ok "a source that keeps failing stays unread" "s.unread.includes('prs:lane-a')"
prs "5|OPEN|aaaa0005|BLOCKED|0||"; wait_run
check "and is still baselined quietly once it reads" 0 "!o.events.some((e) => /^pr_/.test(e.type))"

# --- wait: review requests ----------------------------------------------------
newcase
lane lane-a working:null; base
review_requests "octo-org/octo-repo#7|hubot" "other-org/tool#8|monalisa"
wait_run
check "a new allowlisted review request is a review_request event, others are ignored" 0 \
  "o.events.length === 1 && o.events[0].type === 'review_request' && o.events[0].ref === 'octo-org/octo-repo#7' && o.events[0].author === 'hubot'"

newcase
lane lane-a working:null
review_requests "octo-org/octo-repo#7|hubot"; base
wait_run
check "a review request already in the baseline raises nothing" 0 "$HB"
groute "$SEARCH_RE" "EXIT:1"
wait_run
check "a failed review-request search keeps the baseline and is degraded" 0 "$HB && o.degraded.some((d) => /review requests/.test(d))"
review_requests "octo-org/octo-repo#7|hubot"; wait_run
check "the request is not raised again once the search reads again" 0 "$HB"

# --- wait: CI on a ref --------------------------------------------------------
newcase
lane lane-a working:null
ci_head "$S1"; ci_runs "$S1" "in_progress:"; base --ci octo:main
ci_runs "$S1" "in_progress:" "completed:success+completed:skipped"
wait_event --ci octo:main
check "a ref's runs that finish are a ci_done success event" 0 \
  "o.events.length === 1 && o.events[0].type === 'ci_done' && o.events[0].project === 'octo' && o.events[0].ref === 'main' &&
   o.events[0].sha === '$S1' && o.events[0].status === 'success'"
wait_run --ci octo:main
check "ci_done is raised once" 0 "$HB"

newcase
lane lane-a working:null
ci_head "$S1"; ci_runs "$S1" "completed:success"; base --ci octo:main
wait_run --ci octo:main
check "a ref already finished in the baseline raises nothing" 0 "$HB"
ci_head "$S2"; ci_runs "$S2" "completed:failure+in_progress:"
wait_run --ci octo:main
check "the ref moving to a commit with a failed run is ci_done failed, even with another run still going" 0 \
  "o.events.length === 1 && o.events[0].type === 'ci_done' && o.events[0].sha === '$S2' && o.events[0].status === 'failed'"

newcase
lane lane-a working:null
ci_head "$S1"; ci_runs "$S1" "in_progress:"; base --ci octo:main
ci_runs "$S1" "completed:cancelled+completed:success"
wait_run --ci octo:main
check "a cancelled run is ci_done canceled" 0 "o.events.length === 1 && o.events[0].status === 'canceled'"

newcase
lane lane-a working:null
ci_head "$S1"; ci_runs "$S1" "in_progress:"; base --ci octo:main
ci_runs "$S1" "completed:action_required+completed:success"
wait_run --ci octo:main
check "a run waiting for approval is still pending: no event" 0 "$HB"

newcase
lane lane-a working:null
ci_head "$S1"; ci_runs "$S1" "in_progress:"; base --ci octo:main
groute "^run list -R $REPO --commit $S1 " "EXIT:1"
wait_run --ci octo:main
check "a failed run-list poll keeps the baseline and is listed in degraded" 0 \
  "$HB && o.degraded.length === 1 && /octo:main/.test(o.degraded[0])"
groute "$COMMIT_RE" "HTTP:404"
wait_run --ci octo:main
check "an unresolvable ref is degraded, never a ci_done" 0 "$HB && o.degraded.some((d) => /octo:main/.test(d) && /404/.test(d))"

newcase
lane lane-a working:null
ci_head "$S1"; ci_runs "$S1" "-"; base --ci octo:main
CI_NONE_MS=0
wait_run --ci octo:main
check "a ref whose commit has no run past HERD_CI_NONE_MS is ci_done none" 0 "o.events.length === 1 && o.events[0].status === 'none'"

# --- wait: CI pinned to a commit ----------------------------------------------
newcase
lane lane-a working:null; base
ci_runs "$PIN" "completed:success+completed:neutral"
wait_run --ci "octo:main@$PIN"
check "a pinned commit already finished fires on the first wait even though its key is new" 0 \
  "o.events.length === 1 && o.events[0].type === 'ci_done' && o.events[0].status === 'success' && o.events[0].sha === '$PIN' && o.events[0].ref === 'main'"
grep -q '"commits/main"\|repos/octo-org/octo-repo/commits/main' "$CASE/fx/gh-calls.log" && fail "a pinned entry does not resolve its ref" || pass "a pinned entry does not resolve its ref"
wait_run --ci "octo:main@$PIN"
check "the same finished pinned commit does not fire again on the next wait" 0 "$HB"

newcase
lane lane-a working:null
ci_runs "$PIN" "completed:success"; base --ci "octo:main@$PIN"
check "a pinned commit already finished fires on a first wait with no baseline" 0 \
  "o.events.length === 1 && o.events[0].type === 'ci_done' && o.events[0].sha === '$PIN'"

newcase
lane lane-a working:null; base
ci_runs "$PIN" "queued:" "completed:success"
wait_event --ci "octo:main@$PIN"
check "a pinned commit still running raises nothing, then fires when it succeeds" 0 \
  "o.events.length === 1 && o.events[0].type === 'ci_done' && o.events[0].status === 'success' && o.events[0].sha === '$PIN'"

newcase
lane lane-a working:null; base
ci_runs "$PIN" "-"
CI_NONE_MS=600000
wait_run --ci "octo:main@$PIN"
check "a pinned commit with no run yet raises nothing inside HERD_CI_NONE_MS" 0 "$HB"
baseline_ok "the first empty read is kept in the baseline" "s.ci['octo:main@$PIN'].status === 'pending' && s.ci['octo:main@$PIN'].empty_since > 0"
baseline_set "s.ci['octo:main@$PIN'].empty_since = Date.now() - 700000"
wait_run --ci "octo:main@$PIN"
check "a pinned commit that has had no run for HERD_CI_NONE_MS is ci_done none" 0 \
  "o.events.length === 1 && o.events[0].type === 'ci_done' && o.events[0].status === 'none'"
ci_runs "$PIN" "completed:success"
wait_run --ci "octo:main@$PIN"
check "a run that registers after none still reports its result" 0 "o.events.length === 1 && o.events[0].status === 'success'"

newcase
lane lane-a working:null
run wait --lanes lane-a --run-dir "$CASE/run" --max 0 --ci "octo:main@"
check "a pinned entry with an empty sha is a usage error" 2 "/ci/.test(o.error)"
run wait --lanes lane-a --run-dir "$CASE/run" --max 0 --ci "octo:@$PIN"
check "a pinned entry with an empty ref is a usage error" 2 "/ci/.test(o.error)"
run wait --lanes lane-a --run-dir "$CASE/run" --max 0 --ci "octo:main@abc1234"
check "a pinned sha shorter than 40 hex is a usage error (gh run list --commit needs the full sha)" 2 "/40 hex/.test(o.error)"
run wait --lanes lane-a --run-dir "$CASE/run" --max 0 --ci "octo:main?x=1"
check "a ref that is not a plain ref name is a usage error" 2 "/plain ref/.test(o.error)"
run wait --lanes lane-a --run-dir "$CASE/run" --max 0 --ci nope:main
check "a ci entry naming an unknown project is a usage error" 2 "/nope/.test(o.error)"
run wait --lanes lane-a --run-dir "$CASE/run" --max 0 --ci octomain
check "a ci entry without a ref is a usage error" 2 "/--ci/.test(o.error)"
run wait --lanes lane-a --run-dir "$CASE/run" --max 0 --ci 'octo:main@null'
check "a pinned sha that is not hex is a usage error" 2 "/sha/.test(o.error)"

[ "$fails" -eq 0 ] && echo "all herd-watch tests passed" || echo "$fails herd-watch test(s) failed"
[ "$fails" -eq 0 ]
