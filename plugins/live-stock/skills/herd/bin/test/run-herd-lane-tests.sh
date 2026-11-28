#!/usr/bin/env bash
# Fixture tests for herd-lane.js start | restart | close — input validation, the herdr call sequence, the
# blocked-gate error, and the close safety verdict. herdr and gh are the stubs; worktree-cleanup.js is a stub
# in a fake sdlc root, git-conventions.js is a vendored copy of the sdlc plugin's (fixtures/git-conventions.js).
# git on PATH is a wrapper that logs each call to git-calls.log. HOME, PATH and the config path point into a temp dir.
# shellcheck disable=SC2317,SC2329 # the lane_* helpers, not() and the log probes run indirectly through named/assert
# No network, no live herdr. No npm packages — bash + node only. Exit 0 = all cases pass, 1 = any fail.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../herd-lane.js"
FX_SRC="$HERE/fixtures/herd-lane"
GITCONV="$HERE/fixtures/git-conventions.js"
NODE="$(command -v node)"
GIT="$(command -v git)"
[ -n "$NODE" ] || { echo "FAIL: node not on PATH — cannot run herd-lane tests" >&2; exit 1; }
[ -f "$CLI" ] || { echo "FAIL: herd-lane.js not found at $CLI" >&2; exit 1; }
[ -f "$GITCONV" ] || { echo "FAIL: git-conventions.js not found at $GITCONV" >&2; exit 1; }

# The real path: git reports worktree paths resolved (macOS /var is /private/var).
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# newcase — fresh HOME, fixtures, stub herdr/gh and a logging git on PATH, a valid config, a fake sdlc root
newcase() {
  CASE="$TMP/case$RANDOM$RANDOM"
  mkdir -p "$CASE/home/.claude/herd" "$CASE/bin" "$CASE/fx" "$CASE/repos/checkout" "$CASE/sdlc/bin" "$CASE/sdlc/skills/review/bin" "$CASE/sdlc/.claude-plugin"
  ln -s "$HERE/stub-gh.js" "$CASE/bin/gh"
  ln -s "$HERE/stub-herdr.js" "$CASE/bin/herdr"
  ln -s "$NODE" "$CASE/bin/node"
  # shellcheck disable=SC2016 # $* and $@ belong to the wrapper script, not this shell
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$HERD_FIXTURES/git-calls.log"\nexec "%s" "$@"\n' "$GIT" > "$CASE/bin/git"
  chmod +x "$CASE/bin/git"
  cp "$FX_SRC"/*.json "$CASE/fx/"
  : > "$CASE/fx/herdr-routes"; : > "$CASE/fx/routes"
  printf '{"name":"sdlc","version":"9.9.9"}' > "$CASE/sdlc/.claude-plugin/plugin.json"
  ln -s "$GITCONV" "$CASE/sdlc/bin/git-conventions.js"
  cat > "$CASE/sdlc/skills/review/bin/worktree-cleanup.js" <<'JS'
const fs = require('fs'), path = require('path');
fs.appendFileSync(path.join(process.env.HERD_FIXTURES, 'cleanup-calls.log'), `${JSON.stringify(process.argv.slice(2))}\n`);
process.stdout.write(fs.readFileSync(path.join(process.env.HERD_FIXTURES, 'verdict.json')));
JS
  CHECKOUT="$CASE/repos/checkout"
  WT="$CASE/repos/.sdlc-worktrees/checkout/42"
  g init -q -b main && g commit -q --allow-empty -m init
  printf '{"result":{"type":"worktree_list","worktrees":[]}}' > "$CASE/fx/worktree-list-none.json"
  write_config "$CHECKOUT"
  RUN_PATH="$CASE/bin"
  STDIN="do the story"
}
# write_config <checkout> [extra defaults JSON, e.g. ,"lane_compact_window":277778]
# LANE_DEFAULTS overrides the lane model/effort keys; set it to "" for a config with neither.
write_config() {
  local lane=',"lane_model":"sonnet","lane_effort":"medium"'
  lane=${LANE_DEFAULTS-$lane}
  cat > "$CASE/home/.claude/herd/config.json" <<JSON
{"projects":{"octo":{"repo":"octo-org/octo-repo","checkout":"$1","main_push":"pr-only","merge_method":"squash"}},
 "review_request_authors":["hubot"],"defaults":{"max_lanes":3$lane${2:-}}}
JSON
}
# g <git args> — git in the checkout, with an identity for commits
g() { "$GIT" -C "$CHECKOUT" -c user.name=t -c user.email=t@t "$@"; }
# herdr_worktrees <path|open_workspace_id>... — the herdr worktree list reply before start
herdr_worktrees() {
  local items="" spec p w
  for spec in "$@"; do
    IFS='|' read -r p w <<<"$spec"
    if [ -n "$w" ]; then w="\"$w\""; else w=null; fi
    items="$items${items:+,}{\"path\":\"$p\",\"open_workspace_id\":$w,\"is_linked_worktree\":true}"
  done
  printf '{"result":{"type":"worktree_list","worktrees":[%s]}}' "$items" > "$CASE/fx/worktree-list-start.json"
  : > "$CASE/fx/herdr-routes.new"; grep -v '^worktree list' "$CASE/fx/herdr-routes" > "$CASE/fx/herdr-routes.new"
  mv "$CASE/fx/herdr-routes.new" "$CASE/fx/herdr-routes"; route "worktree list" "worktree-list-start.json"
}
# route <herdr key> <reply>[,<reply>...]
route() { printf '%s\t%s\n' "$1" "$2" >> "$CASE/fx/herdr-routes"; }
# groute <ERE over the gh args> <reply> — a stub-gh route
groute() { printf '%s\t%s\n' "$1" "$2" >> "$CASE/fx/routes"; }
# worktree_list <open_workspace_id> — a herdr worktree list reply naming $WT
worktree_list() {
  printf '{"result":{"type":"worktree_list","worktrees":[{"path":"%s","branch":"feat/42-x","open_workspace_id":"%s","is_linked_worktree":true}]}}' "$WT" "$1" > "$CASE/fx/worktree-list.json"
}
# run <command> [args...] — prompt on stdin from $STDIN; sets $out and $code
run() {
  out="$(cd "$CASE" && printf '%s' "$STDIN" | env -i HOME="$CASE/home" PATH="$RUN_PATH" HERD_FIXTURES="$CASE/fx" \
    HERD_CONFIG="$CASE/home/.claude/herd/config.json" HERD_SDLC_ROOT="$CASE/sdlc" HERD_POLL_MS=10 HERD_EXIT_TIMEOUT_MS=300 \
    HERD_GH_TIMEOUT_MS=2000 "$NODE" "$CLI" "$@" 2>/dev/null)"
  code=$?
}
# check <name> <expected-exit> <js-boolean-expression over `o`>
check() {
  local name="$1" want="$2" expr="$3"
  if [ "$code" -eq "$want" ] && "$NODE" -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$out" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — exit $code, got: $out"
  fi
}
# logged <pattern> — true when herdr-calls.log has a line matching the extended regex
logged() { grep -Eq -- "$1" "$CASE/fx/herdr-calls.log" 2>/dev/null; }
# git_logged <pattern> — true when git-calls.log (herd-lane's own git calls) has a matching line
git_logged() { grep -Eq -- "$1" "$CASE/fx/git-calls.log" 2>/dev/null; }
# lane_env <expr> — true when <expr> over `env` (the lane --settings env object, {} when absent) holds
lane_env() {
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const start = lines.find((a) => a[0] === "agent" && a[1] === "start");
const i = start ? start.indexOf("--settings") : -1;
if (i < 0) process.exit(1);
const s = JSON.parse(start[i + 1]);
const env = s.env === undefined ? {} : s.env;
process.exit((new Function("env", "s", "return (" + process.argv[2] + ")"))(env, s) ? 0 : 1);
' "$CASE/fx/herdr-calls.log" "$1" 2>/dev/null
}
# lane_denies <rule>... — true when the claude start carries --settings whose permissions.deny holds every rule
lane_denies() {
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const start = lines.find((a) => a[0] === "agent" && a[1] === "start");
const i = start ? start.indexOf("--settings") : -1;
const deny = i < 0 ? [] : (JSON.parse(start[i + 1]).permissions || {}).deny || [];
process.exit(process.argv.slice(2).every((r) => deny.includes(r)) ? 0 : 1);
' "$CASE/fx/herdr-calls.log" "$@" 2>/dev/null
}
# lane_push <deny|allow> <command>... — every command is denied (or every one allowed) by the lane's Bash deny rules,
# matched as Claude Code does: the whole command against the rule's glob, where * matches any text
lane_push() {
  # shellcheck disable=SC2016 # ${...} is a JavaScript template literal
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const start = lines.find((a) => a[0] === "agent" && a[1] === "start");
const i = start ? start.indexOf("--settings") : -1;
const deny = i < 0 ? [] : (JSON.parse(start[i + 1]).permissions || {}).deny || [];
const re = deny.map((r) => /^Bash\((.*)\)$/.exec(r)).filter(Boolean)
  .map((m) => new RegExp(`^${m[1].split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`));
const want = process.argv[2] === "deny";
process.exit(process.argv.slice(3).every((c) => re.some((r) => r.test(c)) === want) ? 0 : 1);
' "$CASE/fx/herdr-calls.log" "$@" 2>/dev/null
}
assert() { if "$@"; then pass "$ASSERT_NAME"; else fail "$ASSERT_NAME"; fi; }
named() { ASSERT_NAME="$1"; shift; assert "$@"; }
not() { ! "$@"; }

START="start --lane lane-42 --project octo --key 42 --branch feat/42-x"
start_routes() {
  route "worktree list" "worktree-list-none.json"
  route "worktree create" "worktree-created.json"
  route "worktree open" "worktree-opened.json"
  route "agent start" "ok.json"
  route "agent prompt" "ok.json"
}

# --- start: input validation -------------------------------------------------
newcase; start_routes; STDIN='!rm -rf /'
run $START
check "start refuses a prompt starting with !" 2 "/prompt/.test(o.error)"
named "start refused ! prompt makes no herdr call" not logged '.'

newcase; start_routes; STDIN='  !rm'
run $START
check "start refuses a ! prompt after trimming" 2 "/prompt/.test(o.error)"

newcase; start_routes; STDIN='   '
run $START
check "start refuses an empty prompt" 2 "/prompt/.test(o.error)"

newcase; start_routes
run start --lane Bad_Name --project octo --key 42 --branch feat/42-x
check "start refuses a bad lane name" 2 "/lane name/.test(o.error)"

newcase; start_routes
run start --lane lane-42 --project octo --key 43 --branch feat/42-x
check "start refuses a branch whose key differs" 2 "/#42/.test(o.error) && /#43/.test(o.error)"
named "start with a mismatched key makes no herdr call" not logged '.'

newcase; start_routes
run start --lane lane-42 --project octo --key 4 --branch feat/42-x
check "start compares the whole key, not a prefix" 2 "/#42/.test(o.error) && /#4\\b/.test(o.error)"

newcase; start_routes
run start --lane lane-42 --project octo --key 42 --branch main
check "start refuses a branch that fails git-conventions" 2 "/branch/.test(o.error)"

newcase; start_routes
run start --lane lane-42 --project octo --key 42 --branch 'feat/#42-x'
check "start refuses a branch carrying #42 instead of the bare number" 2 "/branch/.test(o.error) && /drop the/.test(o.error)"

for bad in '../x' 'ABC' '0' 'lt02' '42/../../x'; do
  newcase; start_routes
  run start --lane lane-42 --project octo --key "$bad" --branch feat/42-x
  check "start refuses --key '$bad'" 2 "/--key/.test(o.error) && /not a ticket key/.test(o.error)"
  named "start --key '$bad' makes no herdr call" not logged '.'
done

newcase; start_routes
run start --lane lane-42 --project nope --key 42 --branch feat/42-x
check "start refuses a project not in the config" 2 "/nope/.test(o.error)"

newcase; start_routes; mkdir -p "$WT"
run $START
check "start refuses an existing worktree path" 2 "/already exists/.test(o.error)"
named "start existing path makes no worktree create" not logged 'worktree.*create'

# --- start: happy path -------------------------------------------------------
newcase; start_routes
run $START
check "start prints the lane record" 0 \
  "o.lane === 'lane-42' && o.pane_id === 'w5:p1' && o.workspace_id === 'w5' && o.worktree === '$WT' && o.branch === 'feat/42-x' && /^[0-9a-f-]{36}\$/.test(o.session_id) && o.model === 'sonnet' && o.effort === 'medium'"
named "start creates the worktree off origin/main" logged '"worktree","create".*"--branch","feat/42-x".*"--base","origin/main".*"--path","'"$WT"'".*"--label","lane-42".*"--no-focus"'
named "start launches claude with the lane flags" logged '"agent","start","lane-42","--kind","claude","--pane","w5:p1","--","--permission-mode","auto","--settings",".*","--model","sonnet","--effort","medium","--session-id"'
named "start never bypasses permissions" not logged 'dangerously-skip-permissions'
named "start gives the lane its own deny rules for pushes to main and force pushes" lane_denies \
  'Bash(git push origin main*)' 'Bash(git push origin HEAD:main*)' 'Bash(git push --force*)' 'Bash(git push -f*)'
named "the lane deny rules catch a push to main with flags anywhere, a full ref, or a trailing redirect" lane_push deny \
  'git push origin main' 'git push -u origin main' 'git push origin HEAD:main' 'git push origin HEAD:refs/heads/main' \
  'git push -u origin main 2>&1'
named "the lane deny rules catch a force push in any position and a +refspec" lane_push deny \
  'git push --force origin feat/42-x' 'git push origin feat/42-x --force' 'git push -f origin feat/42-x' \
  'git push origin feat/42-x -f' 'git push --force-with-lease origin feat/42-x' 'git push origin +HEAD:feat/42-x'
named "the lane deny rules allow the lane's own branch push" lane_push allow \
  "git push -u origin 'feat/42-x'" 'git push -u origin feat/42-maintenance-fix' 'git push origin HEAD'
named "start without lane_compact_window adds no env to the lane settings" lane_env '!("env" in s)'
named "start prompts with --wait --until working" logged '"agent","prompt","lane-42","do the story","--wait","--until","working","--timeout","60000"'

newcase; start_routes; write_config "$CHECKOUT" ',"lane_compact_window":277778'
run $START
check "start with lane_compact_window still starts the lane" 0 "o.lane === 'lane-42'"
named "start puts lane_compact_window in the lane settings as a string" lane_env 'env.CLAUDE_CODE_AUTO_COMPACT_WINDOW === "277778"'
named "start keeps the lane deny rules beside the compact window" lane_denies 'Bash(git push origin main*)' 'Bash(git push -f*)'

for bad in 0 -5 1.5 '"277778"'; do
  newcase; start_routes; write_config "$CHECKOUT" ",\"lane_compact_window\":$bad"
  run $START
  check "start refuses lane_compact_window $bad" 2 "/lane_compact_window/.test(o.error) && /positive integer/.test(o.error)"
  named "start with lane_compact_window $bad creates no worktree" not logged '"worktree","create"'
done

newcase; start_routes
run $START --base origin/develop --model opus --effort high
check "start honours --base, --model and --effort" 0 "o.model === 'opus' && o.effort === 'high'"
named "start passes --base through" logged '"--base","origin/develop"'

newcase; start_routes; LANE_DEFAULTS='' write_config "$CHECKOUT"
run $START
check "start with no model or effort from flag or config reports neither" 0 "o.model === null && o.effort === null"
named "start with no model leaves --model off" not logged '"--model"'
named "start with no effort leaves --effort off" not logged '"--effort"'
named "start with neither still launches in auto mode with a session id" logged '"--permission-mode","auto","--settings",".*","--session-id"'

newcase; start_routes; LANE_DEFAULTS=',"lane_model":"sonnet"' write_config "$CHECKOUT"
run $START --effort xhigh
check "start takes the model from config and the effort from the flag" 0 "o.model === 'sonnet' && o.effort === 'xhigh'"
named "start passes the config model and the flag effort" logged '"--model","sonnet","--effort","xhigh","--session-id"'

newcase; start_routes; LANE_DEFAULTS='' write_config "$CHECKOUT"
run $START --model opus
check "start with only --model reports no effort" 0 "o.model === 'opus' && o.effort === null"
named "start with only --model passes it and leaves --effort off" logged '"--settings",".*","--model","opus","--session-id"'

# --- start: adopting an existing branch or worktree ---------------------------
newcase; start_routes
run $START
check "a new branch is created off the base and reports nothing adopted" 0 "o.adopted === null"

newcase; start_routes; g branch feat/42-x
run $START
check "a local branch without a worktree gets a new worktree on it" 0 "o.adopted === 'branch' && o.worktree === '$WT'"
named "a local branch is checked out with worktree create" logged '"worktree","create".*"--branch","feat/42-x"'

newcase; start_routes; g update-ref refs/remotes/origin/feat/42-x HEAD
run $START
check "a branch only on origin is adopted from origin" 0 "o.adopted === 'remote-branch'"
named "a branch only on origin bases the worktree on it, keeping its pushed work" logged '"--branch","feat/42-x","--base","origin/feat/42-x"'

newcase; start_routes; mkdir -p "$(dirname "$WT")"; g worktree add -q -b feat/42-x "$WT"; herdr_worktrees "$WT|"
run $START
check "a worktree already at the lane path on the branch is adopted" 0 \
  "o.adopted === 'worktree' && o.worktree === '$WT' && o.pane_id === 'w7:p1' && o.workspace_id === 'w7'"
named "an adopted worktree is opened in herdr, not created" logged '"worktree","open","--cwd","'"$CHECKOUT"'","--path","'"$WT"'","--label","lane-42","--no-focus"'
named "an adopted worktree makes no worktree create" not logged '"worktree","create"'
named "the adopted lane starts claude in the opened pane" logged '"agent","start","lane-42","--kind","claude","--pane","w7:p1"'

newcase; start_routes; mkdir -p "$(dirname "$WT")"; g worktree add -q -b feat/42-other "$WT"; herdr_worktrees "$WT|"
run $START
check "a worktree at the lane path on another branch is refused" 2 "/feat\/42-other/.test(o.error)"
named "a refused worktree makes no herdr open or create" not logged '"worktree","(open|create)"'

newcase; start_routes; mkdir -p "$(dirname "$WT")"; g worktree add -q -b feat/42-x "$WT"; herdr_worktrees "$WT|w3"
run $START
check "a worktree already open in herdr is refused, pointing at restart" 2 "/w3/.test(o.error) && /restart/.test(o.error)"
named "an open worktree is neither opened nor created" not logged '"worktree","(open|create)"'

OLD="$CASE/repos/elsewhere"
newcase; start_routes; OLD="$CASE/repos/elsewhere"; g worktree add -q -b feat/42-x "$OLD"; herdr_worktrees "$OLD|"
run $START
check "a clean worktree elsewhere on the branch is moved to the lane path and adopted" 0 \
  "o.adopted === 'moved' && o.moved_from === '$OLD' && o.worktree === '$WT' && o.pane_id === 'w7:p1'"
named "the moved worktree is at the lane path" test "$("$GIT" -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" = feat/42-x
named "the old worktree path is gone" not test -e "$OLD"
named "the moved worktree is opened in herdr" logged '"worktree","open","--cwd","'"$CHECKOUT"'","--path","'"$WT"'"'

newcase; start_routes; OLD="$CASE/repos/elsewhere"; g worktree add -q -b feat/42-x "$OLD"; echo x > "$OLD/dirty.txt"; herdr_worktrees "$OLD|"
run $START
check "a worktree elsewhere with uncommitted changes is refused, naming it" 2 "o.error.includes('$OLD') && /uncommitted/.test(o.error)"
named "a dirty worktree stays where it is" test -e "$OLD/dirty.txt"

newcase; start_routes; OLD="$CASE/repos/elsewhere"; g worktree add -q -b feat/42-x "$OLD"; herdr_worktrees "$OLD|w4"
run $START
check "a worktree elsewhere that is open in herdr is refused, naming the workspace" 2 "/w4/.test(o.error)"
named "an open worktree elsewhere stays where it is" test -d "$OLD"

newcase; start_routes; g checkout -q -b feat/42-x
run $START
check "a branch checked out in the main checkout is refused" 2 "/main checkout|checkout itself/.test(o.error)"

# --- start: the base a new branch is cut from ----------------------------------
# sdlc_base <branch> — the branch's recorded sdlc-base in the checkout, empty when unset
sdlc_base() { g config --get "branch.$1.sdlc-base"; }

newcase; start_routes
run $START
check "with no --base and no origin/HEAD the base falls back to origin/main" 0 "o.base === 'origin/main' && o.adopted === null"
named "the origin/main fallback records sdlc-base main" test "$(sdlc_base feat/42-x)" = main

newcase; start_routes; g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
run $START
check "with no --base the base is origin/HEAD's target" 0 "o.base === 'origin/trunk'"
named "the origin/HEAD base is what the worktree is cut from" logged '"worktree","create".*"--branch","feat/42-x","--base","origin/trunk"'
named "the origin/HEAD base is recorded as sdlc-base without origin/" test "$(sdlc_base feat/42-x)" = trunk

newcase; start_routes; g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
run $START --base origin/release/2.0
check "--base wins over origin/HEAD" 0 "o.base === 'origin/release/2.0'"
named "a --base release branch is recorded as sdlc-base release/2.0" test "$(sdlc_base feat/42-x)" = release/2.0

newcase; start_routes; g branch feat/42-x; g config branch.feat/42-x.sdlc-base release/1.0
run $START --base origin/develop
check "an adopted local branch reports no base" 0 "o.adopted === 'branch' && o.base === null"
named "an adopted branch keeps its own sdlc-base" test "$(sdlc_base feat/42-x)" = release/1.0

newcase; start_routes; g update-ref refs/remotes/origin/feat/42-x HEAD
run $START
check "a branch adopted from origin reports no base" 0 "o.adopted === 'remote-branch' && o.base === null"
named "a branch adopted from origin gets no sdlc-base written" test -z "$(sdlc_base feat/42-x)"

newcase; start_routes; mkdir -p "$(dirname "$WT")"; g worktree add -q -b feat/42-x "$WT"; herdr_worktrees "$WT|"
run $START
check "an adopted worktree reports no base" 0 "o.adopted === 'worktree' && o.base === null"
named "an adopted worktree gets no sdlc-base written" test -z "$(sdlc_base feat/42-x)"

for bad in 'origin/../x' '-x' 'a b' 'origin/main.lock' 'origin/' '.hidden' 'origin//main' 'origin/HEAD' 'HEAD' 'a;b'; do
  newcase; start_routes
  run $START --base "$bad"
  check "start refuses --base '$bad'" 2 "/--base/.test(o.error) && /plain ref/.test(o.error)"
  named "start --base '$bad' makes no herdr call" not logged '.'
done

# --- start: blocked gate -----------------------------------------------------
newcase; route "worktree list" "worktree-list-none.json"; route "worktree create" "worktree-created.json"; route "agent start" "ok.json"; route "agent prompt" "ERR:err-blocked.json"
run $START
check "start maps agent_blocked to the gate error" 2 "o.error === 'lane lane-42 is blocked at a gate; answer it before prompting'"
check "a start that fails after the worktree exists still reports the lane's ids" 2 \
  "o.lane === 'lane-42' && o.pane_id === 'w5:p1' && o.workspace_id === 'w5' && /\/42$/.test(o.worktree) && /^[0-9a-f-]{36}$/.test(o.session_id)"

newcase; route "worktree list" "worktree-list-none.json"; route "worktree create" "worktree-created.json"; route "agent start" "ERR:err-blocked.json"
run $START
check "an agent start failure (e.g. blocked during startup) reports the pane, worktree and the session id claude was given" 2 \
  "o.pane_id === 'w5:p1' && /\/42$/.test(o.worktree) && /^[0-9a-f-]{36}$/.test(o.session_id) && typeof o.error === 'string'"

# --- restart ------------------------------------------------------------------
RESTART="restart --lane lane-42"
newcase; route "agent get lane-42" "agent-working.json"
run $RESTART
check "restart refuses a working lane" 2 "/working/.test(o.error)"
named "restart working lane sends no /exit" not logged '/exit'

newcase; route "agent get lane-42" "agent-blocked.json"
run $RESTART
check "restart refuses a blocked lane" 2 "/blocked/.test(o.error)"

newcase; route "agent get lane-42" "ERR:err-not-found.json"
run $RESTART
check "restart of a gone lane without --pane asks for --pane" 2 "/gone/.test(o.error) && /--pane/.test(o.error)"
named "restart gone without --pane starts nothing" not logged '"agent","(start|prompt)"'

newcase; route "agent get lane-42" "ERR:err-not-found.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
run $RESTART --pane w9:p2
check "restart of a gone lane with --pane starts in that pane" 0 "o.pane_id === 'w9:p2' && o.pane_source === 'flag' && o.resumed === false"
named "restart gone + --pane starts claude in the given pane" logged '"agent","start","lane-42","--kind","claude","--pane","w9:p2","--"'
named "restart gone + --pane sends no /exit" not logged '/exit'
named "restart gone + --pane still prompts" logged '"agent","prompt","lane-42","do the story","--wait"'

newcase; route "agent get lane-42" "agent-unknown.json,ERR:err-not-found.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
run $RESTART
check "restart of a wedged (unknown) lane restarts it in its own pane" 0 "o.pane_id === 'w5:p1' && o.pane_source === 'agent'"
named "restart unknown sends /exit" logged '"agent","prompt","lane-42","/exit"\]'

newcase; route "agent get lane-42" "agent-idle.json,ERR:err-not-found.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
run $RESTART --resume 11111111-2222-3333-4444-555555555555
check "restart --resume reports the resumed session" 0 \
  "o.lane === 'lane-42' && o.pane_id === 'w5:p1' && o.session_id === '11111111-2222-3333-4444-555555555555' && o.resumed === true"
named "restart sends /exit without --wait" logged '"agent","prompt","lane-42","/exit"\]'
named "restart passes --resume to claude" logged '"agent","start","lane-42","--kind","claude","--pane","w5:p1","--".*"--resume","11111111-2222-3333-4444-555555555555"'
named "restart without --session-id when resuming" not logged '"--resume".*"--session-id"'

newcase; route "agent get lane-42" "ERR:err-not-found.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
write_config "$CHECKOUT" ',"lane_compact_window":277778'
run $RESTART --pane w9:p2
check "restart with lane_compact_window starts the lane" 0 "o.pane_id === 'w9:p2'"
named "restart puts lane_compact_window in the lane settings as a string" lane_env 'env.CLAUDE_CODE_AUTO_COMPACT_WINDOW === "277778"'
named "restart keeps auto mode and the lane deny rules" lane_denies 'Bash(git push origin main*)' 'Bash(git push --force*)'

newcase; route "agent get lane-42" "ERR:err-not-found.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
write_config "$CHECKOUT" ',"lane_compact_window":0'
run $RESTART --pane w9:p2
check "restart refuses lane_compact_window 0" 2 "/lane_compact_window/.test(o.error)"
named "restart with a bad lane_compact_window starts nothing" not logged '"agent","start"'

newcase; route "agent get lane-42" "agent-idle.json,ERR:err-not-found.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
run $RESTART --model opus --effort low
check "restart without --resume starts a fresh session id" 0 "o.resumed === false && /^[0-9a-f-]{36}\$/.test(o.session_id)"
named "restart passes a new --session-id" logged '"--model","opus","--effort","low","--session-id"'

newcase; route "agent get lane-42" "ERR:err-not-found.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
run $RESTART --pane w9:p2
check "restart without flags starts the lane" 0 "o.pane_id === 'w9:p2'"
named "restart without flags takes the config model and effort" logged '"--model","sonnet","--effort","medium","--session-id"'

newcase; route "agent get lane-42" "ERR:err-not-found.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
LANE_DEFAULTS='' write_config "$CHECKOUT"
run $RESTART --pane w9:p2
check "restart with no model or effort from flag or config starts the lane" 0 "o.pane_id === 'w9:p2'"
named "restart with no model or effort leaves --model and --effort off" not logged '"--(model|effort)"'

newcase; route "agent get lane-42" "ERR:err-not-found.json"; route "agent start" "ok.json"; route "agent prompt" "ERR:err-blocked.json"
run $RESTART --pane w9:p2
check "a restart whose prompt fails still reports the new session and its pane" 2 \
  "o.error === 'lane lane-42 is blocked at a gate; answer it before prompting' && o.pane_id === 'w9:p2' && o.pane_source === 'flag' && /^[0-9a-f-]{36}\$/.test(o.session_id) && o.resumed === false"

newcase; route "agent get lane-42" "ERR:err-not-found.json"; route "agent start" "ok.json"; route "agent prompt" "ERR:err-blocked.json"
run $RESTART --pane w9:p2 --resume 11111111-2222-3333-4444-555555555555
check "a resumed restart whose prompt fails reports the resumed session" 2 \
  "o.session_id === '11111111-2222-3333-4444-555555555555' && o.resumed === true && o.pane_id === 'w9:p2'"

newcase; route "agent get lane-42" "ERR:err-not-found.json"; route "agent start" "ERR:err-blocked.json"
run $RESTART --pane w9:p2
check "a restart whose agent start fails reports the session id claude was given" 2 \
  "typeof o.error === 'string' && o.pane_id === 'w9:p2' && /^[0-9a-f-]{36}\$/.test(o.session_id)"

newcase; route "agent get lane-42" "agent-idle.json"; route "agent prompt" "ok.json"; route "agent start" "ok.json"
run $RESTART
check "restart times out when the lane never exits" 2 "/exit/.test(o.error)"
named "restart timeout never starts claude again" not logged '"agent","start"'

newcase; route "agent get lane-42" "agent-idle.json"
STDIN='!x'
run $RESTART
check "restart refuses a ! prompt" 2 "/prompt/.test(o.error)"

# --- start: ticket keys -------------------------------------------------------
newcase; start_routes
run start --lane lane-42 --project octo --key '#42' --branch feat/42-x
check "start takes --key #42 the same as 42" 0 "o.worktree === '$WT'"

newcase; start_routes
run start --lane lane-lt02 --project octo --key LT-02 --branch feat/LT-02-live-tuner
check "a story-code lane's worktree is named by the story code" 0 \
  "o.lane === 'lane-lt02' && o.worktree === '$CASE/repos/.sdlc-worktrees/checkout/LT-02' && o.branch === 'feat/LT-02-live-tuner'"
named "the story-code worktree is created at that path" logged '"worktree","create".*"--branch","feat/LT-02-live-tuner".*"--path","'"$CASE"'/repos/.sdlc-worktrees/checkout/LT-02"'

newcase; start_routes
run start --lane lane-lt02 --project octo --key lt-02 --branch feat/LT-02-live-tuner
check "a lowercase story code is read as its uppercase form" 0 "o.worktree === '$CASE/repos/.sdlc-worktrees/checkout/LT-02'"

newcase; start_routes
run start --lane lane-lt02 --project octo --key LT-02 --branch feat/42-x
check "a story code against an issue branch is refused" 2 "/LT-02/.test(o.error) && /#42/.test(o.error)"

# --- close --------------------------------------------------------------------
CLOSE="close --lane lane-42 --project octo --key 42 --pr 7"
HEAD_SHA=dddd444444444444444444444444444444444444
PR_VIEW='^pr view 7 -R octo-org/octo-repo --json state,headRefOid$'
PR_COMMITS='^api repos/octo-org/octo-repo/pulls/7/commits --paginate --slurp$'
close_fixtures() { # <pr-state> <verdict> <class> [head sha]
  printf '{"state":"%s","headRefOid":"%s"}' "$1" "${4:-$HEAD_SHA}" > "$CASE/fx/pr.json"
  printf '{"verdict":"%s","class":"%s","reason":"because"}' "$2" "$3" > "$CASE/fx/verdict.json"
  groute "$PR_VIEW" "pr.json"
  groute "$PR_COMMITS" "pr-commits.json"
}
close_routes() { # <agent get replies> — herdr routes for a close that reaches removal
  route "agent get lane-42" "$1"; route "worktree list" "worktree-list.json"; route "worktree remove" "ok.json"; route "agent prompt" "ok.json"
  worktree_list w5
}
classified() { test -s "$CASE/fx/cleanup-calls.log"; }

newcase; mkdir -p "$WT"; close_fixtures OPEN keep pr-open; close_routes "agent-idle.json"
run $CLOSE
check "close keeps a lane whose PR is open" 0 "o.closed === false && o.verdict === 'keep' && o.class === 'pr-open' && o.reason === 'because'"
named "close keep sends no /exit" not logged '/exit'
named "close keep does not remove the worktree" not logged 'worktree","remove'
named "close classifies from the checkout with the PR facts" grep -qF \
  "[\"classify\",\"--repo\",\"$CHECKOUT\",\"--worktree\",\"$WT\",\"--pr-state\",\"OPEN\",\"--pr-ref\",\"#7\",\"--pr-head\",\"$HEAD_SHA\",\"--pr-commits\",\"aaaa111111111111111111111111111111111111,bbbb222222222222222222222222222222222222\"]" "$CASE/fx/cleanup-calls.log"
named "close reads the PR with gh pr view -R and its commits paginated" grep -qF \
  '["api","repos/octo-org/octo-repo/pulls/7/commits","--paginate","--slurp"]' "$CASE/fx/gh-calls.log"

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe; close_routes "agent-idle.json,ERR:err-not-found.json"
run $CLOSE
check "close of a safe worktree reports closed" 0 "o.closed === true && o.lane === 'lane-42' && o.worktree === '$WT'"
named "close passes gh's MERGED state as-is" grep -qF '"--pr-state","MERGED"' "$CASE/fx/cleanup-calls.log"
named "close safe sends /exit to the lane" logged '"agent","prompt","lane-42","/exit"\]'
named "close safe removes the workspace by id" logged '"worktree","remove","--workspace","w5"\]'

newcase; mkdir -p "$WT"; close_fixtures CLOSED keep not-landed; close_routes "agent-idle.json"
run $CLOSE
check "close keeps a closed-unmerged PR the classifier keeps" 0 "o.closed === false && o.class === 'not-landed'"
named "close passes gh's CLOSED state as-is" grep -qF '"--pr-state","CLOSED"' "$CASE/fx/cleanup-calls.log"

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe
route "agent get lane-42" "ERR:err-not-found.json"; route "worktree list" "worktree-list.json"; route "worktree remove" "ok.json"
worktree_list w5
run $CLOSE
check "close safe skips /exit when the lane is already gone" 0 "o.closed === true"
named "close with a gone lane sends no /exit" not logged '/exit'
named "close with a gone lane still removes the workspace" logged '"worktree","remove","--workspace","w5"'

newcase; close_fixtures MERGED safe safe
run $CLOSE
check "close with the worktree gone is already_gone" 0 "o.lane === 'lane-42' && o.closed === true && o.already_gone === true"
named "close already_gone makes no herdr call" not logged '.'
named "close already_gone reads no PR" not test -e "$CASE/fx/gh-calls.log"

newcase; mkdir -p "$CASE/repos/.sdlc-worktrees/checkout/LT-02"; close_fixtures MERGED safe safe
route "agent get lane-lt02" "ERR:err-not-found.json"; route "worktree list" "worktree-list.json"; route "worktree remove" "ok.json"
WT="$CASE/repos/.sdlc-worktrees/checkout/LT-02" worktree_list w6
run close --lane lane-lt02 --project octo --key LT-02 --pr 7
check "close finds a story-code lane's worktree by its code" 0 "o.closed === true && o.worktree === '$CASE/repos/.sdlc-worktrees/checkout/LT-02'"
named "close removes the story-code lane's workspace" logged '"worktree","remove","--workspace","w6"'

# --- close: the PR head is fetched when it is not local -----------------------
newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe "$(g rev-parse HEAD)"; close_routes "ERR:err-not-found.json"
run $CLOSE
check "close with the head already local closes" 0 "o.closed === true"
named "close with the head already local fetches nothing" not git_logged 'fetch'

newcase; mkdir -p "$WT"
"$GIT" init -q --bare "$CASE/origin.git"; g remote add origin "$CASE/origin.git"
"$GIT" init -q -b main "$CASE/other"
"$GIT" -C "$CASE/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'squashed away'
"$GIT" -C "$CASE/other" push -q "$CASE/origin.git" HEAD:refs/pull/7/head
REMOTE_HEAD="$("$GIT" -C "$CASE/other" rev-parse HEAD)"
close_fixtures MERGED safe safe "$REMOTE_HEAD"; close_routes "ERR:err-not-found.json"
named "the remote-only head is not in the checkout before close" not g cat-file -e "$REMOTE_HEAD^{commit}" 2>/dev/null
run $CLOSE
check "close with a remote-only head closes" 0 "o.closed === true"
named "close fetches refs/pull/<n>/head from origin" git_logged "fetch --quiet --no-tags origin refs/pull/7/head"
named "the fetched head is in the checkout for classify" g cat-file -e "$REMOTE_HEAD^{commit}"
named "close classifies with the fetched head" grep -qF "\"--pr-head\",\"$REMOTE_HEAD\"" "$CASE/fx/cleanup-calls.log"

newcase; mkdir -p "$WT"; close_fixtures MERGED keep head-unavailable; close_routes "agent-idle.json"
run $CLOSE
check "a failed head fetch is left to classify, which keeps the lane" 0 "o.closed === false && o.class === 'head-unavailable'"
named "the fetch was attempted" git_logged "fetch .*refs/pull/7/head"
named "a kept lane after a failed fetch is not exited" not logged '/exit'

# --- close: unreadable GitHub calls never close --------------------------------
for reply in EXIT:1 HTTP:404 RATE; do
  newcase; mkdir -p "$WT"; printf '{"verdict":"safe","class":"safe","reason":"x"}' > "$CASE/fx/verdict.json"
  groute "$PR_VIEW" "$reply"; groute "$PR_COMMITS" "pr-commits.json"; close_routes "agent-idle.json"
  run $CLOSE
  check "close with gh pr view failing ($reply) is an error" 2 "/gh pr view/.test(o.error) && !('closed' in o)"
  named "close with gh pr view failing ($reply) never classifies or touches herdr" not classified
  named "close with gh pr view failing ($reply) makes no herdr call" not logged '.'
done

newcase; mkdir -p "$WT"; printf '{"verdict":"safe","class":"safe","reason":"x"}' > "$CASE/fx/verdict.json"
groute "$PR_VIEW" "pr.json"; groute "$PR_COMMITS" "RATE"; printf '{"state":"MERGED","headRefOid":"%s"}' "$HEAD_SHA" > "$CASE/fx/pr.json"
close_routes "agent-idle.json"
run $CLOSE
check "close with the commit list rate-limited is an error naming it" 2 "/rate limit/.test(o.error)"
named "close with no commit list never classifies" not classified
named "close with no commit list makes no herdr call" not logged '.'

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe; printf '{"state":"MERGED"}' > "$CASE/fx/pr.json"; close_routes "agent-idle.json"
run $CLOSE
check "a PR reply without headRefOid is an error" 2 "/headRefOid/.test(o.error)"
named "a PR reply without headRefOid never classifies" not classified

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe; printf '{"message":"Not Found"}' > "$CASE/fx/pr-commits.json"; close_routes "agent-idle.json"
run $CLOSE
check "a commit list that is not a list of pages is an error" 2 "/did not return a list/.test(o.error)"
named "a malformed commit list never classifies" not classified

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe; printf '[[{"sha":"aaaa111111111111111111111111111111111111"},{"node_id":"x"}]]' > "$CASE/fx/pr-commits.json"; close_routes "agent-idle.json"
run $CLOSE
check "a commit without a sha is an error" 2 "/without a sha/.test(o.error)"

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe; printf 'not json' > "$CASE/fx/verdict.json"; close_routes "agent-idle.json"
run $CLOSE
check "a classifier that gives no verdict is an error" 2 "/worktree-cleanup\.js gave no verdict/.test(o.error)"
named "no verdict removes nothing" not logged 'worktree","remove'

# --- close: arguments ------------------------------------------------------------
for bad in '7/../8' '0' '-7' '#7'; do
  newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe
  run close --lane lane-42 --project octo --key 42 --pr "$bad"
  check "close refuses --pr '$bad'" 2 "/--pr/.test(o.error)"
  named "close --pr '$bad' calls no gh" not test -e "$CASE/fx/gh-calls.log"
done

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe
run close --lane lane-42 --project octo --key 42 --mr 7
check "close no longer takes --mr" 2 "/unknown option --mr/.test(o.error)"

newcase; mkdir -p "$CASE/repos/.sdlc-worktrees/x"; close_fixtures MERGED safe safe
run close --lane lane-42 --project octo --key '../x' --pr 7
check "close refuses a --key that is a path, not a ticket key" 2 "/--key/.test(o.error)"
named "close with a path --key calls no gh" not test -e "$CASE/fx/gh-calls.log"

newcase; start_routes; STDIN='--help me'
run $START
check "start refuses a prompt starting with - (herdr would read a flag)" 2 "/prompt/.test(o.error)"

newcase; start_routes; : > "$CASE/fx/herdr-routes"; route "worktree list" "worktree-list-none.json"; route "worktree create" "SLEEP:5"
s0=$SECONDS
# shellcheck disable=SC2086 # START is the subcommand's argument list
out="$(cd "$CASE" && printf '%s' "$STDIN" | env -i HOME="$CASE/home" PATH="$RUN_PATH" HERD_FIXTURES="$CASE/fx" \
  HERD_CONFIG="$CASE/home/.claude/herd/config.json" HERD_SDLC_ROOT="$CASE/sdlc" HERD_HERDR_TIMEOUT_MS=500 "$NODE" "$CLI" $START 2>/dev/null)"; code=$?
check "a hung herdr call times out into exit 2" 2 "/timed out/.test(o.error)"
named "the herdr timeout is bounded" test $((SECONDS - s0)) -lt 4

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe; : > "$CASE/fx/routes"; groute "$PR_VIEW" "SLEEP:10"
s0=$SECONDS
# shellcheck disable=SC2086 # CLOSE is the subcommand's argument list
out="$(cd "$CASE" && env -i HOME="$CASE/home" PATH="$RUN_PATH" HERD_FIXTURES="$CASE/fx" HERD_CONFIG="$CASE/home/.claude/herd/config.json" \
  HERD_SDLC_ROOT="$CASE/sdlc" HERD_GH_TIMEOUT_MS=500 "$NODE" "$CLI" $CLOSE 2>/dev/null)"; code=$?
check "a hung gh call times out into exit 2" 2 "/timed out/.test(o.error)"
named "the gh timeout is bounded" test $((SECONDS - s0)) -lt 4

newcase; mkdir -p "$WT"; close_fixtures MERGED safe safe
ln -s "$CASE/repos" "$CASE/alias"; write_config "$CASE/alias/checkout"
route "agent get lane-42" "ERR:err-not-found.json"; route "worktree list" "worktree-list.json"; route "worktree remove" "ok.json"
worktree_list w5
run $CLOSE
check "close matches herdr's real path when the checkout is reached through a symlink" 0 "o.closed === true"

# --- the whole suite ----------------------------------------------------------
# every herdr call from every case above was logged under $TMP; no argument may be --force
if grep -rlF -- '"--force"' "$TMP"/case*/fx/herdr-calls.log > /dev/null 2>&1; then fail "--force appeared in a herdr call"; else pass "--force never appears in any herdr call"; fi

echo
if [ "$fails" -eq 0 ]; then echo "All herd-lane tests passed"; exit 0; fi
echo "$fails herd-lane test(s) failed"; exit 1
