# Spike Path

Loaded by Phase 4 when `session.spike == true`. Writes and commits a findings doc instead of code; the
escape hatch below moves the work to the Standard path when the spike has produced shippable code.

```text
# Escape hatch: spike has produced shippable code mid-stream
if `git status --porcelain` shows changes outside `docs/spikes/`:
  ⚠️  Warning — spike has produced shippable code outside docs/spikes/
  AskUserQuestion → "Spike produced shippable code outside docs/spikes/ — how to proceed?"; options:
    (a) "Re-classify as feat|fix|refactor|docs|chore|test — keep the code, take the Standard path"
    (b) "Discard non-docs changes — write spike findings only"
  do NOT proceed silently with mixed spike + code
  match user_response:
    case (a):
      new_type = prompt_for_work_type(
        "spike has produced shippable code; pick a new work_type:"
      )                                          # reuses the canonical 3-attempt-capped helper
      if new_type != session.branch_type:          # chore → chore keeps the branch as is
        # session.branch_name is safe-ref checked: built by `new`, or kept by SKILL.md Phase 2's filter
        r = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" retype --type '{new_type}' --name '{session.branch_name}'
        if not r.ok:
          ❌ Error — cannot rename {session.branch_name}: {r.error}; ask the engineer how to proceed; STOP
        git branch -m '{r.from}' '{r.to}'
        if `git ls-remote --exit-code --heads origin '{r.from}'` exits 0:   # already pushed
          🟡 Waiting on you — remote branch still has the old name
          AskUserQuestion → "Spike branch was pushed as {r.from} — rename it on origin too?"; options:
            (a) "Rename on origin — git push origin :'{r.from}' '{r.to}'"
            (b) "Leave the remote as-is"
          never run the remote rename without (a)
        session.branch_name = r.to
      session.branch_type = new_type
      session.work_type   = new_type
      session.spike       = false
      return to the Standard path in SKILL.md Phase 4
    case (b):
      discard non-docs changes (`git checkout -- <non-docs-paths>`); write spike findings only

# Commit description — the ticket title is attacker-influenced; the script strips shell + newline meta
d = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" sanitize <<'SPIKE_DESCRIPTION'
{session.ticket_title}
SPIKE_DESCRIPTION
short_description = d.description            # one line, ≤ 60 chars, "investigation" when nothing is left

spike_doc = "docs/spikes/{session.key_slug}-{session.slug}.md"
write findings to spike_doc
git add '{spike_doc}'

# git commit -F <file> instead of -m eliminates shell-quoting concerns
write commit_msg_file with content:
  "chore(spike): {short_description}\n\nRefs: {session.ticket_key}"
git commit -F '<commit_msg_file>'
goto End (SKILL.md)
```
