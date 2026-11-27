#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted patterns and seeded lines are literal on purpose
# Structure and terminology guards for the sdlc skills: body size, reference TOCs and depth, ticket-history
# narration, one term per concept, and trigger phrases. Each check runs against a plugin root, so the
# mutation cases at the bottom can prove a guard actually fires.
# Usage: run-skill-structure-tests.sh [plugin-root]   (default: this plugin)
# SDLC_TEST_TMP=<dir> keeps the mutation copies there instead of a self-cleaning mktemp dir.
# No npm packages: bash, grep and awk only. Exit 0 = all cases pass, 1 = any fail.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="${1:-$(cd "$HERE/../.." && pwd)}"

fails=0
total=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }

SKILLS="review pull-request deliver implement plan copilot-review"
# Skills checked for ticket history (review is out: its finding ids, e.g. CRITICAL-001, look like keys).
HISTORY_SKILLS="pull-request deliver implement plan copilot-review"
# Example keys and standard terms the docs may use; anything else matching <PROJECT>-<n> is ticket history.
EXAMPLE_KEYS='^(LT-[0-9]+|ABC-123|ABC-1234|TICKET-123|UTF-8|SHA-[0-9]+|ISO-[0-9]+)$'
# Example issue numbers; any other #NN (2+ digits) is ticket history.
EXAMPLE_ISSUES=':#(42|57|123|1234)$'

# Markdown the model reads as instructions (READMEs and fixtures excluded).
instruction_docs() {
  find "$1/skills" "$1/references" "$1/assets" -type f -name '*.md' \
    -not -path '*/bin/test/fixtures/*' -not -name 'README.md' 2>/dev/null | sort
}

# issue_refs <file> — ":#<n>" for each issue number of two or more digits; a # glued to a word, an entity
# (&#8212;) or a hex colour (#5319e7) is not one. Same rule as run-pe-agent-tests.sh.
issue_refs() { tr -c '[:alnum:]#&' '\n' < "$1" | grep -E '^#[0-9]{2,}$' | sed 's|^|:|'; }

# strip_frontmatter <file> — the body without the leading --- … --- block
strip_frontmatter() { awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$1"; }

check_body_size() {  # <root> → violations on stdout
  local s f n
  for s in $SKILLS; do
    f="$1/skills/$s/SKILL.md"; [ -f "$f" ] || continue
    n=$(strip_frontmatter "$f" | wc -l)
    [ "$n" -lt 500 ] || echo "$s SKILL.md body is $n lines (limit 499)"
  done
}

check_reference_tocs() {
  local s f
  for s in $SKILLS; do
    for f in "$1/skills/$s/references/"*.md; do
      [ -f "$f" ] || continue
      if [ "$(wc -l < "$f")" -gt 100 ] && ! grep -q '^## Contents' "$f"; then
        echo "${f#"$1"/} is over 100 lines with no ## Contents"
      fi
    done
  done
}

check_reference_depth() {  # a skill reference never loads another reference (the skill's own or the shared ones)
  local s f
  for s in $SKILLS; do
    for f in "$1/skills/$s/references/"*.md; do
      [ -f "$f" ] || continue
      grep -niE "(read|load)s? [^ ]*(skills/[a-z-]+/)?references/[a-z0-9-]+\.md|\]\((\./)?[a-z0-9-]+\.md\)" "$f" | sed "s|^|${f#"$1"/}:|"
    done
  done
}

check_ticket_history() {
  local s f k
  for s in $HISTORY_SKILLS; do
    for f in "$1/skills/$s/SKILL.md" "$1/skills/$s/references/"*.md; do
      [ -f "$f" ] || continue
      grep -nE '[Ss]tory [0-9]+|IMPLEMENTED' "$f" | sed "s|^|${f#"$1"/}:|"
      issue_refs "$f" | grep -vE "$EXAMPLE_ISSUES" | sed "s|^|${f#"$1"/}:|"
      for k in $(tr -c '[:alnum:]_-' '\n' < "$f" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+(-|$)' | sed 's/-$//' | sort -u); do
        [[ "$k" =~ $EXAMPLE_KEYS ]] || echo "${f#"$1"/} names ticket $k"
      done
    done
  done
}

check_terms() {  # one term each: ticket_key (not issue_key / TICKET-ID), "Gate 1", "code review" as a noun only in literals
  local f
  while IFS= read -r f; do
    strip_frontmatter "$f" | grep -nE '(^|[^[:alnum:]_])(ac_)?issue_key([^[:alnum:]_]|$)|Gate-[12]([^[:alnum:]_]|$)|TICKET-ID' | sed "s|^|${f#"$1"/}:|"
    # spaced "code review" (singular) outside backtick literals such as the `Code Review` status name
    strip_frontmatter "$f" | grep -nE '[Cc]ode [Rr]eview([^s]|$)' | grep -vF '`Code Review`' | sed "s|^|${f#"$1"/}:|"
  done < <(instruction_docs "$1")
}

check_triggers() {
  local root="$1" s want desc miss="" wants
  for s in pull-request deliver implement plan copilot-review; do
    desc="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm' "$root/skills/$s/SKILL.md")"
    grep -qxF "name: $s" <<<"$desc" || miss="$miss $s:name"
    case "$s" in
      pull-request)   wants=('"Open the PR"' '"Ship this branch"' '"/sdlc:pull-request"' '"Nudge PR #N"' 'invoked by sdlc:deliver') ;;
      deliver)        wants=('"Deliver this issue"' '"Take #42 end-to-end"' '"/sdlc:deliver"') ;;
      implement)      wants=('"Implement #42"' '"Start work on #42"' '"/sdlc:implement"' 'invoked by sdlc:deliver') ;;
      plan)           wants=('"create epic"' '"create story"' '"import epic"' '"update issue from markdown"' '"/sdlc:plan"') ;;
      copilot-review) wants=('"run a Copilot review"' '"/sdlc:copilot-review"') ;;
    esac
    for want in "${wants[@]}"; do grep -qF -- "$want" <<<"$desc" || miss="$miss $s:$want"; done
  done
  [ -z "$miss" ] || echo "lost trigger phrases:$miss"
}

run_check() {  # run_check <name> <fn> <root>
  local out; out="$("$2" "$3")"
  # shellcheck disable=SC2001
  if [ -z "$out" ]; then pass "$1"; else fail "$1"$'\n'"$(sed 's/^/    /' <<<"$out" | head -20)"; fi
}

run_check "SKILL.md bodies are under 500 lines" check_body_size "$PLUGIN"
run_check "references over 100 lines open with ## Contents" check_reference_tocs "$PLUGIN"
run_check "references are one level deep" check_reference_depth "$PLUGIN"
run_check "pull-request, deliver, implement, plan and copilot-review carry no ticket history" check_ticket_history "$PLUGIN"
run_check "sdlc instructions use one term per concept" check_terms "$PLUGIN"
run_check "pull-request, deliver, implement, plan and copilot-review keep their trigger phrases" check_triggers "$PLUGIN"

# --- mutation cases: each guard fires on a seeded violation (default plugin root only) ----------------
if [ $# -eq 0 ]; then
  if [ -n "${SDLC_TEST_TMP:-}" ]; then
    TMP="$(mktemp -d "$SDLC_TEST_TMP/skill-structure.XXXX")"
  else
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  fi
  SN=0
  seed() {  # a fresh copy of the plugin's docs at $P
    SN=$((SN + 1)); P="$TMP/p$SN"; mkdir -p "$P"; cp -R "$PLUGIN/skills" "$PLUGIN/references" "$PLUGIN/assets" "$P/"
  }
  fires() {  # fires <name> <fn>
    if [ -n "$("$2" "$P")" ]; then pass "guard fires: $1"; else fail "guard silent: $1"; fi
  }
  silent() {  # silent <name> <fn>
    if [ -z "$("$2" "$P")" ]; then pass "guard silent: $1"; else fail "guard fires: $1"; fi
  }
  seed; yes 'filler' | head -520 >> "$P/skills/deliver/SKILL.md";             fires "oversized body" check_body_size
  seed; yes 'filler' | head -120 > "$P/skills/deliver/references/big.md";      fires "reference without TOC" check_reference_tocs
  seed; echo 'see [x](resume-menus.md)' >> "$P/skills/deliver/references/override.md"; fires "reference links a reference" check_reference_depth
  seed; echo 'read ${CLAUDE_PLUGIN_ROOT}/references/settings.md' >> "$P/skills/pull-request/references/nudge.md"; fires "reference loads a shared reference" check_reference_depth
  seed; echo 'Since ABC-9999 this changed.' >> "$P/skills/pull-request/SKILL.md"; fires "ticket history" check_ticket_history
  seed; echo 'Fixed in XY-77.' >> "$P/skills/copilot-review/SKILL.md";         fires "copilot-review ticket history" check_ticket_history
  seed; echo 'Implement LT-02 next.' >> "$P/skills/implement/SKILL.md";         silent "story code example LT-02" check_ticket_history
  seed; echo 'session.issue_key = x' >> "$P/skills/plan/SKILL.md";              fires "issue_key term" check_terms
  seed; echo 'needs a Gate-1 lock' >> "$P/references/settings.md";              fires "Gate-1 term" check_terms
  seed; echo 'after the code review ends' >> "$P/assets/slack-templates.md";    fires "spaced code review" check_terms
  seed; sed -i.bak 's/"Ship this branch"//' "$P/skills/pull-request/SKILL.md"; fires "lost trigger" check_triggers
  seed; sed -i.bak 's#"/sdlc:copilot-review"#"/copilot"#' "$P/skills/copilot-review/SKILL.md"; fires "lost copilot-review trigger" check_triggers
  seed; echo '# IMPLEMENTED in story 03' >> "$P/skills/plan/SKILL.md";       fires "story narration" check_ticket_history
  seed; echo 'The file must be valid UTF-8.' >> "$P/skills/plan/SKILL.md";    silent "standard term UTF-8" check_ticket_history
  seed; yes 'filler' | head -520 >> "$P/skills/implement/SKILL.md";          fires "oversized implement body" check_body_size
  seed; echo 'see [x](planning-playbook.md)' >> "$P/skills/implement/references/spike.md"; fires "implement reference links a reference" check_reference_depth
  seed; sed -i.bak 's#"/sdlc:implement"#"/implement"#' "$P/skills/implement/SKILL.md"; fires "lost implement trigger" check_triggers
  seed; echo 'Read ${CLAUDE_PLUGIN_ROOT}/references/settings.md first.' >> "$P/skills/deliver/references/override.md"; fires "capitalised Read of a shared reference" check_reference_depth
  seed; echo 'Loads ${CLAUDE_PLUGIN_ROOT}/skills/implement/references/spike.md' >> "$P/skills/implement/references/stash-restore.md"; fires "capitalised Loads of a skill reference" check_reference_depth
  seed; echo 'Since #517 merged this step changed.' >> "$P/skills/deliver/SKILL.md";  fires "#NNN issue history" check_ticket_history
  seed; echo 'Since #20 merged (a regression from #17).' >> "$P/skills/deliver/SKILL.md"; fires "#20 two-digit issue history" check_ticket_history
  seed; echo 'Refs #42, #57, #123 and #1234 are examples.' >> "$P/skills/deliver/SKILL.md"; silent "example issues #42 #57 #123 #1234" check_ticket_history
  seed; echo 'An em dash &#8212; and the colour #5319e7.' >> "$P/skills/plan/SKILL.md"; silent "entity &#8212; and hex colour" check_ticket_history
  seed; echo 'Hash it with SHA-256 and stamp ISO-8601 dates.' >> "$P/skills/plan/SKILL.md"; silent "standard terms SHA-256 and ISO-8601" check_ticket_history
fi

echo "$total checks, $fails failed"
[ "$fails" -eq 0 ]
