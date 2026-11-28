#!/usr/bin/env bash
# Fixture tests for herd-usage.js — token totals from a lane's Claude Code transcripts, subagents included.
# Transcripts are written into a temp HOME in the shape Claude Code 2.1 writes them:
#   ~/.claude/projects/<dir>/<session>.jsonl and ~/.claude/projects/<dir>/<session>/subagents/agent-*.jsonl
# No npm packages — bash + node only. Exit 0 = all cases pass, 1 = any fail.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../herd-usage.js"
NODE="$(command -v node)"
[ -n "$NODE" ] || { echo "FAIL: node not on PATH — cannot run herd-usage tests" >&2; exit 1; }
[ -f "$CLI" ] || { echo "FAIL: herd-usage.js not found at $CLI" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

S1=11111111-1111-4111-8111-111111111111
S2=22222222-2222-4222-8222-222222222222
PROJ=-home-u-repos--sdlc-worktrees-checkout-42

newcase() {
  CASE="$TMP/case$RANDOM$RANDOM"
  mkdir -p "$CASE/home/.claude/projects/$PROJ"
  CONFIG_DIR=""
}
# transcript <path relative to the project dir> — writes stdin there
transcript() { mkdir -p "$(dirname "$CASE/home/.claude/projects/$PROJ/$1")"; cat > "$CASE/home/.claude/projects/$PROJ/$1"; }
# asst <id> <model> <input> <cache_write> <cache_read> <output> — one assistant record as Claude Code writes it
asst() {
  printf '{"type":"assistant","sessionId":"x","message":{"id":"%s","model":"%s","role":"assistant","content":[{"type":"text","text":"t"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":0},"service_tier":"standard"}}}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$4"
}
user() { printf '{"type":"user","message":{"role":"user","content":"go"}}\n'; }

run() {
  out="$(env -i HOME="$CASE/home" PATH="$PATH" ${CONFIG_DIR:+CLAUDE_CONFIG_DIR="$CONFIG_DIR"} "$NODE" "$CLI" "$@" 2>/dev/null)"
  code=$?
}
# check "<name>" <expected exit> "<js boolean expression over o>"
check() {
  local name="$1" want="$2" expr="$3"
  if [ "$code" != "$want" ]; then fail "$name — exit $want, got $code: $out"; return; fi
  if printf '%s' "$out" | "$NODE" -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8')); process.exit(($expr)?0:1)" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — got: $out"
  fi
}

# --- one session: repeated message ids count once -----------------------------
newcase
{ user; asst m1 claude-opus-5-5 2 100 1000 10; asst m1 claude-opus-5-5 2 100 1000 10; user; asst m2 claude-opus-5-5 3 50 2000 20; } | transcript "$S1.jsonl"
run --session "$S1"
check "a message id written once per content block counts once" 0 "o.assistant_turns === 2"
check "totals sum input, cache write, cache read and output" 0 \
  "o.tokens.input === 5 && o.tokens.cache_write === 150 && o.tokens.cache_read === 3000 && o.tokens.output === 30"
check "by_model carries the same numbers for the one model" 0 \
  "Object.keys(o.by_model).join() === 'claude-opus-5-5' && o.by_model['claude-opus-5-5'].assistant_turns === 2 && o.by_model['claude-opus-5-5'].tokens.cache_read === 3000"
check "the result names the sessions and transcripts read" 0 "o.sessions.join() === '$S1' && o.transcripts === 1"
check "the result carries tokens only, no price" 0 "!/cost|price|usd/i.test(JSON.stringify(o))"

# --- subagent transcripts are included, by model ------------------------------
newcase
{ asst m1 claude-opus-5-5 1 10 100 5; } | transcript "$S1.jsonl"
{ asst s1 claude-sonnet-5-5 2 20 200 7; asst s1 claude-sonnet-5-5 2 20 200 7; } | transcript "$S1/subagents/agent-a1.jsonl"
{ asst s2 claude-opus-5-5 4 40 400 9; } | transcript "$S1/subagents/agent-a2.jsonl"
printf '{"agentType":"x"}' | transcript "$S1/subagents/agent-a1.meta.json"
{ asst t1 claude-opus-5-5 999 999 999 999; } | transcript "$S1/tool-results/blob.jsonl"
run --session "$S1"
check "subagent transcripts count toward the totals" 0 "o.assistant_turns === 3 && o.tokens.output === 21 && o.tokens.cache_read === 700"
check "subagent tokens split by model" 0 \
  "o.by_model['claude-sonnet-5-5'].tokens.output === 7 && o.by_model['claude-sonnet-5-5'].assistant_turns === 1 && o.by_model['claude-opus-5-5'].tokens.output === 14"
check "only the session and its subagents are read, not tool results or meta files" 0 "o.transcripts === 3"

# --- a message id seen in two files counts once --------------------------------
newcase
{ asst m1 claude-opus-5-5 1 10 100 5; } | transcript "$S1.jsonl"
{ asst m1 claude-opus-5-5 1 10 100 5; } | transcript "$S1/subagents/agent-a1.jsonl"
run --session "$S1"
check "a message id repeated across transcripts counts once" 0 "o.assistant_turns === 1 && o.tokens.output === 5"

# --- synthetic records and unreadable lines ------------------------------------
newcase
{ asst m1 claude-opus-5-5 1 10 100 5; asst syn '<synthetic>' 0 0 0 0; printf '{"type":"assistant","message":{"id":"m2","mod\n'; } | transcript "$S1.jsonl"
run --session "$S1"
check "a synthetic notice is not an assistant turn" 0 "o.assistant_turns === 1 && !('<synthetic>' in o.by_model)"
check "a partial line is skipped and counted" 0 "o.skipped_lines === 1"

# --- several sessions (a fresh restart) ---------------------------------------
newcase
{ asst m1 claude-sonnet-5-5 1 10 100 5; } | transcript "$S1.jsonl"
mkdir -p "$CASE/home/.claude/projects/-other-dir"
asst m2 claude-opus-5-5 2 20 200 6 > "$CASE/home/.claude/projects/-other-dir/$S2.jsonl"
run --session "$S1" --session "$S2"
check "sessions are summed wherever their project folder is" 0 \
  "o.assistant_turns === 2 && o.tokens.output === 11 && o.sessions.join() === '$S1,$S2' && o.transcripts === 2"

# --- CLAUDE_CONFIG_DIR moves the projects folder -------------------------------
newcase
CONFIG_DIR="$CASE/cfg"
mkdir -p "$CONFIG_DIR/projects/$PROJ"
asst m1 claude-opus-5-5 1 10 100 5 > "$CONFIG_DIR/projects/$PROJ/$S1.jsonl"
run --session "$S1"
check "CLAUDE_CONFIG_DIR is where the projects folder lives" 0 "o.tokens.output === 5"

# --- errors -------------------------------------------------------------------
newcase
run --session "$S1"
check "an unknown session is an error naming it" 2 "o.error.includes('$S1')"
run
check "--session is required" 2 "/--session/.test(o.error)"
run --session "../../etc/passwd"
check "a session that is not a uuid is refused" 2 "/uuid/.test(o.error)"
run --session "$S1" --bogus x
check "an unknown option is refused" 2 "/--bogus/.test(o.error)"

echo
if [ "$fails" -eq 0 ]; then echo "All herd-usage tests passed"; exit 0; fi
echo "$fails herd-usage test(s) failed"; exit 1
