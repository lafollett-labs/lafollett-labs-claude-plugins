# Verification Gate

Loaded by Phase 4 on the Standard path, before the first test. Runs before EVERY commit; § Pre-End AC coverage gate runs once, from SKILL.md's Pre-End.

## Contents

- Pre-commit checks
- Warnings waive lifecycle
- Flake handling
- AC coverage progress
- Pre-End AC coverage gate

## Pre-commit checks

```text
before EVERY commit (not just the final one):
  build:        differentiate NEW vs PRE-EXISTING warnings (see lifecycle below)
  tests:        full suite must pass — not just new tests
  lint:         must pass; same NEW vs PRE-EXISTING discipline applies
  AC coverage:  log progress every commit; gate on the FINAL commit (see AC coverage progress below)

if any check fails (excluding flake — see below):
  fix it OR follow the waive lifecycle below
  do NOT commit broken or AC-incomplete code
```

## Warnings waive lifecycle

Applies to build and lint.

```text
new_warnings        = warnings on touched files at HEAD but NOT at session.branch_cut
                      (i.e., introduced by THIS branch's diff since branch creation)
preexisting_warnings = warnings on touched files at session.branch_cut
                      (i.e., already present before this branch's diff)

session.waived_warnings carries BOTH the disposition and the specific warning
records it covers, so subsequent commits know what to suppress and what to
re-prompt on:

  session.waived_warnings = {
    disposition:     "fix-in-scope" | "waive-for-branch" | "waive-and-ticket",
    warnings:        [ (file, line, code), ... ],   # warning identifiers as tuples
    followup_ticket: "#<N>" or null                  # populated only when
                                                     # disposition == "waive-and-ticket"
  }

gate on the FIRST commit of the branch:
  new_warnings must be ZERO before any commit lands

  if preexisting_warnings is not empty:
    report the list ONCE in the question context, then:
    AskUserQuestion → "Pre-existing warnings on touched files — how to handle?"; options:
      (a) "fix-in-scope — expand plan to fix them"
      (b) "waive-for-branch — accept for this branch"
      (c) "waive-and-ticket — open a follow-up issue (sdlc:plan create-standalone), then accept"
    match user_response:
      case (a):                   # fix-in-scope → expand plan (go through the Scope expansion gate, loaded with this file)
        session.waived_warnings = {
          disposition:     "fix-in-scope",
          warnings:        preexisting_warnings,
          followup_ticket: null
        }
      case (b):
        session.waived_warnings = {
          disposition:     "waive-for-branch",
          warnings:        preexisting_warnings,
          followup_ticket: null
        }
      case (c):                   # open the follow-up issue first
        session.waived_warnings = {
          disposition:     "waive-and-ticket",
          warnings:        preexisting_warnings,
          followup_ticket: "#<new issue number>"
        }

on every subsequent commit:
  new_warnings must still be ZERO
  any warning whose (file, line, code) is in session.waived_warnings.warnings:
    do NOT re-prompt
  any warning NOT in session.waived_warnings.warnings:
    re-trigger the lifecycle above (treat as a fresh preexisting set)
```

## Flake handling

Within the test axis.

```text
if test outcome on initial run is fail OR error (assertion failure, crash, or timeout):
  re-run the test 3 times in isolation
  match outcome_set across 4 runs:
    case [fail, fail, fail, fail]:  real failure — fix the bug, do NOT treat as flake
    case [pass, pass, pass, pass]:  initial run was a one-off — log and proceed
    case anything mixed (≥1 pass AND ≥1 fail across the 4 runs):  flake
      🟡 Waiting on you — flaky test detected: {test_name}
      AskUserQuestion → "Flaky test {test_name} — how to proceed?"; options:
        (a) "Fix the flake before committing (recommended)"
        (b) "Quarantine — mark skip + open a follow-up issue, then proceed"
        (c) "Accept and commit anyway — last resort; note flake in commit message"
      do NOT silently retry-until-pass
```

## AC coverage progress

Within the AC axis; the Pre-End gate below reads the same tasks.

```text
at Phase 4 start, before the first test:
  session.ac_tasks = {}                        # dict: ac → task_id
  for ac in session.ticket_acs:
    task_id = TaskCreate(subject = "AC: {ac}", status = "pending")
    session.ac_tasks[ac] = task_id             # explicit ac → task_id mapping

on each commit, parse the commit message body for either footer form:
  "AC: N, M"         — ACs satisfied by this commit
  "AC-waived: N, M"  — ACs explicitly waived/deferred (footer-line "-- {initials}"
                       REQUIRED so the waive carries author attribution)

  for ac_index in (footer_ac_indices ∪ footer_ac_waived_indices):
    if ac_index < 1 OR ac_index > len(session.ticket_acs):
      ⚠️ Warning — invalid AC index {ac_index} in commit body (ignored;
                    valid range is 1..{len(session.ticket_acs)})
      continue
    ac = session.ticket_acs[ac_index - 1]      # 1-based indices match plan
    TaskUpdate(session.ac_tasks[ac], status = "completed")

per-commit progress logging (informational only — no gating):
  committed_acs = [ac for ac in session.ticket_acs
                       if Task(session.ac_tasks[ac]).status == "completed"]
  log "AC progress: {len(committed_acs)}/{len(session.ticket_acs)}"
```

## Pre-End AC coverage gate

Verifies every ticket AC is covered before End; the engineer waives any deferred AC explicitly.

```text
committed_acs = [ac for ac in session.ticket_acs
                     if Task(session.ac_tasks[ac]).status == "completed"]
uncovered_acs = [ac for ac in session.ticket_acs if ac not in committed_acs]

if uncovered_acs is empty:
  proceed to End
else:
  🟡 Waiting on you — AC coverage gap before completion
  list the uncovered ACs in the question context, then:
  AskUserQuestion → "Uncovered ACs remain — how to proceed?"; options:
    (a) "Implement the missing AC(s) now — loops back into Phase 4"
    (b) "Waive via a NEW commit using the canonical AC-waived: footer"
  the (b) waive footer form (same shape as "AC:" — bare indices, engineer initials REQUIRED):
    AC-waived: 3 -- oc
  plus an optional free-form rationale line, e.g.:
    + note: deferred to follow-up #57
  the commit-time parser handles "AC-waived:" the same as "AC:" and marks the
    corresponding Task completed with the waive footer as attribution; no
    out-of-band Task updates here.
  do NOT proceed to End with silently uncovered ACs
```
