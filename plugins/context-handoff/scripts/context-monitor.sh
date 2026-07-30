#!/usr/bin/env bash
# Context window usage monitor — fires on Stop events, warns at thresholds.
# Large windows (>=500K): 30% warn, every 2%, 40% hard handoff (quality ceiling ~300-400K)
# Small windows (<500K):  80% warn, every 2%, 90% hard handoff (compaction territory)
set -euo pipefail

command -v jq &>/dev/null || exit 0

# --- Hook input (one jq pass — process startup dominates cost on Windows) ---
# Capture via $() so the trailing CR/LF is stripped (native Windows jq emits CRLF,
# and `read` would otherwise leave a stray \r in the last field); then split on tab.
INPUT=$(cat)
FIELDS=$(printf '%s' "$INPUT" | jq -r '[.session_id // "", .transcript_path // "", .agent_id // ""] | @tsv' 2>/dev/null) || true
IFS=$'\t' read -r SESSION_ID TRANSCRIPT AGENT_ID <<< "$FIELDS" || true
[[ -z "$SESSION_ID" || -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# Skip subagent stops — they have their own context windows
[[ -n "$AGENT_ID" ]] && exit 0

# --- Config (thresholds set after context window detection) ---
WARN_INTERVAL=2

# --- State ---
STATE_DIR="${CLAUDE_PLUGIN_DATA:-/tmp/context-handoff}"
STATE_FILE="$STATE_DIR/monitor-$SESSION_ID.json"
mkdir -p "$STATE_DIR"

# --- Latest main-agent assistant message: token TOTAL + model in ONE jq pass ---
# Filter out isSidechain entries (subagents/teams have separate context windows).
# tail -500 is instant (seek-based) regardless of file size; covers long subagent chains.
# jq sums the usage fields itself and emits "<total>\t<model>" so we spawn ONE jq, not
# one-per-field. On Windows jq's process startup dwarfs the parse, so spawn COUNT — not
# parse work — is what blew past the old 5s timeout on ~15% of Stop events.
USAGE_LINE=$(tail -500 "$TRANSCRIPT" | jq -r '
    select(.type == "assistant" and .message.usage and (.isSidechain | not))
    | [ (.message.usage
          | (.input_tokens // 0) + (.output_tokens // 0)
            + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)),
        (.message.model // "") ]
    | @tsv' 2>/dev/null | tail -1) || true
IFS=$'\t' read -r TOTAL JSONL_MODEL <<< "$USAGE_LINE" || true

# --- Auto-detect context window size ---
# Priority: env var > settings.json model suffix [1m] > model family > default 1M
if [[ -n "${CONTEXT_HANDOFF_WINDOW_SIZE:-}" ]]; then
  CTX_WINDOW=$CONTEXT_HANDOFF_WINDOW_SIZE
else
  SETTINGS_MODEL=$(jq -r '.model // empty' ~/.claude/settings.json 2>/dev/null) || true
  if [[ "$SETTINGS_MODEL" == *"[1m]"* ]]; then
    CTX_WINDOW=1000000
  else
    # JSONL_MODEL already extracted from the transcript in the pass above
    case "$JSONL_MODEL" in
      claude-opus-*|claude-sonnet-*) CTX_WINDOW=1000000 ;;
      claude-haiku-*)                CTX_WINDOW=200000 ;;
      *)                             CTX_WINDOW=1000000 ;;
    esac
  fi
fi

# Thresholds scale with window size: quality degrades around 300-400K regardless,
# so large windows warn early; small windows warn near compaction.
if [[ $CTX_WINDOW -ge 500000 ]]; then
  WARN_START=30
  HARD_HANDOFF=40
else
  WARN_START=80
  HARD_HANDOFF=90
fi

[[ -z "$TOTAL" || "$TOTAL" == "null" || "$TOTAL" -eq 0 ]] && exit 0

PCT=$((TOTAL * 100 / CTX_WINDOW))

# --- Load previous state (parse our own tiny file in-shell, no jq spawn) ---
LAST=0
if [[ -f "$STATE_FILE" ]]; then
  _state=$(<"$STATE_FILE")
  [[ "$_state" =~ \"last\":([0-9]+) ]] && LAST=${BASH_REMATCH[1]}
fi

# Reset if context shrunk significantly (compaction)
[[ $PCT -lt $((LAST - 5)) ]] && LAST=0

# --- Below threshold ---
if [[ $PCT -lt $WARN_START ]]; then
  printf '{"last":%d,"pct":%d}' "$LAST" "$PCT" > "$STATE_FILE"
  exit 0
fi

# --- Warning bucket (2% intervals from 30%) ---
BUCKET=$(( (PCT - WARN_START) / WARN_INTERVAL * WARN_INTERVAL + WARN_START ))

# --- Check for hard handoff crossing (45% doesn't land on 2% grid) ---
CROSSED_HARD=false
[[ $PCT -ge $HARD_HANDOFF && $LAST -lt $HARD_HANDOFF ]] && CROSSED_HARD=true

# --- Decide warning ---
MSG=""

if [[ "$CROSSED_HARD" == "true" ]]; then
  MSG="🚨 CONTEXT CRITICAL — ${PCT}% used (~${TOTAL}/${CTX_WINDOW} tokens). HARD HANDOFF REQUESTED. Complete your current thought, inform the user context is critically high, and run /handoff-context. Do not start new work — quality and reliability degrade beyond this point."
  printf '{"last":%d,"pct":%d}' "$HARD_HANDOFF" "$PCT" > "$STATE_FILE"

elif [[ $BUCKET -gt $LAST ]]; then
  if [[ $PCT -ge $HARD_HANDOFF ]]; then
    MSG="🚨 CONTEXT CRITICAL — ${PCT}% used (~${TOTAL}/${CTX_WINDOW} tokens). Past hard handoff threshold. Run /handoff-context NOW."
  elif [[ $PCT -ge $(( HARD_HANDOFF - (HARD_HANDOFF - WARN_START) / 2 )) ]]; then
    MSG="⚠️ CONTEXT HIGH — ${PCT}% used (~${TOTAL}/${CTX_WINDOW} tokens). Hard handoff at ${HARD_HANDOFF}%. Wrap up current work and prepare to run /handoff-context."
  elif [[ $LAST -lt $WARN_START ]]; then
    MSG="📊 CONTEXT MONITOR — ${PCT}% used (~${TOTAL}/${CTX_WINDOW} tokens). First warning threshold reached — start noting natural handoff points for long tasks."
  else
    MSG="📊 CONTEXT MONITOR — ${PCT}% used (~${TOTAL}/${CTX_WINDOW} tokens). Consider /compact for focused tasks or plan for /handoff-context."
  fi
  printf '{"last":%d,"pct":%d}' "$BUCKET" "$PCT" > "$STATE_FILE"

else
  printf '{"last":%d,"pct":%d}' "$LAST" "$PCT" > "$STATE_FILE"
  exit 0
fi

jq -n --arg m "$MSG" '{"continue":true,"systemMessage":$m}'
