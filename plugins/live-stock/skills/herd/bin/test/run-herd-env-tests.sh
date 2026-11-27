#!/usr/bin/env bash
# Fixture tests for herd-env.js check and lib/sdlc-root.js — sdlc root resolution, sdlc script presence,
# tools, HERDR_ENV, GitHub login, run_dir and config validation.
# gh is stub-gh.js; HOME, PATH and the config path point into a temp dir. No network, no live herdr.
# No npm packages — bash + node only. Exit 0 = all cases pass, 1 = any fail.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../herd-env.js"
NODE="$(command -v node)"
GIT="$(command -v git)"
[ -n "$NODE" ] || { echo "FAIL: node not on PATH — cannot run herd-env tests" >&2; exit 1; }
[ -f "$CLI" ] || { echo "FAIL: herd-env.js not found at $CLI" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# fake_sdlc <dir> <name> <version> <script-relpath>... — a plugin root holding empty sdlc scripts
fake_sdlc() {
  local dir="$1" name="$2" version="$3"; shift 3
  mkdir -p "$dir/.claude-plugin"
  printf '{"name":"%s","version":"%s"}' "$name" "$version" > "$dir/.claude-plugin/plugin.json"
  for s in "$@"; do mkdir -p "$dir/$(dirname "$s")"; : > "$dir/$s"; done
}
ALL_SCRIPTS="bin/pr-checks.js bin/git-conventions.js skills/copilot-review/bin/copilot-review.js skills/plan/bin/publish-body.js skills/review/bin/review-file.js skills/review/bin/worktree-cleanup.js"

# newcase — fresh HOME, fixtures, bin dir with stub gh and herdr, a valid config, sdlc via HERD_SDLC_ROOT
newcase() {
  CASE="$TMP/case$RANDOM$RANDOM"
  mkdir -p "$CASE/home/.claude/herd" "$CASE/bin" "$CASE/fx" "$CASE/state" "$CASE/checkout"
  ln -s "$HERE/stub-gh.js" "$CASE/bin/gh"
  ln -s "$HERE/stub-herdr.js" "$CASE/bin/herdr"
  ln -s "$NODE" "$CASE/bin/node"
  ln -s "$GIT" "$CASE/bin/git"
  printf '{"login":"octocat","id":1}' > "$CASE/fx/user.json"
  printf '^api user$\tuser.json\n' > "$CASE/fx/routes"
  # shellcheck disable=SC2086 # ALL_SCRIPTS is a list of relative paths
  fake_sdlc "$CASE/sdlc" sdlc 9.9.9 $ALL_SCRIPTS
  CONFIG="$CASE/home/.claude/herd/config.json"
  write_config "$CASE/checkout" pr-only
  unset CLAUDE_PLUGIN_ROOT
  SDLC_ENV="HERD_SDLC_ROOT=$CASE/sdlc"
  HERDR_ENV_VAL=1
  RUN_PATH="$CASE/bin"
}
# write_config <checkout> <main_push> [extra defaults JSON] — REPO and MERGE override the project's repo and merge_method;
# PROJ_EXTRA adds project keys (e.g. ,"main_ci":false)
write_config() {
  cat > "$CONFIG" <<JSON
{"projects":{"octo":{"repo":"${REPO:-octo-org/octo-repo}","checkout":"$1","main_push":"$2","merge_method":"${MERGE:-squash}"${PROJ_EXTRA:-}}},
 "review_request_authors":["hubot"],
 "defaults":{"max_lanes":3,"lane_model":"opus","lane_effort":"high"${3:-}}}
JSON
}
# run [args...] — sets $out and $code
run() {
  # shellcheck disable=SC2086 # SDLC_ENV is a list of VAR=value words
  out="$(cd "$CASE" && env -i HOME="$CASE/home" PATH="$RUN_PATH" HERD_FIXTURES="$CASE/fx" HERDR_ENV="$HERDR_ENV_VAL" \
    HERD_STATE_DIR="$CASE/state" HERD_GH_TIMEOUT_MS=2000 $SDLC_ENV "$NODE" "$CLI" check "$@" 2>/dev/null)"
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

# --- sdlc root resolution ---------------------------------------------------
newcase
run
check "HERD_SDLC_ROOT resolves sdlc with its version" 0 \
  "o.sdlc.root === '$CASE/sdlc' && o.sdlc.source === 'HERD_SDLC_ROOT' && o.sdlc.version === '9.9.9'"

newcase; fake_sdlc "$CASE/plugroot" sdlc 1.2.3
SDLC_ENV="CLAUDE_PLUGIN_ROOT=$CASE/plugroot HERD_SDLC_ROOT=$CASE/sdlc"
run
check "CLAUDE_PLUGIN_ROOT wins over HERD_SDLC_ROOT" 0 "o.sdlc.root === '$CASE/plugroot' && o.sdlc.source === 'CLAUDE_PLUGIN_ROOT'"

newcase; fake_sdlc "$CASE/other" not-sdlc 1.0.0
SDLC_ENV="CLAUDE_PLUGIN_ROOT=$CASE/other HERD_SDLC_ROOT=$CASE/sdlc"
run
check "a CLAUDE_PLUGIN_ROOT that is not sdlc is skipped" 0 "o.sdlc.source === 'HERD_SDLC_ROOT'"

newcase; mkdir -p "$CASE/home/.claude/plugins"
printf '{"plugins":{"sdlc@lafollett-labs-claude-plugins":[{"scope":"user","installPath":"%s","version":"9.9.9"}]}}' "$CASE/sdlc" \
  > "$CASE/home/.claude/plugins/installed_plugins.json"
SDLC_ENV=""
run
check "installed_plugins.json is the last fallback" 0 "o.sdlc.root === '$CASE/sdlc' && o.sdlc.source === 'installed_plugins'"

newcase; mkdir -p "$CASE/home/.claude/plugins"
printf '{"plugins":{"sdlc@another-marketplace":[{"scope":"user","installPath":"%s","version":"9.9.9"}]}}' "$CASE/sdlc" \
  > "$CASE/home/.claude/plugins/installed_plugins.json"
SDLC_ENV=""
run
check "an sdlc install from another marketplace is accepted" 0 "o.sdlc.root === '$CASE/sdlc' && o.sdlc.source === 'installed_plugins'"

newcase; mkdir -p "$CASE/home/.claude/plugins"; fake_sdlc "$CASE/other-sdlc" sdlc 1.0.0
printf '{"plugins":{"sdlc@another-marketplace":[{"installPath":"%s"}],"sdlc@lafollett-labs-claude-plugins":[{"installPath":"%s"}]}}' \
  "$CASE/other-sdlc" "$CASE/sdlc" > "$CASE/home/.claude/plugins/installed_plugins.json"
SDLC_ENV=""
run
check "sdlc@lafollett-labs-claude-plugins wins over another marketplace's sdlc" 0 "o.sdlc.root === '$CASE/sdlc'"

newcase; mkdir -p "$CASE/home/.claude/plugins"
printf '{"plugins":{"sdlc-extras@another-marketplace":[{"installPath":"%s"}]}}' "$CASE/sdlc" \
  > "$CASE/home/.claude/plugins/installed_plugins.json"
SDLC_ENV=""
run
check "a plugin merely named like sdlc is not accepted" 0 "o.sdlc.root === null"

newcase; SDLC_ENV=""
run
check "no sdlc anywhere is an error, not a crash" 0 "o.sdlc.root === null && o.errors.some((e) => /sdlc/.test(e))"

# --- sdlc scripts -------------------------------------------------------------
newcase
run
check "every sdlc script found is reported with its path" 0 \
  "Object.keys(o.sdlc_scripts).length === 6 && o.sdlc_scripts['pr-checks.js'] === '$CASE/sdlc/bin/pr-checks.js' && o.sdlc_scripts['copilot-review.js'] === '$CASE/sdlc/skills/copilot-review/bin/copilot-review.js' && o.sdlc_scripts['worktree-cleanup.js'] === '$CASE/sdlc/skills/review/bin/worktree-cleanup.js'"
check "no GitLab or Duo script is asked for" 0 "!('mr-pipeline.js' in o.sdlc_scripts) && !('duo-review.js' in o.sdlc_scripts)"

newcase; rm "$CASE/sdlc/skills/copilot-review/bin/copilot-review.js"
run
check "a missing sdlc script is null and an error" 0 "o.sdlc_scripts['copilot-review.js'] === null && o.errors.some((e) => /copilot-review\.js/.test(e))"

# --- tools and HERDR_ENV ------------------------------------------------------
newcase
run
check "gh, git, herdr and node are the tools, all present" 0 \
  "Object.keys(o.tools).sort().join() === 'gh,git,herdr,node' && Object.values(o.tools).every(Boolean) && o.errors.length === 0"

newcase; rm "$CASE/bin/git"
run
check "an absent tool is reported absent and is an error" 0 "o.tools.git === false && o.tools.gh === true && o.errors.some((e) => /git not on PATH/.test(e))"

newcase; rm "$CASE/bin/gh"
run
check "no gh is an error and no login is looked up" 0 \
  "o.tools.gh === false && o.github_login === null && o.errors.some((e) => /gh not on PATH/.test(e)) && !require('fs').existsSync('$CASE/fx/gh-calls.log')"

newcase; HERDR_ENV_VAL=""
run
check "HERDR_ENV unset is reported and is an error" 0 "o.herdr_env === false && o.errors.some((e) => /HERDR_ENV/.test(e))"

# --- GitHub login --------------------------------------------------------------
newcase
run
check "the GitHub login comes from gh api user" 0 "o.github_login === 'octocat'"
check "the report has no GitLab user field" 0 "!('gitlab_user' in o)"

newcase; printf '^api user$\tEXIT:1\n' > "$CASE/fx/routes"
run
check "a gh failure leaves github_login null with an error" 0 "o.github_login === null && o.errors.some((e) => /gh api user/.test(e))"

newcase; printf '^api user$\tHTTP:401\n' > "$CASE/fx/routes"
run
check "an unauthenticated gh (HTTP 401) is an error" 0 "o.github_login === null && o.errors.some((e) => /401/.test(e))"

newcase; printf '^api user$\tRATE\n' > "$CASE/fx/routes"
run
check "a rate-limited gh api user is an error naming the rate limit" 0 "o.github_login === null && o.errors.some((e) => /rate limit/.test(e))"

newcase; printf '{"id":1}' > "$CASE/fx/user.json"
run
check "a user reply with no login is an error, not a null login passed off as fine" 0 \
  "o.github_login === null && o.errors.some((e) => /no login/.test(e))"

newcase; printf '^api user$\tSLEEP:10\n' > "$CASE/fx/routes"
start=$SECONDS; run
[ $((SECONDS - start)) -lt 8 ] || fail "gh timeout is bounded by HERD_GH_TIMEOUT_MS"
check "a hung gh times out into an error" 0 "o.github_login === null && o.errors.some((e) => /timed out/.test(e))"

# --- run_dir --------------------------------------------------------------------
newcase; : > "$CASE/my-work-plan.md"
run --plan "$CASE/my-work-plan.md"
check "run_dir is the state dir plus the plan's name" 0 "o.run_dir === '$CASE/state/my-work-plan'"

newcase
run
check "run_dir is null without --plan" 0 "o.run_dir === null"

newcase
run --plan "$CASE/absent.md"
check "a missing --plan file is an error" 0 "o.errors.some((e) => /absent\.md/.test(e))"

# --- config ---------------------------------------------------------------------
newcase
run
check "a valid config has no config errors" 0 "o.config.path === '$CONFIG' && o.config.errors.length === 0 && o.errors.length === 0"

newcase; write_config "$CASE/checkout" direct
run
check "main_push direct is valid" 0 "o.config.errors.length === 0"

newcase; rm "$CONFIG"
run
check "a missing config is a config error" 0 "o.config.errors.some((e) => /not found/.test(e))"

for bad in sideways direct-ci-skip mr-only; do
  newcase; write_config "$CASE/checkout" "$bad"
  run
  check "main_push $bad is a config error naming the project" 0 "o.config.errors.some((e) => /octo/.test(e) && /main_push/.test(e))"
done

for bad in octo-repo 'octo-org/octo repo' 'a/b/c'; do
  newcase; REPO="$bad" write_config "$CASE/checkout" pr-only
  run
  check "repo '$bad' is a config error" 0 "o.config.errors.some((e) => /octo/.test(e) && /repo must be owner\/name/.test(e))"
done

newcase; MERGE=fast-forward write_config "$CASE/checkout" pr-only
run
check "an unknown merge_method is a config error" 0 "o.config.errors.some((e) => /merge_method/.test(e))"

for m in merge rebase; do
  newcase; MERGE=$m write_config "$CASE/checkout" pr-only
  run
  check "merge_method $m is valid" 0 "o.config.errors.length === 0"
done

newcase; PROJ_EXTRA=',"main_ci":"yes"' write_config "$CASE/checkout" pr-only
run
check "main_ci \"yes\" is a config error naming the project" 0 "o.config.errors.some((e) => /octo/.test(e) && /main_ci must be true or false/.test(e))"

for ok in false true; do
  newcase; PROJ_EXTRA=",\"main_ci\":$ok" write_config "$CASE/checkout" pr-only
  run
  check "main_ci $ok is accepted" 0 "o.config.errors.length === 0"
done

newcase; write_config "$CASE/nowhere" pr-only
run
check "a checkout that does not exist is a config error" 0 "o.config.errors.some((e) => /checkout/.test(e))"

newcase; printf '{not json' > "$CONFIG"
run
check "unparseable config is a config error" 0 "o.config.errors.some((e) => /JSON/.test(e))"

newcase; write_config "$CASE/checkout" pr-only ',"lane_compact_window":277778'
run
check "a positive integer lane_compact_window is valid" 0 "o.config.errors.length === 0"

for bad in 0 -1 2.5 '"277778"' null; do
  newcase; write_config "$CASE/checkout" pr-only ",\"lane_compact_window\":$bad"
  run
  check "lane_compact_window $bad is a config error" 0 "o.config.errors.some((e) => /defaults\.lane_compact_window must be a positive integer/.test(e))"
done

newcase
out="$(cd "$CASE" && env -i HOME="$CASE/home" PATH="$RUN_PATH" HERD_FIXTURES="$CASE/fx" "$NODE" "$CLI" bogus 2>/dev/null)"; code=$?
check "an unknown command is a usage error" 2 "/usage/.test(o.error)"

newcase
run --bogus x
check "an unknown option is a usage error" 2 "/--bogus/.test(o.error)"

echo
if [ "$fails" -eq 0 ]; then echo "All herd-env tests passed"; exit 0; fi
echo "$fails herd-env test(s) failed"; exit 1
