#!/usr/bin/env bash
# Structure and terminology guards for the live-stock skills: body size, reference TOCs and depth, ticket-history
# narration, one term per concept, script-call flags, sdlc:plan result gates, the herd trigger, herd's
# reviewer-requested-changes-twice rule, and no source-platform or organisation-specific terms in any doc. Each check runs against a plugin root, so the mutation cases at the
# bottom can prove a guard actually fires.
# Usage: run-structure-tests.sh [plugin-root]   (default: this plugin)
# No npm packages — bash + grep/awk only. Exit 0 = all cases pass, 1 = any fail.
# shellcheck disable=SC2317,SC2329 # the check_* functions run indirectly through run_check, fires and silent
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="${1:-$(cd "$HERE/../.." && pwd)}"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# The one example key the docs may use; anything else matching <PROJECT>-<n> is ticket history.
EXAMPLE_KEYS='^(LT-02)$'

skills() { find "$1/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort; }

# Markdown the model reads as instructions (READMEs and fixtures excluded).
instruction_docs() {
  find "$1/skills" "$1/references" "$1/assets" -type f -name '*.md' \
    -not -path '*/bin/test/fixtures/*' -not -name 'README.md' 2>/dev/null | sort
}

# Every doc the plugin ships: Markdown and JSON outside the scripts' bin/ trees (fixtures included there).
all_docs() {
  find "$1" -type f \( -name '*.md' -o -name '*.json' \) -not -path "$1/bin/*" -not -path "$1/skills/*/bin/*" 2>/dev/null | sort
}

# strip_frontmatter <file> — the body without the leading --- … --- block
strip_frontmatter() { awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$1"; }
# frontmatter <file> — only the leading --- … --- block
frontmatter() { awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm' "$1"; }

check_body_size() {  # <root> → violations on stdout
  local s f n
  while IFS= read -r s; do
    f="$s/SKILL.md"; [ -f "$f" ] || continue
    n=$(strip_frontmatter "$f" | wc -l)
    [ "$n" -lt 500 ] || echo "${s##*/} SKILL.md body is $n lines (limit 499)"
  done < <(skills "$1")
}

check_reference_tocs() {
  local s f
  while IFS= read -r s; do
    for f in "$s/references/"*.md; do
      [ -f "$f" ] || continue
      if [ "$(wc -l < "$f")" -gt 100 ] && ! grep -q '^## Contents' "$f"; then
        echo "${f#"$1"/} is over 100 lines with no ## Contents"
      fi
    done
  done < <(skills "$1")
}

check_reference_depth() {  # a skill reference never loads another reference (the skill's own or a shared one)
  local s f
  while IFS= read -r s; do
    for f in "$s/references/"*.md; do
      [ -f "$f" ] || continue
      grep -nE "(read|load) [^ ]*(skills/[a-z-]+/)?references/[a-z0-9-]+\.md|\]\((\./)?[a-z0-9-]+\.md\)" "$f" | sed "s|^|${f#"$1"/}:|"
    done
  done < <(skills "$1")
}

check_ticket_history() {
  local s f k
  while IFS= read -r s; do
    for f in "$s/SKILL.md" "$s/references/"*.md; do
      [ -f "$f" ] || continue
      grep -nE '[Ss]tory [0-9]+|IMPLEMENTED' "$f" | sed "s|^|${f#"$1"/}:|"
      for k in $(tr -c '[:alnum:]_-' '\n' < "$f" | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+(-|$)' | sed 's/-$//' | sort -u); do
        [[ "$k" =~ $EXAMPLE_KEYS ]] || echo "${f#"$1"/} names ticket $k"
      done
    done
  done < <(skills "$1")
}

check_terms() {  # one term each: ticket_key / <KEY> (never issue_key or story_key), "Gate 1", "code-review"
  local f
  while IFS= read -r f; do
    strip_frontmatter "$f" | grep -nE '(^|[^[:alnum:]_])(ac_)?(issue|story)_key([^[:alnum:]_]|$)|Gate-[12]([^[:alnum:]_]|$)|TICKET-ID' | sed "s|^|${f#"$1"/}:|"
    # spaced "code review" (singular) outside backtick literals such as the `Code Review` status name
    # shellcheck disable=SC2016 # the backticks are literal Markdown
    strip_frontmatter "$f" | grep -nE '[Cc]ode [Rr]eview([^s]|$)' | grep -vF '`Code Review`' | sed "s|^|${f#"$1"/}:|"
  done < <(instruction_docs "$1")
}

check_triggers() {  # herd's description keeps its name and its /live-stock:herd invocations
  local f="$1/skills/herd/SKILL.md" desc want miss=""
  [ -f "$f" ] || { echo "skills/herd/SKILL.md is missing"; return; }
  desc="$(frontmatter "$f")"
  grep -qxF "name: herd" <<<"$desc" || miss="$miss name"
  for want in '"/live-stock:herd <run-file>"' '"/live-stock:herd new <work-plan>"' '"herd this work plan"'; do
    grep -qF -- "$want" <<<"$desc" || miss="$miss $want"
  done
  [ -z "$miss" ] || echo "lost trigger phrases:$miss"
}

check_script_calls() {  # publish-body.js prepare and verify (by name or as node "{PB}") carry their required flags
  local f line
  while IFS= read -r f; do
    while IFS= read -r line; do
      line="${line%% # *}"                    # a trailing pseudocode comment names a script; it does not run it
      case "$line" in
        *"publish-body.js prepare"*|*'{PB}" prepare'*) [[ "$line" == *--file* && "$line" == *--type* ]] || echo "${f#"$1"/}: $line" ;;
        *"publish-body.js verify"*|*'{PB}" verify'*)   [[ "$line" == *--file* && "$line" == *--readback* ]] || echo "${f#"$1"/}: $line" ;;
      esac
    done < "$f"
  done < <(instruction_docs "$1")
}

check_plan_result_gates() {  # the line after every sdlc:plan result continues only on its success shape
  local f line pending="" gate='if not (result ends with its "✅ Done" line and reports no readback findings):'
  while IFS= read -r f; do
    pending=""
    while IFS= read -r line; do
      if [ -n "$pending" ]; then
        line="${line#"${line%%[![:space:]]*}"}"
        [ "$line" = "$gate" ] || echo "${f#"$1"/}: $pending -> $line"; pending=""
      fi
      [[ "$line" == *"result = sdlc:plan"* ]] && pending="${line#"${line%%[![:space:]]*}"}"
    done < "$f"
  done < <(instruction_docs "$1")
}

check_reviewer_twice() {  # a second changes-requested round from the reviewer parks the row and escalates
  local f="$1/skills/herd/SKILL.md" want
  [ -f "$f" ] || { echo "skills/herd/SKILL.md is missing"; return; }
  for want in \
    'if n >= 2 and the row has no "reviewer-changes | <KEY> | allow round <n>" line: Reviewer changes twice (below)' \
    'State parked; Hold "<KEY> reviewer requested changes twice" (unparks when the stand-in answers)' \
    '| The reviewer requests changes a second time on the same PR (Merge: Reviewer changes twice) | stand-in |'; do
    grep -qF -- "$want" "$f" || echo "SKILL.md lost: $want"
  done
}

check_forbidden_terms() {  # no doc names the source platforms, their tools, or an organisation drive
  local f
  while IFS= read -r f; do
    grep -niE '(^|[^[:alnum:]_])(glab|gitlab|jira|atlassian|duo)([^[:alnum:]_]|$)|merge[ -]requests?' "$f" | sed "s|^|${f#"$1"/}:|"
    grep -nE '(^|[^[:alnum:]_])MRs?([^[:alnum:]_]|$)|(^|[^[:alnum:]])[PL]:([\\/]| drive| or [PL]:)' "$f" | sed "s|^|${f#"$1"/}:|"
  done < <(all_docs "$1")
}

run_check() {  # run_check <name> <fn> <root>
  local out; out="$("$2" "$3")"
  # shellcheck disable=SC2001 # indents every line of a multi-line string
  if [ -z "$out" ]; then pass "$1"; else fail "$1"$'\n'"$(sed 's/^/    /' <<<"$out" | head -20)"; fi
}

run_check "SKILL.md bodies are under 500 lines" check_body_size "$PLUGIN"
run_check "references over 100 lines open with ## Contents" check_reference_tocs "$PLUGIN"
run_check "references are one level deep" check_reference_depth "$PLUGIN"
run_check "skills carry no ticket history" check_ticket_history "$PLUGIN"
run_check "instructions use one term per concept" check_terms "$PLUGIN"
run_check "herd keeps its /live-stock:herd triggers" check_triggers "$PLUGIN"
run_check "publish-body.js prepare and verify calls carry their required flags" check_script_calls "$PLUGIN"
run_check "sdlc:plan result gates continue only on the success shape" check_plan_result_gates "$PLUGIN"
run_check "herd parks and escalates on a second changes-requested round" check_reviewer_twice "$PLUGIN"
run_check "docs name no source platform, its tools, or an organisation drive" check_forbidden_terms "$PLUGIN"

# --- mutation cases: each guard fires on a seeded violation in a temp copy (default plugin root only) ----
if [ $# -eq 0 ]; then
  TMP="$(mktemp -d)"
  trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -r -- "$TMP"' EXIT
  P=""; H=""
  seed() { P="$(mktemp -d "$TMP/p.XXXXXX")"; cp -R "$PLUGIN/." "$P/"; H="$P/skills/herd"; }   # a fresh copy per case
  fires() {  # fires <name> <fn>
    if [ -n "$("$2" "$P")" ]; then pass "guard fires: $1"; else fail "guard silent: $1"; fi
  }
  silent() {  # silent <name> <fn>
    if [ -z "$("$2" "$P")" ]; then pass "guard silent: $1"; else fail "guard fires: $1"; fi
  }
  seed; yes 'filler' | head -520 >> "$H/SKILL.md";                                  fires "oversized body" check_body_size
  seed; yes 'filler' | head -120 > "$H/references/big.md";                          fires "reference without TOC" check_reference_tocs
  seed; echo 'see [x](finish.md)' >> "$H/references/replanning.md";                 fires "reference links a reference" check_reference_depth
  seed; echo "read \${CLAUDE_PLUGIN_ROOT}/references/issue-status-labels.md" >> "$H/references/finish.md"; fires "reference loads a shared reference" check_reference_depth
  seed; echo 'Since AB-1341 this changed.' >> "$H/SKILL.md";                        fires "ticket history" check_ticket_history
  seed; echo '# IMPLEMENTED in story 03' >> "$H/references/finish.md";              fires "story narration" check_ticket_history
  seed; echo 'A lane is named like lane-lt02 for LT-02.' >> "$H/SKILL.md";          silent "the example key LT-02" check_ticket_history
  seed; echo 'session.issue_key = x' >> "$H/SKILL.md";                              fires "issue_key term" check_terms
  seed; echo 'needs a Gate-1 lock' >> "$H/references/gate-answers.md";              fires "Gate-1 term" check_terms
  seed; echo 'after the code review ends' >> "$H/references/lane-prompts.md";       fires "spaced code review" check_terms
  seed; sed -i.bak 's#"/live-stock:herd <run-file>"#"/sdlc:herd <run-file>"#' "$H/SKILL.md"; fires "lost /live-stock:herd trigger" check_triggers
  seed; echo 'node publish-body.js prepare <file>' >> "$H/references/finish.md";    fires "bare publish-body prepare" check_script_calls
  seed; echo 'node publish-body.js prepare --type Story --file <file>' >> "$H/references/finish.md"; silent "flagged publish-body prepare" check_script_calls
  seed; echo 'sdlc:plan update --file <f>      # runs publish-body.js verify' >> "$H/references/finish.md"; silent "publish-body named in a comment" check_script_calls
  seed; echo 'node "{PB}" verify --file x' >> "$H/references/finish.md";            fires "{PB} verify without --readback" check_script_calls
  seed; printf 'result = sdlc:plan update --file f --key K\nif result is "Done with errors":\n' >> "$H/references/finish.md"; fires "plan result gate on failure shapes" check_plan_result_gates
  seed; printf 'result = sdlc:plan update --file f --key K\nupdate the row\n' >> "$H/references/finish.md"; fires "plan result with no gate" check_plan_result_gates
  seed; printf 'result = sdlc:plan update --file f --key K\n  if not (result ends with its "✅ Done" line and reports no readback findings):\n' >> "$H/references/finish.md"; silent "plan result gate on the success shape" check_plan_result_gates
  seed; sed -i.bak '/reviewer requested changes twice" (unparks/d' "$H/SKILL.md";   fires "reviewer-twice Hold removed" check_reviewer_twice
  seed; sed -i.bak '/The reviewer requests changes a second time on the same PR/d' "$H/SKILL.md"; fires "reviewer-twice escalation removed" check_reviewer_twice
  seed; echo 'run glab api to read it' >> "$H/references/finish.md";               fires "glab named" check_forbidden_terms
  seed; echo 'Ships on GitLab.' >> "$P/README.md";                                  fires "GitLab named in a README" check_forbidden_terms
  seed; echo 'sync the Jira body' >> "$H/assets/herd-run-template.md";              fires "Jira named" check_forbidden_terms
  seed; echo 'the Atlassian MCP' >> "$H/README.md";                                 fires "Atlassian named" check_forbidden_terms
  seed; echo 'open the merge request' >> "$H/references/lane-prompts.md";           fires "merge request named" check_forbidden_terms
  seed; echo 'merge the MR' >> "$H/SKILL.md";                                       fires "MR named" check_forbidden_terms
  seed; echo 'rerequest GitLabDuo or Duo' >> "$H/SKILL.md";                         fires "Duo named" check_forbidden_terms
  seed; echo 'Never write to the P: or L: drive' >> "$H/SKILL.md";                  fires "P:/L: drive named" check_forbidden_terms
  seed; sed -i.bak 's#"LaFollett Labs"#"duo labs"#' "$P/.claude-plugin/plugin.json"; fires "Duo named in plugin.json" check_forbidden_terms
  seed; echo 'MRI, a PR, a primary key and 4:3 ratios' >> "$H/SKILL.md";            silent "words that only look like a source term" check_forbidden_terms
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "live-stock structure: all tests passed"
  exit 0
fi
echo "live-stock structure: $fails test(s) failed"
exit 1
