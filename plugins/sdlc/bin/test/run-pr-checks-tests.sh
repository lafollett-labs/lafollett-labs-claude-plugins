#!/usr/bin/env bash
# Fixture tests for pr-checks.js — confirms --head is the PR head, then classifies the head's checks
# (passed, failed with run ids, pending, incomplete, none), re-reads a none under --settle, and fails closed on
# gh errors, timeouts and non-JSON. gh is the shared stub-gh.sh serving per-case routes. No npm packages — bash +
# node only.
# SDLC_TEST_TMP=<dir> keeps the case dirs there instead of a self-cleaning mktemp dir.
# Exit 0 = all checks pass, 1 = any fail.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../pr-checks.js"
STUB="$HERE/stub-gh.sh"
FIX="$HERE/fixtures/pr-checks"

command -v node >/dev/null 2>&1 || { echo "FAIL: node not on PATH — cannot run pr-checks tests" >&2; exit 1; }
[ -f "$CLI" ] || { echo "FAIL: pr-checks.js not found at $CLI" >&2; exit 1; }
[ -x "$STUB" ] || { echo "FAIL: stub-gh.sh not executable at $STUB" >&2; exit 1; }

if [ -n "${SDLC_TEST_TMP:-}" ]; then
  W="$(mktemp -d "$SDLC_TEST_TMP/pr-checks.XXXX")"
else
  W="$(mktemp -d)"
  trap 'rm -rf "$W"' EXIT
fi

total=0
fails=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); fails=$((fails + 1)); echo "FAIL: $1"; }

HEAD=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98
VIEW='^pr view 7 --json headRefOid$'
CHECKS='^pr checks 7 --json name,workflow,state,bucket,link$'

# newcase — a fresh STUB_GH_DIR holding every fixture and an empty routes file
N=0
newcase() {
  N=$((N + 1))
  CASE="$W/case$N"
  mkdir -p "$CASE"
  cp "$FIX"/* "$CASE/"
  : > "$CASE/routes"
}
# route <ERE> <exit> <response files> — one stub-gh route
route() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CASE/routes"; }
# head_is <response> — the PR head route; checks_are <exit> <response> — the checks route
head_is() { route "$VIEW" 0 "$1"; }
checks_are() { route "$CHECKS" "$1" "$2"; }

# run [--head <sha>] [extra args...] — sets $out and $code; runs in $CASE (no workflows) unless RUN_DIR names a
# checkout; gh is the stub unless SDLC_GH is preset; --settle re-reads every 100 ms
run() {
  local head="$HEAD"
  if [ "${1:-}" = "--head" ]; then head="$2"; shift 2; fi
  out="$(cd "${RUN_DIR:-$CASE}" && SDLC_GH="${GH_OVERRIDE:-$STUB}" STUB_GH_DIR="$CASE" \
    SDLC_GH_TIMEOUT_MS="${TIMEOUT_MS:-5000}" SDLC_SETTLE_POLL_MS=100 node "$CLI" check --pr 7 --head "$head" "$@" 2>/dev/null)"
  code=$?
}
# check <name> <expected-exit> <js-boolean-expression over `o`>
check() {
  local name="$1" want="$2" expr="$3"
  if [ "$code" -eq "$want" ] && node -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$out" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — exit $code, got: $out"
  fi
}
# calls_are <name> <expected calls, one per line> — the exact gh invocations the case made
calls_are() {
  local got
  got="$(cat "$CASE/calls" 2>/dev/null)"
  if [ "$got" = "$2" ]; then pass "$1"; else fail "$1 — calls were: $got"; fi
}

# --- passed ------------------------------------------------------------------
newcase; head_is pr-view.json; checks_are 0 checks-passed.json
run
check "pass and skipping checks are passed" 0 \
  'o.state === "passed" && o.head === "'$HEAD'" && o.checks.length === 3 && o.failed_checks.length === 0 && /2 checks passed .*\(1 skipped\)/.test(o.reason)'
check "each check carries exactly name, workflow, state, bucket, link" 0 \
  'o.checks.every((c) => Object.keys(c).join() === "name,workflow,state,bucket,link") && o.checks[2].bucket === "skipping"'
calls_are "the head is read before its checks, with the contract's fields" \
  "$(printf '%s\n' 'pr view 7 --json headRefOid' 'pr checks 7 --json name,workflow,state,bucket,link')"

newcase; head_is pr-view.json; checks_are 0 checks-passed.json
run --head "${HEAD:0:7}"
check "a 7-character --head prefix matches the PR head" 0 'o.state === "passed" && o.head === "'$HEAD'"'

newcase; head_is pr-view.json; checks_are 0 checks-passed.json
run --head "$(printf '%s' "$HEAD" | tr 'a-f' 'A-F')"
check "an uppercase --head matches the PR head" 0 'o.state === "passed"'

# --- failed ------------------------------------------------------------------
newcase; head_is pr-view.json; checks_are 0 checks-failed.json
run
check "any fail bucket is failed, even with a pending check" 0 'o.state === "failed" && /2 of 4 checks failed .*: test, external\/ci$/.test(o.reason)'
check "failed_checks carries the Actions run id parsed from the link" 0 \
  'o.failed_checks.length === 2 && o.failed_checks[0].name === "test" && o.failed_checks[0].run_id === 1001 && o.failed_checks[0].link.endsWith("/actions/runs/1001/job/2002")'
check "a failed check outside Actions has run_id null" 0 'o.failed_checks[1].name === "external/ci" && o.failed_checks[1].run_id === null'

newcase; head_is pr-view.json; checks_are 1 checks-failed.json
run
check "gh exiting 1 with the checks on stdout is still read as failed" 0 'o.state === "failed" && o.failed_checks.length === 2'

# --- pending / incomplete ---------------------------------------------------------
newcase; head_is pr-view.json; checks_are 0 checks-pending.json
run
check "any pending bucket (no fail) is pending, ahead of a cancel" 0 'o.state === "pending" && o.failed_checks.length === 0 && /1 of 3 checks pending .*: test$/.test(o.reason)'

newcase; head_is pr-view.json; checks_are 8 checks-pending.json
run
check "gh's pending exit code 8 with the checks on stdout is pending" 0 'o.state === "pending"'

newcase; head_is pr-view.json; checks_are 0 checks-canceled.json
run
check "a cancel bucket with no fail or pending is incomplete" 0 'o.state === "incomplete" && /1 of 2 checks canceled .*: e2e$/.test(o.reason)'

# --- none ------------------------------------------------------------------------
newcase; head_is pr-view.json; checks_are 1 no-checks.stderr
run
check "gh's 'no checks reported' is none" 0 'o.state === "none" && o.checks.length === 0 && o.failed_checks.length === 0 && /no checks reported on PR #7 head 01234567/.test(o.reason)'

newcase; head_is pr-view.json; checks_are 0 checks-empty.json
run
check "an empty check list is none" 0 'o.state === "none" && o.head === "'$HEAD'"'

# --- HEAD mismatch -------------------------------------------------------------------
newcase; head_is pr-view.json; checks_are 0 checks-passed.json
run --head "$OTHER"
check "a --head that is not the PR head is an error" 2 'o.error === "HEAD is not the PR head" && Object.keys(o).join() === "error"'
calls_are "a HEAD mismatch never reads the checks" 'pr view 7 --json headRefOid'

newcase; head_is pr-view-no-head.json
run
check "a PR view without headRefOid is an error" 2 '/no headRefOid/.test(o.error)'

# --- gh failures fail closed (exit 2) ---------------------------------------------------
newcase; route "$VIEW" 1 gh-error.stderr
run
check "a failing gh pr view is an error carrying gh's reason" 2 'o.error === "gh pr view 7 failed: GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)"'

newcase; head_is pr-view.json; checks_are 1 gh-error.stderr
run
check "a failing gh pr checks is an error carrying gh's reason" 2 '/^gh pr checks 7 failed: GraphQL/.test(o.error)'

newcase; head_is pr-view.json; checks_are 8 -
run
check "gh's pending exit code with nothing on stdout is an error" 2 '/^gh pr checks 7 failed/.test(o.error)'

newcase; head_is pr-view.json; checks_are 4 checks-passed.json
run
check "an unexpected gh exit code is an error even with output" 2 '/^gh pr checks 7 failed/.test(o.error)'

newcase; head_is pr-view.json; checks_are 0 not-json.txt
run
check "non-JSON from gh pr checks is an error" 2 'o.error === "gh pr checks 7 returned non-JSON"'

newcase; route "$VIEW" 0 not-json.txt
run
check "non-JSON from gh pr view is an error" 2 'o.error === "gh pr view 7 returned non-JSON"'

newcase; head_is pr-view.json; checks_are 0 checks-not-a-list.json
run
check "a checks payload that is not a list is an error" 2 '/did not return a list/.test(o.error)'

newcase; head_is pr-view.json; checks_are 0 checks-unknown-bucket.json
run
check "an unknown bucket is an error" 2 "/unknown check bucket 'mystery' on check 'build'/.test(o.error)"

newcase
start=$(date +%s)
GH_OVERRIDE="$FIX/sleep-gh.sh" TIMEOUT_MS=300 run
elapsed=$(( $(date +%s) - start ))
check "a hung gh call is killed and reported as timed out" 2 'o.error === "gh pr view 7 timed out"'
if [ "$elapsed" -lt 10 ]; then pass "the timeout returns promptly (${elapsed}s)"; else fail "the timeout took ${elapsed}s"; fi

newcase
GH_OVERRIDE="$W/no-such-gh" run
check "an unrunnable gh is an error" 2 '/^gh not runnable/.test(o.error)'

# --- --settle ----------------------------------------------------------------------------
# checkout <name> <file>=<on: trigger>... — a dir whose .github/workflows holds those files
checkout() {
  local d="$W/$1" f; shift
  mkdir -p "$d/.github/workflows"
  for f in "$@"; do printf 'on: %s\n' "${f#*=}" > "$d/.github/workflows/${f%%=*}"; done
  RUN_DIR="$d"
}
reads() { grep -c "^pr checks" "$CASE/calls"; }

checkout pr-yml ci.yml=pull_request
newcase; head_is pr-view.json; checks_are 0 checks-empty.json,checks-empty.json,checks-passed.json
run --settle 5
check "--settle re-reads a none until the checks register" 0 'o.state === "passed" && o.checks.length === 3'
calls_are "each re-read confirms the head first" "$(printf 'pr view 7 --json headRefOid\npr checks 7 --json name,workflow,state,bucket,link\n%.0s' 1 2 3)"

checkout pr-yaml ci.yaml='[push, pull_request]'
newcase; head_is pr-view.json; checks_are 0 checks-empty.json
start=$(date +%s); run --settle 1; elapsed=$(( $(date +%s) - start ))
check "--settle returns none once the window passes" 0 'o.state === "none" && /^no checks reported/.test(o.reason)'
if [ "$(reads)" -ge 3 ] && [ "$elapsed" -lt 5 ]; then pass "--settle polls within the window ($(reads) reads, ${elapsed}s)"
else fail "--settle read $(reads) times in ${elapsed}s"; fi

checkout push-only ci.yml=push notes.md=pull_request
newcase; head_is pr-view.json; checks_are 0 checks-empty.json,checks-passed.json
run --settle 30
check "--settle returns none at once with no pull_request workflow" 0 'o.state === "none"'
if [ "$(reads)" -eq 1 ]; then pass "no pull_request workflow means one read"; else fail "no pull_request workflow read $(reads) times"; fi

newcase; head_is pr-view.json; checks_are 0 checks-empty.json,checks-passed.json
RUN_DIR="$W/pr-yml" run --settle 0
check "--settle 0 reads once" 0 'o.state === "none"'
newcase; head_is pr-view.json; checks_are 0 checks-pending.json,checks-passed.json
RUN_DIR="$W/pr-yml" run --settle 30
check "--settle leaves a state other than none alone" 0 'o.state === "pending"'
if [ "$(reads)" -eq 1 ]; then pass "a pending head is read once"; else fail "a pending head was read $(reads) times"; fi

newcase; printf '{"headRefOid":"%s"}\n' "$OTHER" > "$CASE/pr-view-moved.json"
head_is pr-view.json,pr-view-moved.json; checks_are 0 checks-empty.json,checks-passed.json
RUN_DIR="$W/pr-yml" run --settle 5
check "--settle fails when the PR head moves mid-wait" 2 'o.error === "HEAD is not the PR head"'
unset RUN_DIR

# --- arguments ---------------------------------------------------------------------------
args_case() {  # args_case <name> <error regex> <args...>
  local name="$1" re="$2"; shift 2
  out="$(SDLC_GH="$W/no-such-gh" node "$CLI" "$@" 2>/dev/null)"; code=$?
  check "$name" 2 "/$re/.test(o.error)"
}
args_case "a non-numeric --pr is an error" '--pr must be' check --pr x --head "$HEAD"
args_case "--pr 0 is an error" '--pr must be' check --pr 0 --head "$HEAD"
args_case "a non-hex --head is an error" '--head must be' check --pr 7 --head zzzzzzz
args_case "a --head shorter than 7 is an error" '--head must be' check --pr 7 --head 012345
args_case "an unknown option is an error" "unknown option '--issue'" check --issue 7 --head "$HEAD"
args_case "a flag with no value is an error" 'missing value for --head' check --pr 7 --head
args_case "a non-numeric --settle is an error" '--settle must be' check --pr 7 --head "$HEAD" --settle 5s
args_case "a --settle over 600 is an error" '--settle must be a whole number of seconds from 0 to 600' check --pr 7 --head "$HEAD" --settle 601
args_case "an unknown command is an error" "unknown command 'status'" status --pr 7 --head "$HEAD"

echo
echo "$total checks, $fails failed"
[ "$fails" -eq 0 ] || exit 1
