# Gate 2 CI Gate

Loaded by Phase 6 for a Gate 2 round, before the severity-gated verdict. Gate 2 never approves over failed checks on HEAD's code: it binds `session.ci` (read by `gate2` and by `publish.md` Step 4) and, when a check on HEAD failed, adds a CRITICAL finding to `consolidated`.

```text
read_ci():
  (ci, ec) = `cd "{session.review_root}" && node "${CLAUDE_PLUGIN_ROOT}/bin/pr-checks.js" check --pr {session.pr.number} --head {session.head_sha}`
  if ec != 0 or ci is not JSON:                    # fail closed — unread checks never clear the gate (includes "HEAD is not the PR head")
    return {state: "unreadable", reason: ci.error if ci and ci.error else trim(stderr) or "pr-checks.js exit {ec}"}
  return {state: ci.state, reason: ci.reason, failed_checks: ci.failed_checks}

session.ci = read_ci()
if session.ci.state == "none" and `grep -qsE 'pull_request' "{session.review_root}"/.github/workflows/*.yml "{session.review_root}"/.github/workflows/*.yaml` exits 0:
  wait 30 seconds; session.ci = read_ci()         # checks register a few seconds after a push: read once more before accepting none

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
| `passed`, `none` | no CI finding; MERGEABLE follows the reviewers' GitHub reviews. `none` counts only after one re-read ~30s later when a workflow under `.github/workflows/` has a `pull_request` trigger |
| `failed` | CRITICAL finding → 🚫 BLOCKED; `gate2` returns `OPEN — Gate 2 CI failed: …` |
| `pending`, `incomplete` | no finding; `gate2` returns `OPEN — Gate 2 waiting on CI: …`; no PR approval |
| `unreadable` | no finding; `gate2` returns `OPEN — Gate 2 CI status unreadable: …`; no PR approval |
