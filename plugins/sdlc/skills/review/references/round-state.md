# Round State

Loaded by SKILL.md at Phase 2, after scope classification and gate detection. Binds the round number, reads the findings ledger, and checks the gate prerequisites before any PE is dispatched.

## Contents

- Directory-existence check
- Read the review
- Round number + post-lock commits
- Gate 1 prerequisite (Gate 2 only)
- Engineer override

## Directory-existence check

```text
session.story_spec = session.story.text if session.story else null   # the issue body or story file bound in SKILL.md Phase 1

if session.story_spec != null:
  parse session.story_spec for:
    - structure trees (markdown code blocks with directory paths)
    - acceptance criteria referencing directory paths (e.g., "skills/{implement,review}/")
  → directories_required = [list of paths]

  for dir in directories_required:
    if not (Glob(dir) or directory exists in working tree):
      record Pass-2b finding:
        severity:   MEDIUM (default; bump to HIGH if story spec marks dir as MUST exist)
        title:      "Required directory missing: {dir}"
        location:   "{dir}/"
        description: "Story {session.ticket_key} spec requires this directory but it is absent from the diff and the working tree. Empty directories do not appear in git diff and would silently pass a content-only review."
        recommendation: "Create the directory (with a placeholder file if needed to make it survive git) or amend the story spec to remove the requirement."
        in_scope: true

if session.story_spec == null:
  skip Pass 2b directory check (no AC source to validate against)
```

## Read the review

`review-file.js parse` is the one reader of the review file (review-store.md).

```text
read_review(root, name):
  (p, ec) = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" parse --root "{root}" --name "{name}"`
  if ec != 0: ❌ Error — {p.error}; STOP
  return p          # rounds, latest (null when none), next_round, markdown_path, ledger_path, version_advisories
```

## Round number + post-lock commits

```text
session.head_sha    = `git -C "{session.review_root}" rev-parse HEAD`   # bound once; reused by Phases 3, 6, 7 — the reviewed branch's HEAD (worktree's in worktree mode)
p = read_review(session.review_root, session.name)   # § Read the review
if session.gate == "Gate 2" and p.version_advisories.gate2:
  ⚠️ {p.version_advisories.gate2}
review_file         = p.markdown_path   # {review_root}/docs/code-reviews/{name}-code-review.md
output_path         = p.markdown_path   # Phase 6 renders here
session.ledger_path = p.ledger_path     # …/{name}-findings-ledger.json beside it
session.prior       = p if p.rounds is non-empty else null
session.round_n     = p.next_round      # 1 when no round exists; the same numbering render uses when it appends

if not session.ledger:                             # scope.js: Specific Files / Folder / Ad-hoc never touch the branch ledger
  ledger_status = {locked: false, last_clean: null}
  skip to § Gate 1 prerequisite

# Clean-round state is read from the findings ledger by code — never re-derived from prose.
ledger_status = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/convergence.js" status --ledger "{session.ledger_path}" --target "$(git -C "{session.review_root}" rev-parse --abbrev-ref HEAD)" --round {session.round_n}`
                # --target: a lock earned on another branch never counts; --round: a round missing since the lock (errored, never recorded) breaks it
if exit == 127:
  ❌ Error — sdlc:review needs Node on PATH (convergence controller); STOP
elif exit != 0 and session.gate == "Gate 2":
  ⚠️ Warning — findings ledger unreadable ({stderr}); continuing peer review
  ledger_status = {locked: false, last_clean: null}
elif exit != 0 and `git -C "{session.review_root}" ls-files -u -- "{session.ledger_path}"` is non-empty:
  ❌ Error — findings ledger has a merge conflict; STOP. Resolve by content, never by --ours/--theirs (they swap under rebase):
     for stage in [2, 3]:
       tmp_{stage} = "{session.ledger_path}.stage{stage}.json"
       `git -C "{session.review_root}" show ":{stage}:{ledger path relative to review_root}"` > "{tmp_{stage}}"
       status_{stage} = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/convergence.js" status --ledger "{tmp_{stage}}"`
     if status_2.rounds != status_3.rounds:        keep = the stage with more rounds
     elif status_2.locked != status_3.locked:      keep = the stage whose locked is false   # fail closed — a lock never survives a peer's dirty round
     else:                                         keep = 3
     copy tmp_{keep} over "{session.ledger_path}"; delete tmp_2, tmp_3
     `git -C "{session.review_root}" add "{session.ledger_path}"`; re-run
elif exit != 0:
  ❌ Error — findings ledger unreadable: {stderr}; STOP. Restore the newest committed version the controller accepts:
     tmp = "{session.ledger_path}.restore.json"
     for sha in `git -C "{session.review_root}" log --format=%h -- "{session.ledger_path}"`:
       `git -C "{session.review_root}" show "$sha:{ledger path relative to review_root}"` > "{tmp}"
       if `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/convergence.js" status --ledger "{tmp}"` exits 0:   # the controller's own check — parse AND shape
         `git -C "{session.review_root}" checkout "$sha" -- "{session.ledger_path}"`; break
     delete tmp
     never delete the ledger — it holds the clean streak + reopen history
last_locked_round = ledger_status.last_clean if ledger_status.locked else null   # {round, sha}; only a closed Gate 1

if session.prior:
  if last_locked_round != null:
    if session.head_sha != last_locked_round.sha:
      # New commits since Gate 1 locked — the lock may be stale
      if session.auto:                              # unattended: take the recommended (a) — re-review HEAD
        🤖 Auto-resolved — HEAD advanced since lock; re-running review on HEAD as a fresh round (auto)
        proceed to Phase 3 as a new round
      AskUserQuestion → "Gate 1 locked at SHA {last_locked_round.sha} (Round {last_locked_round.round}); HEAD advanced to {session.head_sha}. Choose:"; options:
        (a) "re-run review on HEAD as a fresh round (recommended)"
        (b) "waive — record waive entry and keep gate locked"
        (c) "abort"

      match user_response:
        case (a):
          proceed to Phase 3 as a new round
        case (b):
          require: waive rationale + reviewer initials
          append waive entry to the review file, before its footer:
            ## Post-gate-lock waive
            **HEAD SHA:** {head_sha}
            **Prior locked SHA:** {last_locked_round.sha}
            **Waived by:** {initials}
            **Rationale:** {user-provided rationale}
          do NOT re-run PE dispatch; exit
        case (c):
          if session.stash_ref: git stash pop; on conflict git stash apply and tell the user the stash {session.stash_ref} is still in their stash list
          exit
```

## Gate 1 prerequisite (Gate 2 only)

Gate 2 is an independent peer review; it presupposes the author drove Gate 1 to a lock. Verify that proof BEFORE PE dispatch, so peer review capital is never spent on un-self-reviewed code. Proof = a recorded round whose Gate Status begins "LOCKED" (only a Gate 1 lock records "LOCKED — ready for Gate 2"; no recorded round is trivially unlocked).

```text
session.gate1_skip_note = null

if session.gate == "Gate 2":
  gate1_locked = session.prior is not null and any(r.gate_status starts with "LOCKED" for r in session.prior.rounds)
  if not gate1_locked:
    if session.auto:                    # unattended: record the skip and proceed (a hard exit strands the run)
      🤖 Auto-resolved — author has no Gate 1 lock; proceeding and recording the skip (auto)
      session.gate1_skip_note = "⚠️ Gate 1 not locked at review start — proceeded unattended (auto)"
    else:
      🟡 Waiting on you — author has no Gate 1 lock in {review_file}
      AskUserQuestion → "PR author has no recorded Gate 1 lock — proceed with peer review?"; options:
        (a) "Bounce back — ask the author to complete Gate 1 first (recommended); exit"
        (b) "Proceed anyway — record that Gate 1 was skipped"
        (c) "Abort"
      match user_response:
        case (a):
          if session.stash_ref: git stash pop; on conflict git stash apply and tell the user the stash {session.stash_ref} is still in their stash list
          🛑 exit — the author runs sdlc:review locally and locks Gate 1 (2 consecutive clean rounds) before re-requesting peer review
        case (b):
          session.gate1_skip_note = "⚠️ Gate 1 not locked at review start — peer review proceeded by @{session.reviewer_username}"
        case (c):
          if session.stash_ref: git stash pop; on conflict git stash apply and tell the user the stash {session.stash_ref} is still in their stash list
          exit
```

## Engineer override

Never silently accept an override. Before honoring one, push back on every open gating (MEDIUM+) finding; advisory LOW/INFO need no override.

```text
restate every open MEDIUM+ finding — severity, location, and why it genuinely matters
state plainly: "These are legitimate and unresolved. Override and accept them anyway?"
require an explicit second confirmation + a one-line reason
if confirmed:
  session.gate_status = "OVERRIDDEN — engineer accepted {N} open finding(s); see Overridden Findings"
  in the round just persisted (round 1 → the top section; later → its "## Review Round {n}"), set the Gate Status cell and append:
    ### Overridden Findings (round {session.round_n})
    - [{severity}] {title} — {location} — overridden by @{session.reviewer_username}: "{reason}"
else:
  return to remediate + re-review
```
