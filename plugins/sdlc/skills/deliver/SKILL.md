---
name: deliver
description: >-
  Thin SDLC orchestrator that chains sdlc:implement -> sdlc:review -> sdlc:pull-request for one ticket, a GitHub issue (#42) or a local story code (LT-02). On invocation it detects prior progress and offers an explicit resume menu, runs an automated fix loop that drives sdlc:review's Gate 1 to a locked state (2 consecutive clean rounds; bounded by review's deterministic round cap) by remediating every in-scope MEDIUM+ finding (LOW/INFO are advisory and carried to the PR) — an engineer override requires mandatory agent pushback — enforces a human verification gate before any PR, and short-circuits cleanly on spike outcomes. Owns only cross-skill orchestration — delegates all real work to the three peer skills and never dispatches PE agents itself. This skill should be used when the engineer says "Deliver this issue", "Take #42 end-to-end", "Deliver LT-02", or invokes "/sdlc:deliver".
argument-hint: "[#ISSUE | STORY-CODE] [--auto] [--incident] [--no-slack] [--model-by-review-tier | --no-model-by-review-tier] [--builds worktree|checkout|off]"
---

# Deliver (sdlc:deliver)

Initial input: `$ARGUMENTS`

Drives one ticket from a starting point through committed code, an APPROVED review, a human verification gate, and an open PR, by delegating to the three peer skills. deliver owns ONLY the cross-skill control flow: entry routing, the fix loop, and the verification gate. Every unit of real work (issue read, branching, planning, TDD, PE review, push, PR, Copilot, labels, Slack) lives in a sub-skill.

```text
phases:
  0   — Entry + resume menu     detect prior progress; route or start fresh (deliver-owned)
  0.5 — Auto consent banner     --auto ONLY, fresh entry: disclose the unattended chain (no reply) (deliver-owned)
  1   — Implement               invoke sdlc:implement (commits code OR writes a spike doc); --auto keeps its plan gate; --incident: a reviewer answers it
  S   — Spike short-circuit     spike outcome → skip review + PR, summarize (deliver-owned)
  2   — Review                  invoke sdlc:review (records the round in docs/code-reviews/)
  3   — Fix loop                drive review's Gate 1 to LOCKED (2 consecutive clean); HUMAN_GATE hands back (deliver-owned); --auto: remediate, halts on the conditions below
  6.5 — Verification gate       HARD STOP — human approves before any PR (deliver-owned); --auto: auto-approved + recorded
  7   — Pull request            invoke sdlc:pull-request (push, PR, Copilot, status:in-review, optional Slack)
  End — Completion summary
```

## Operating Principles

```text
use TaskCreate / TaskUpdate to track every phase:
  mark in_progress when starting; completed when done

deliver owns EXACTLY three control points — add no others:
  Phase 0   — resume menu (entry routing)
  Phase 3   — fix-loop round prompt
  Phase 6.5 — verification gate (HARD STOP before the PR)

auto mode (--auto, opt-in, per-invocation):
  human stops = sdlc:implement's PLAN gate (under --incident only on escalate) + copilot-review's confirm when a Copilot thread needs a decision.
    deliver passes --auto down; each sub-skill auto-resolves its happy-path gates. deliver auto-resolves
    Phase 3 (remediate) + 6.5 (approve), RECORDED in session.auto_decisions. Phase 0.5 discloses the unattended PR up front.
  HALTS + hands back on: spike, unresolvable / no-progress finding, override, loop-guard, review HUMAN_GATE.

delegate, never duplicate:
  every sub-skill owns its own gates (implement's planning HARD STOP; review's scope banner
  + multi-round loop (ledger-driven, round cap) + review-file commit; pull-request's base/reviewer/title/intent/label/Slack gates)
  do not re-ask anything a sub-skill already asks — the engineer already answered it there

never dispatch PE agents:
  PE review lives in sdlc:review; deliver only invokes it and reads the resulting review file

sub-skills communicate via SIDE EFFECTS, not return values:
  after each sub-skill returns, re-probe git + files to learn the outcome
  (branch, commits-ahead, spike doc, review file + verdict)

fully-qualified sub-skill names:
  invoke sdlc:implement, sdlc:review, sdlc:pull-request — never the bare names
```

## User-Facing Output Conventions

```text
🟡 Waiting on you — paused at an input gate (Phase 0 resume menu, Phase 3 round prompt)
🛑 Hard stop       — Phase 6.5 verification gate; Phase 3 engineer-override pushback
🤖 Auto-resolved   — --auto took a deliver-owned gate decision unattended (recorded for audit)
❌ Error           — required step failed (no ticket key; a sub-skill aborted mid-flow)
⚠️  Warning        — advisory; not a pause (implement produced no commits; issue read failed)
✅ Done            — final completion summary (exactly one firing per session)
```

Gate rendering — every input gate is presented by INVOKING the AskUserQuestion tool, never as prose:

```text
for each 🟡 / yes-no / choice gate:
  question = gate name + one-line context (branch, verdict, what just happened)
  header   = ≤12-char gate label
  options  = the gate's enumerated choices, each → { label: terse choice, description: trailing clause }
             a stated default/preferred choice is listed FIRST with "(recommended)" appended to its label
  free-text answer (rationale, custom value) → the user's "Other" free-text reply
  the returned selection feeds the existing `match user_response` dispatch UNCHANGED —
             only the surface changes, never the gate's options, default, or downstream behavior

  if session.auto and the gate is an auto-resolvable happy-path gate:
    skip the tool; resolve per the auto contract; record 🤖
```

Invoke AskUserQuestion only when the user must act, one call per decision, in the canonical shape `AskUserQuestion → "{q}"; options:` then one `({tag}) "label"` per line. Sub-skills emit their own gates — never echo them. In `--auto`, each auto-resolved gate prints a 🤖 line; `session.auto_decisions` is the audit record.

---

## Shared contract — `parse_latest_round`

`review-file.js parse` is the one reader of the review; `sdlc:pull-request` reads verdict, round, and SHA from the same call.

```text
read_review():   # binds session.review_file
  (r, ec) = node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" parse --root "$(git rev-parse --show-toplevel)" --name '{session.name}'
  if ec != 0:      # 127 = no Node; 2 = unreadable file ({r.error})
    🛑 Hard stop — cannot read the review (exit {ec}): {r.error}; fix it, then re-run sdlc:deliver {session.ticket_key}
    if session.auto_decisions: print "Auto log:\n" + join(session.auto_decisions, "\n")
    exit
  session.review_file = "docs/code-reviews/" + session.name + "-code-review.md"; return r
parse_latest_round():
  r = read_review(); return (r.latest.verdict,                       # ✅ APPROVED | ⚠️ CHANGES REQUESTED | 🚫 BLOCKED
          r.latest.gate_status,                   # LOCKED… | OPEN… | OVERRIDDEN… | HUMAN_GATE…
          r.latest.counts.in,                     # {CRITICAL, HIGH, MEDIUM, LOW, INFO}
          r.latest.in_scope_findings,             # [{id, severity, title, location, recommendation}]
          r.version_advisories.findings)
```

The fix loop advances only on `LOCKED` (two consecutive clean rounds) or a recorded `OVERRIDDEN`. Use counts and findings in the round prompt and gate summary. Remediate in-scope MEDIUM+ findings. `sdlc:pull-request` lists LOW/INFO as advisories.

---

## Phase 0 — Entry + State Detection + Resume Menu

Goal: bind the ticket key, detect what has already been done for it, and let the engineer choose where to enter. Never silently auto-advance — except the `fresh` case.

```text
tokens = tokenize($ARGUMENTS)
session.auto     = ("--auto" in tokens)          # explicit opt-in; default false; NEVER persisted across runs
session.incident = ("--incident" in tokens)      # passed to sdlc:implement
session.no_slack = ("--no-slack" in tokens)      # passed verbatim to sdlc:pull-request (Phase 7)
# deliver owns no PE dispatch: it threads these verbatim to every sdlc:review call; implement gets neither.
session.review_model_flag = "--model-by-review-tier"    if "--model-by-review-tier" in tokens
                            else "--no-model-by-review-tier" if "--no-model-by-review-tier" in tokens
                            else ""
session.builds_arg = "--builds {v}" if tokens contain "--builds" followed by v else ""   # v other than worktree, checkout or off: ❌ Error naming the flag and its values; STOP
args_sans_flags = $ARGUMENTS minus all of the flags above (and the --builds value), whitespace collapsed

# User text reaches the script on stdin through a quoted heredoc — never as a shell argument.
k = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" key --anchored <<'TICKET_ARG'
{args_sans_flags}
TICKET_ARG
session.ticket_key   = k.ticket_key       # "#42" | "LT-02"; null unless the whole argument is one key
session.key_slug     = k.key_slug         # "42" | "LT-02"
session.issue_number = k.issue_number     # 42 | null (a story code)
if not session.ticket_key:
  ask the user for the issue number or story code, quoting k.error   # e.g. "take the login one" or "hello"
  restart Phase 0                                                      # re-parse the reply; flags may be re-supplied

session.review_args = join_nonempty([("--auto" if session.auto else ""), session.review_model_flag, session.builds_arg], " ")
session.name = session.key_slug
session.fix_round = 0          # bound here so menu paths that bypass Phase 3 (e.g. B(skip)) read a defined value
session.engineer = `gh api user --jq .login`; else the local part of `git config user.email`   # override-audit attribution
session.auto_decisions = []    # every auto-resolved deliver-owned gate appended here; rendered on every terminal path
```

Probe current state (all read-only):

```text
session.branch         = `git branch --show-current`
session.on_feature     = (node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" branch <<'BRANCH_NAME'
{session.branch}
BRANCH_NAME
                         ).on_feature
session.commits_ahead  = `git rev-list --count 'origin/main..HEAD'` if session.on_feature else 0
session.review_present = (read_review().rounds is non-empty) if session.on_feature else false   # binds session.review_file
session.spike_present  = (Glob("docs/spikes/" + session.key_slug + "-*.md") is non-empty)

# Issue status is informational for the menu only — warn-only, never blocks routing.
if session.issue_number:
  (t, ec) = `gh issue view {session.issue_number} --json title,labels`
  session.issue_status = the status:* label in t.labels, else "no status label" (ec != 0 → null with ⚠️)
```

Classify state and route:

```text
match (session.on_feature, session.commits_ahead, session.spike_present, session.review_present):
  case (false, _, _, _):                  # on main / detached / unrelated branch — nothing started
    session.entry = "fresh"
    notice "Starting fresh at sdlc:implement for {session.ticket_key}."
    goto Phase 0.5 if session.auto else Phase 1
  case (true, 0, _, _):          present Menu A    # branch exists, implement interrupted pre-commit
  case (true, >0, true, _):      present Menu D    # spike doc already committed
  case (true, >0, false, false): present Menu B    # code committed, never reviewed
  case (true, >0, false, true):  present Menu C    # code committed AND reviewed
```

For Menus A–D, read `${CLAUDE_PLUGIN_ROOT}/skills/deliver/references/resume-menus.md` and present the matching menu; the chosen option sets the entry phase.

---

## Phase 0.5 — Auto Consent Banner (--auto ONLY, deliver-owned)

Disclosure only (no reply), reached on `session.auto` AND `entry == "fresh"`. The auto stops are implement's plan gate (next phase) and any later Copilot confirm; this banner makes that approval informed consent.

```text
acs = the ticket's ACs + title + type: `gh issue view {session.issue_number} --json title,body,labels`, or the story file in docs/epics/; [] if unavailable

🤖 Auto-resolved — entering auto mode for {session.ticket_key} (fresh run, approved by @{session.engineer})
print (no reply — the plan approval below is your one decision now):
> AUTO MODE — {session.ticket_key} {title} ({type})
> Scope: {1–3 line AC summary, or "ACs unavailable — proceeding on ticket key only"}
> Your stop now is the upcoming PLAN approval{" (--incident: a plan reviewer answers it; you decide only on escalate)" if session.incident}. Approving it runs the rest unattended:
>   TDD implementation → sdlc:review to a LOCKED Gate 1 (auto-remediating every finding)
>   → PR opened → one Copilot confirm, only if a MEDIUM+ Copilot thread needs a decision
>   → issue labelled status:in-review{" → PR announced in Slack" if .claude/sdlc.json sets slack.enabled and not session.no_slack}.
> I will HALT and hand back if: it's a spike, a finding can't be resolved or stops making progress,
>   an override is needed, the fix loop trips its guard, or review's convergence controller escalates (HUMAN_GATE).

session.auto_decisions.append("Phase 0.5 — auto run consented for {session.ticket_key} by @{session.engineer}")
goto Phase 1
```

---

## Phase 1 — Implement (delegate to sdlc:implement)

```text
notice "Invoking sdlc:implement {session.ticket_key} ..."
invoke skill sdlc:implement with $ARGUMENTS = session.ticket_key + (" --auto" if session.auto else "") + (" --incident" if session.incident else "")
# implement owns: issue confirm, base/dirty gate, planning HARD STOP, TDD, Conventional Commits,
# status:in-progress, and the spike path. deliver adds NO gate here.
```

Capture the outcome via side effects (sub-skills return text only):

```text
session.branch              = `git branch --show-current`
session.commits_ahead       = `git rev-list --count 'origin/main..HEAD'`
session.spike_present       = (Glob("docs/spikes/" + session.key_slug + "-*.md") is non-empty)
session.code_outside_spikes = `git diff --name-only 'origin/main..HEAD'` has any path NOT under docs/spikes/

if session.spike_present and not session.code_outside_spikes:
  goto Phase S
if session.commits_ahead == 0:
  ⚠️ Warning — implement produced no commits (you likely stopped at a gate)
  ✅ Done — nothing to deliver yet; re-run sdlc:deliver {session.ticket_key} when ready
  if session.auto_decisions: print "Auto log:\n" + join(session.auto_decisions, "\n")
  exit
goto Phase 2
```

---

## Phase S — Spike Short-Circuit

```text
# sdlc:implement already wrote + committed the findings doc, printed its spike summary, and labelled the
# issue status:in-progress. There is no code to review or ship.
✅ Done — spike delivered (no PR)
  - Ticket:    {session.ticket_key}
  - Branch:    {session.branch}
  - Spike doc: {the docs/spikes/{key_slug}-*.md path}
  - Review:    skipped (research, no code)
  - PR:        skipped (nothing to ship)
if session.auto_decisions: print "Auto log:\n" + join(session.auto_decisions, "\n")
next: share the findings doc; if the decision is "build it", create a follow-up issue and re-run sdlc:deliver on it
exit
```

---

## Phase 2 — Review (delegate to sdlc:review)

```text
notice "Invoking sdlc:review on {session.branch} ..."
invoke skill sdlc:review with $ARGUMENTS = session.review_args   # auto-detects the current branch as the review target
# review owns: scope-banner confirm, PE dispatch, its own multi-round handling + override, and
# the review-file commit/push gate. deliver adds NO gate here.
goto Phase 3
```

---

## Phase 3 — Fix Loop (drive Gate 1 to LOCKED)

`sdlc:review` bounds the fix loop through its convergence controller, which locks Gate 1 or returns `HUMAN_GATE`. The engineer can record an override.

```text
session.fix_round = session.fix_round or 0

loop:
  (verdict, gate_status, counts, findings, version_advisory) = parse_latest_round()

  if gate_status starts with "LOCKED" or gate_status starts with "OVERRIDDEN":
    goto Phase 6.5                                  # Gate 1 closed: 2 consecutive clean, or recorded override

  if gate_status starts with "HUMAN_GATE — convergence controller error":   # a controller fault — the errored round never reached the ledger
    🛑 Hard stop — {gate_status}; see {session.review_file}; fix the ledger / input, remediate that round's findings, then re-run sdlc:deliver {session.ticket_key}
    if session.auto_decisions: print "Auto log:\n" + join(session.auto_decisions, "\n")
    exit

  if gate_status starts with "HUMAN_GATE" and session.auto:   # review's controller escalated — never auto-resolved
    🤖 Auto-resolved — HALT: {gate_status}
    session.auto_decisions.append("Phase 3 — auto HALTED: {gate_status}")
    session.auto = false
    🛑 Hard stop — handing back to interactive fix loop; open findings in {session.review_file}

  if verdict == "✅ APPROVED" and not gate_status starts with "HUMAN_GATE":
    # Clean round, gate still OPEN (1 of 2 consecutive clean). Earn the 2nd: re-run review at the
    # SAME SHA with a fresh PE dispatch. Two clean in a row → LOCKED; a finding here → back to fixing.
    notice "Round clean — running the confirmation round (fresh dispatch) to lock Gate 1 ..."
    invoke skill sdlc:review with $ARGUMENTS = session.review_args   # confirmation round; no code change
    continue

  # verdict != APPROVED → in-scope findings remain
  session.fix_round += 1
  gating   = [f for f in findings if f.severity in (CRITICAL, HIGH, MEDIUM)]   # LOW/INFO are advisory
  total    = counts.CRITICAL + counts.HIGH + counts.MEDIUM
  advisory = counts.LOW + counts.INFO

  if gating is non-empty and version_advisory:
    ⚠️ {version_advisory}

  # --auto: pick the default (remediate) unattended, UNLESS a halt condition fires. On any halt,
  # flip to interactive in this SAME iteration so the human sees the standard 🟡 prompt below.
  if session.auto:
    finding_sig = sorted set of (severity, location, title) over gating
    if session.last_finding_sig is defined AND finding_sig == session.last_finding_sig:
      🤖 Auto-resolved — HALT: no progress (identical findings after a remediation commit)
      session.auto_decisions.append("Phase 3 Round {session.fix_round} — auto HALTED: no progress (identical findings)")
      session.auto = false
      🛑 Hard stop — handing back to interactive fix loop; open findings in {session.review_file}
    elif session.fix_round > 8:                       # deliver auto-only guard; review's per-cycle round cap bounds every mode
      🤖 Auto-resolved — HALT: auto loop guard tripped at round {session.fix_round} (cap 8)
      session.auto_decisions.append("Phase 3 Round {session.fix_round} — auto HALTED: loop guard (cap 8)")
      session.auto = false
      🛑 Hard stop — handing back to interactive fix loop; open findings in {session.review_file}
    else:
      session.last_finding_sig = finding_sig
      🤖 Auto-resolved — fix loop Round {session.fix_round}: remediate ALL ({total} in-scope)
      session.auto_decisions.append("Phase 3 Round {session.fix_round} — auto-remediated {total} in-scope finding(s)")
      user_response = "yes"                           # auto picks the default; override/stop are human-only

  if not session.auto:                                # interactive — incl. a run just handed back by a halt above
    🟡 Waiting on you — fix loop, Round {session.fix_round}
    gate_prefix = "🛑 {gate_status} — " if gate_status starts with "HUMAN_GATE" else ""   # the controller's reason stays visible after a handback
    AskUserQuestion → "{gate_prefix}{total} in-scope findings ({counts.CRITICAL} C · {counts.HIGH} H · {counts.MEDIUM} M; +{advisory} advisory, not remediated) — how to proceed?"; options:
      (yes)      "Remediate ALL findings + re-review (recommended)"
      (override) "Proceed with findings open — I push back first"
      (stop)     "Halt; open findings remain in the review file"
    user_response = reply

  match user_response:
    case stop:
      ✅ Done — stopped mid-loop; open findings remain in {session.review_file}; PR not created
      if session.auto_decisions: print "Auto log:\n" + join(session.auto_decisions, "\n")
      exit
    case override:
      goto Engineer Override
    case yes:                                         # default; auto always lands here
      # remediate EVERY in-scope finding — directly, or via a spawned developer subagent for disjoint
      # areas. NEVER re-invoke sdlc:implement (it re-reads the issue, re-plans, and re-gates).
      for f in gating:                                # advisory LOW/INFO are never remediated
        if session.auto and (f.recommendation is unactionable OR applying it errors):
          🤖 Auto-resolved — HALT: cannot auto-apply [{f.severity}] {f.title} ({f.location})
          session.auto_decisions.append("Phase 3 Round {session.fix_round} — auto HALTED: cannot auto-apply [{f.severity}] {f.title} ({f.location})")
          session.auto = false
          🛑 Hard stop — handing back to interactive fix loop; open findings in {session.review_file}
          session.fix_round -= 1                       # undo this iteration's increment; the handback re-enters loop top and re-counts
          continue loop                               # re-enter loop top → interactive 🟡 prompt
        apply f.recommendation
      run targeted verification (tests / build / lint touched by the fixes)
      `git commit -m "fix: address review feedback, round {session.fix_round}"`
      notice "Re-invoking sdlc:review ..."
      invoke skill sdlc:review with $ARGUMENTS = session.review_args   # new SHA → new round
      continue
```

### Engineer Override (mandatory pushback, recorded)

deliver advances on an override only after pushing back on every open MEDIUM+ finding; advisory LOW/INFO need no override. Read `${CLAUDE_PLUGIN_ROOT}/skills/deliver/references/override.md` and run it: it restates each finding, requires an explicit confirmation plus a reason, records the override in the review file, and routes to Phase 6.5 (or back to the fix loop if not confirmed).

---

## Phase 6.5 — Verification Gate (HARD STOP, deliver-owned)

Reached when Gate 1 is `LOCKED` or `OVERRIDDEN`, or via Menu B(skip), where the engineer explicitly skips review. This gate verifies the WORK does what the ticket asked — it is NOT finding triage. A locked gate is necessary but NOT sufficient: the human still chooses.

```text
if read_review().rounds is empty:                  # Menu B(skip) — review skipped; nothing to parse
  (verdict, gate_status, counts) = ("— (no review)", "SKIPPED — engineer chose to proceed without review", all-zero)
else:
  (verdict, gate_status, counts, _, _) = parse_latest_round()
acs = re-read the ticket's ACs (gh issue view, or the story file); [] if unavailable
      # sub-skills communicate via side effects, not shared session

show:
  - Branch {session.branch} · {session.commits_ahead} commits · Gate 1 {gate_status} · review {verdict} · {session.fix_round} fix round(s) this session
  - If OVERRIDDEN: list the overridden findings + reason up front — the human is consciously accepting them
  - If SKIPPED: state plainly that no sdlc:review round backs this work; sdlc:pull-request raises its
    own no-review gate downstream — deliver does not add a second one
  - What changed: one line per major change
  - De-scoped findings (follow-up issue refs, if any) + out-of-scope awareness items
  - AC check: each AC with a brief status line
  - Suggested verification: commands tailored to the change (run it; exercise an AC edge case)

if session.auto:                                    # consent for the PR was given up front (Phase 0.5 + plan approval)
  🤖 Auto-resolved — Phase 6.5 verification gate AUTO-APPROVED
  session.auto_decisions.append(
    "Phase 6.5 — auto-approved: branch {session.branch}, Gate 1 {gate_status}, verdict {verdict}, {session.fix_round} fix round(s)")
  goto Phase 7

🛑 Hard stop — Phase 6.5 verification gate
AskUserQuestion → "Verification gate — approve to proceed to the PR?"; options:
  (a) "Approve — proceed to Phase 7 (sdlc:pull-request)"
  (b) "Request changes — describe what, or make changes yourself and say 'done'"
  (c) "Stop — exit with summary"

match user_response:
  case (a):
    goto Phase 7
  case (b):
    if user described changes: apply them (directly or via a spawned developer subagent) + commit
    elif user is making them:  wait for "done"; ensure the changes are committed
    session.fix_round = 0                           # RESET — new work re-enters the loop, drives back to a locked gate
    goto Phase 2
  case (c):
    ✅ Done — stopped at the verification gate
      branch {session.branch} · verdict {verdict} · review {session.review_file}
      PR NOT created
    if session.auto_decisions: print "Auto log:\n" + join(session.auto_decisions, "\n")
    exit
```

There is no cap on Phase 6.5 ↔ review/fix-loop cycles; inside the loop, `sdlc:review`'s convergence controller (round cap 8 per cycle, reset after each lock; reopen-guard) guarantees each review cycle terminates in a lock or `HUMAN_GATE`.

---

## Phase 7 — Pull Request (delegate to sdlc:pull-request)

```text
notice "Invoking sdlc:pull-request ..."
invoke skill sdlc:pull-request with $ARGUMENTS = join_nonempty([("--auto" if session.auto else ""), ("--no-slack" if session.no_slack else "")], " ")
# pull-request owns ALL of: gh pre-flight, branch/commit validation, review-verdict consumption, reviewers,
# PR description, push, gh pr create, the CI check, the Copilot review (it asks only when a Copilot thread
# needs a decision), status:in-review + the progress comment, and the optional Slack announcement.
# deliver adds no gate and re-asks nothing here.
goto End
```

---

## End — Completion Summary

```text
✅ Done — delivered {session.ticket_key}{" (AUTO)" if session.auto else ""}
  - Branch:   {session.branch}
  - Review:   {final verdict} (round {n}) · {session.review_file}
  - Fix loop: {session.fix_round} automated round(s) this session
  - PR:       opened by sdlc:pull-request (see its summary above)
  - Issue:    → status:in-review (by sdlc:pull-request; a story code without an issue has no label)
if session.auto_decisions:                          # gates auto-resolved this run, for after-the-fact audit
  - Auto log:
      {each entry in session.auto_decisions, one per line}
next: await reviewer activity; nudge an idle PR via /sdlc:pull-request #N
```

---

## Key Rules

- **Never re-invoke sdlc:implement to fix review findings** — remediate directly or via a developer subagent; re-invoking implement re-plans and re-gates.
- **No silent skips** — a finding reaches the PR unfixed only via a recorded engineer override, and only after the agent pushes back on it (every MEDIUM+ finding); advisory LOW/INFO reach the PR listed, never silently.
- **A resume is never silently upgraded** — a resumed run is auto only when `--auto` was passed THIS invocation.
