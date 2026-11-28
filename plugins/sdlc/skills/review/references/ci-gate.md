# Gate 2 CI Gate

Loaded by Phase 6 for a Gate 2 round, before the severity-gated verdict. Gate 2 never approves over failed checks on HEAD's code: it binds `session.ci` (read by `gate2` and by `publish.md` Step 4) and, when a check on HEAD failed, adds a CRITICAL finding to `consolidated`.

```text
(ci, ec) = `cd "{session.review_root}" && node "${CLAUDE_PLUGIN_ROOT}/bin/pr-checks.js" check --pr {session.pr.number} --head {session.head_sha} --settle 30`
if ec != 0 or ci is not JSON:                      # fail closed — unread checks never clear the gate (includes "HEAD is not the PR head")
  session.ci = {state: "unreadable", reason: ci.error if ci and ci.error else trim(stderr) or "pr-checks.js exit {ec}"}
else:
  session.ci = {state: ci.state, reason: ci.reason, failed_checks: ci.failed_checks}

if session.ci.state == "failed":
  logs = []
  for c in session.ci.failed_checks where c.run_id:
    tail = last 40 lines of `gh run view {c.run_id} --log-failed`     # empty or failing → "log unavailable"
    logs += ["{c.name}: {tail}"]
  append to consolidated:
    severity:       CRITICAL
    in_scope:       true
    domains:        ["CI"]
    category:       "correctness"
    title:          "CI checks failed on HEAD's code"              # fixed — ledger fingerprint stays stable across rounds
    location:       "(ci-checks)"                                  # fixed sentinel, same reason
    description:    "Checks on {session.head_sha} failed: {each failed_check as "{name} ({link})", or "none listed"}.
                     Failed-step logs: {logs joined, or "none (external CI)"}"
    recommendation: "Fix the failing check(s) and push so they run green on HEAD's code, then re-run Gate 2."
    verification_receipt: the first failed_check link

render "  🔎 CI: {session.ci.state} — {session.ci.reason}"
```

| `session.ci.state` | Gate 2 effect |
| - | - |
| `passed`, `none` | no CI finding; MERGEABLE follows the reviewers' GitHub reviews. `none` is final only after `--settle 30`: when `.github/workflows/` holds any workflow, the script polls up to 30s for checks to register, then reads the head's workflow runs, the newest per workflow and event (a run that failed to start reports no check: `failed`; one queued or awaiting approval: `pending`; one cancelled: `incomplete`). A `passed` read is checked against the runs the same way, so a run that failed to start beside green checks is `failed` |
| `failed` | CRITICAL finding → 🚫 BLOCKED; `gate2` returns `OPEN — Gate 2 CI failed: …` |
| `pending`, `incomplete` | no finding; `gate2` returns `OPEN — Gate 2 waiting on CI: …`; no PR approval |
| `unreadable` | no finding; `gate2` returns `OPEN — Gate 2 CI status unreadable: …`; no PR approval |
