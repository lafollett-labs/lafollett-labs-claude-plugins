# Phase 7 — Copilot Review

Loaded by `sdlc:pull-request` after Phase 6 on the author path, before the issue label and the Slack announcement. Reads and writes the same `session.*` state as the body.

```text
if session.no_copilot or session.pr_number is null:
  session.copilot_line = "skipped" + (" (--no-copilot)" if session.no_copilot else ""); session.slack_copilot_line = null
  exit Phase 7
if session.intent_gate == "(b) manual":
  AskUserQuestion → "Request a Copilot review on #{session.pr_number}? (uses Copilot review quota)"; options:
    (yes) "Request it (recommended)"
    (no) "Skip Copilot"
  if no: session.copilot_line = "skipped"; session.slack_copilot_line = null; exit Phase 7

run sdlc:copilot-review with "#{session.pr_number}" + (" --auto" if session.auto)   # requests, waits, evaluates
read its copilot-review-result block → res

match res.status:
  "complete":
    session.copilot_line = "{len(res.findings)} finding(s): {count per disposition}" (or "nothing new to act on")
    if res.coverage == "partial": append " — ⚠ Copilot skipped some changed files"
    if res.coverage == "unknown": append " — ⚠ Copilot's coverage is unknown"
    if res.warnings:              append " — ⚠ " + join(res.warnings, "; ")
    if res.answered:              append " — {len(res.answered)} Copilot thread(s) you answered earlier are still open"
    append the gate outcome:
      applied → " — applied at your confirmation" · declined → " — declined; nothing posted"
      unanswered → " — not confirmed; no fix posted — run /sdlc:copilot-review #{session.pr_number} to act"
      not_needed → " — no decision needed" · read_only → " — not acted on (checkout is not the PR's branch)"
  "quota_exhausted":
    session.copilot_line = "Copilot review quota exhausted — no review this run"
  else:
    session.copilot_line = the skill's one-line report

session.slack_copilot_line = null if res.status != "complete"
                             else "Copilot: {res.copilot_rounds} round(s) · {res.fixed or 0} fixed" + (" · {res.open} open" if (res.open or 0) > 0 else "")

if res.fixed > 0:                                # a fix was pushed; Phases 8–9 report the settled head
  re-read session.head_sha and session.file_stats
  remove the Phase 6 CI caveat line from session.slack_caveat
  re-run the Phase 6 CI validation gate on the new head without its prompt (the caveat append only)
# Never fails the PR flow: an error, timeout or exhausted quota is reported and the run continues to Phase 8.
```
