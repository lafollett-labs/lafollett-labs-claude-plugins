# Round State

Loaded by SKILL.md at Phase 2, after scope classification and gate detection. Binds the review paths, the round number and the Gate 1 state, checks the findings ledger, and checks the gate prerequisites before any PE is dispatched. `same_code` and `restore_stash()` are SKILL.md § Shared routines.

## Contents

- Read the review
- Round number
- Findings ledger (Gate 1)
- Post-lock check (Gate 1)
- Gate 1 prerequisite (Gate 2)
- Engineer override

## Read the review

`review-file.js parse` is the one reader of a review file (review-store.md).

```text
read_review(args):
  (p, ec) = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" parse {args}`
  if ec != 0: ❌ Error — {p.error}; restore_stash(); STOP
  return p          # rounds, latest (null when none), next_round, gate1 {state, round, sha}, partial_rounds, markdown_path, ledger_path, version_advisories
```

## Round number

```text
session.head_sha = `git -C "{session.review_root}" rev-parse HEAD`   # bound once; reused by Phases 3, 6, 7
author = read_review(`--root "{session.review_root}" --name "{session.name}"`)   # the committed Gate 1 review on the reviewed branch
session.gate1 = author.gate1             # the latest Gate 1 branch round: locked | overridden | open | none
session.skip_rounds = join(author.partial_rounds, ",")   # Staged / Files / Folder / Ad-hoc round numbers: never a ledger gap
session.gate1_skip_note = null
if session.gate == "Gate 1":
  p = author
  session.ledger_path = p.ledger_path    # …/{name}-findings-ledger.json beside it
else:                                    # Gate 2: the reviewer's own rounds, under ~/.claude, never committed
  p = read_review(`--local "{session.repo}" --pr {session.pr.number} --name "{session.name}"`)   # keyed by PR
  session.ledger_path = null
  if author.version_advisories.gate2: ⚠️ {author.version_advisories.gate2}
review_file = output_path = p.markdown_path       # Phase 6 renders here
session.prior   = p if p.rounds is non-empty else null
session.round_n = p.next_round                    # 1 when no round exists; the numbering render uses when it appends
```

## Findings ledger (Gate 1)

Checks the ledger before any PE runs, so a broken ledger stops the round before dispatch.

```text
if not session.ledger: skip this section          # Gate 2, Staged Diff, Specific Files, Folder, Ad-hoc
status = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/convergence.js" status --ledger "{session.ledger_path}" --target "$(git -C "{session.review_root}" rev-parse --abbrev-ref HEAD)" --round {session.round_n} --skip "{session.skip_rounds}"`
if exit == 127:
  ❌ Error — sdlc:review needs Node on PATH (convergence controller); restore_stash(); STOP
elif exit != 0 and `git -C "{session.review_root}" ls-files -u -- "{session.ledger_path}"` is non-empty:
  ❌ Error — findings ledger has a merge conflict; restore_stash(); STOP. Resolve by content, never by --ours/--theirs (they swap under rebase):
     for stage in [2, 3]:
       tmp_{stage} = "{session.ledger_path}.stage{stage}.json"
       `git -C "{session.review_root}" show ":{stage}:{ledger path relative to review_root}"` > "{tmp_{stage}}"
       status_{stage} = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/convergence.js" status --ledger "{tmp_{stage}}" --skip "{session.skip_rounds}"`
     if status_2.rounds != status_3.rounds:        keep = the stage with more rounds
     elif status_2.locked != status_3.locked:      keep = the stage whose locked is false   # fail closed — a lock never survives a dirty round
     else:                                         keep = 3
     copy tmp_{keep} over "{session.ledger_path}"; delete tmp_2, tmp_3
     `git -C "{session.review_root}" add "{session.ledger_path}"`; re-run
elif exit != 0:
  ❌ Error — findings ledger unreadable: {stderr}; restore_stash(); STOP. Restore the newest committed version the controller accepts:
     tmp = "{session.ledger_path}.restore.json"
     for sha in `git -C "{session.review_root}" log --format=%h -- "{session.ledger_path}"`:
       `git -C "{session.review_root}" show "$sha:{ledger path relative to review_root}"` > "{tmp}"
       if `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/convergence.js" status --ledger "{tmp}"` exits 0:   # the controller's own check — parse AND shape
         `git -C "{session.review_root}" checkout "$sha" -- "{session.ledger_path}"`; break
     delete tmp
     never delete the ledger — it holds the clean streak + reopen history
```

## Post-lock check (Gate 1)

A Gate 1 closed (locked or overridden) on other code is stale; a review-doc commit since the lock is not a change.

```text
g = session.gate1
if session.gate == "Gate 1" and g.state in ["locked", "overridden"] and not same_code(g.sha, session.head_sha):
  if session.auto:
    🤖 Auto-resolved — the code changed since Gate 1 closed at {g.sha} (round {g.round}); reviewing HEAD as a fresh round
  else:
    AskUserQuestion → "Gate 1 closed ({g.state}) at {g.sha} in round {g.round}, and the code has changed since. Review HEAD?"; options:
      (a) "review HEAD as a fresh round (recommended)"
      (b) "abort"
    if (b): restore_stash(); exit
```

## Gate 1 prerequisite (Gate 2)

Gate 2 is an independent peer review; it presupposes the author closed Gate 1 on this code. Verify that BEFORE PE dispatch, so peer review capital is never spent on un-self-reviewed code.

```text
if session.gate == "Gate 2":
  g = session.gate1
  why = "no Gate 1 round in docs/code-reviews/{session.name}-code-review.md" if g.state == "none"
        else "Gate 1 is still open (round {g.round})" if g.state == "open"
        else "the code changed since Gate 1 closed at {g.sha}" if not same_code(g.sha, session.head_sha)
        else null
  if why and session.auto:              # unattended: record the skip and proceed (a hard exit strands the run)
    🤖 Auto-resolved — {why}; proceeding and recording the skip (auto)
    session.gate1_skip_note = "⚠️ Gate 1 not closed for this code at review start ({why}) — proceeded unattended (auto)"
  elif why:
    🟡 Waiting on you — {why}
    AskUserQuestion → "The PR author has not closed Gate 1 for this code ({why}) — proceed with peer review?"; options:
      (a) "Bounce back — ask the author to close Gate 1 first (recommended); exit"
      (b) "Proceed anyway — record that Gate 1 was skipped"
      (c) "Abort"
    match user_response:
      case (a): restore_stash(); 🛑 exit — the author runs sdlc:review and locks Gate 1 (2 consecutive clean rounds) on this code
      case (b): session.gate1_skip_note = "⚠️ Gate 1 not closed for this code at review start ({why}) — peer review proceeded by @{session.reviewer_username}"
      case (c): restore_stash(); exit
```

## Engineer override

Never silently accept an override. Before honoring one, push back on every open gating (MEDIUM+) finding; advisory LOW/INFO need no override.

```text
restate every open MEDIUM+ finding — severity, location, and why it genuinely matters
state plainly: "These are legitimate and unresolved. Override and accept them anyway?"
require an explicit second confirmation + a one-line reason
if not confirmed: return to remediate + re-review
open = [{id: f.id, title: f.title} for f in read_review(`--file "{output_path}"`).latest.in_scope_findings if f.severity in [CRITICAL, HIGH, MEDIUM]]
(o, ec) = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" override --file "{output_path}"` < {round: session.round_n, reviewer: session.reviewer_username, reason, findings: open}
if ec != 0: ❌ Error — override not recorded: {o.error}; return to remediate + re-review
session.gate_status = o.gate_status     # "OVERRIDDEN — {reason}"; the round now holds its Overridden Findings section
```
