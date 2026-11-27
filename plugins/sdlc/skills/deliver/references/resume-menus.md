# Resume Menus

Loaded by `sdlc:deliver` Phase 0 when the ticket's branch already exists (state is not `fresh`).

Each menu is one 🟡 AskUserQuestion; the chosen option's tag sets the entry phase. A resumed run is NOT auto unless `--auto` was passed THIS invocation; the menu itself is always interactive, and auto applies only to gates reached after it.

```text
preamble on EVERY menu:
  "Mode: {AUTO — gates after this menu auto-resolve | INTERACTIVE}"         # from session.auto, bound fresh this run
  "Issue: {session.issue_status}" if session.issue_number                    # informational only

each menu is ONE AskUserQuestion; the chosen option's tag sets the entry phase (→ Phase N). Default first + "(recommended)".

Menu A — feature branch, 0 commits ahead (implement interrupted before any commit)
  AskUserQuestion → "Resume {ticket_key} — branch has no commits yet. What next?"; options:
    (resume) "Resume sdlc:implement (recommended) → Phase 1"
    (start-over) "Start over → Phase 1"

Menu B — code committed, not yet reviewed
  AskUserQuestion → "Resume {ticket_key} — code committed, not yet reviewed. What next?"; options:
    (review) "Run sdlc:review (recommended) → Phase 2"
    (implement) "sdlc:implement — make more changes → Phase 1"
    (skip) "Skip to verification gate + PR, no review → Phase 6.5"
    (start-over) "Start over → Phase 1"

Menu C — code committed AND reviewed (preamble also shows latest verdict + round + gate status)
  recommended = (verify) if latest gate_status starts with "LOCKED"/"OVERRIDDEN" else (re-review)   # compute before the prompt
  AskUserQuestion → "Resume {ticket_key} — code committed + reviewed. What next?"; options (append "(recommended)" to {recommended}'s label):
    (re-review) "Re-review — fresh sdlc:review round → Phase 2"
    (implement) "sdlc:implement — make more changes → re-review → Phase 1"
    (verify) "Verification gate + PR → Phase 6.5 if gate_status starts with LOCKED/OVERRIDDEN, else Phase 3 (fix loop's remediate/override/stop — no unfixed finding reaches the PR without a recorded override)"
    (start-over) "Start over → Phase 1"

Menu D — spike doc present (spike already delivered)
  context: "spike findings exist at docs/spikes/{key_slug}-*.md"
  AskUserQuestion → "Resume {ticket_key} — spike doc present. What next?"; options:
    (finish) "View spike summary + finish, no review/PR (recommended) → Phase S"
    (implement) "sdlc:implement — spike concluded build-it → Phase 1"
    (start-over) "Start over → Phase 1"
```

"Start over" routes to Phase 1; `sdlc:implement` owns its own dirty-tree and existing-branch handling, so deliver never pre-cleans the working tree.
