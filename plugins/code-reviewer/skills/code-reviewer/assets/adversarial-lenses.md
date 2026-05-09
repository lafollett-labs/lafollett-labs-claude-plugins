# Pass 4 — Adversarial Re-read (Common Lenses + Calibration + Apply Protocol)

This asset is loaded by every production-grade PE sub-agent (`pe-go`, `pe-vue`, `pe-aws-infra`, `pe-governance`) at the start of Pass 4. It defines the six common adversarial lenses, the calibration anchor that prevents over-firing, and the application protocol.

`pe-devtools` does NOT load this asset; it has its own calibrated `operator_normal_use` lens set (single-operator local threat model) inline in its agent file.

---

## Calibration Anchor (read BEFORE applying any lens)

Pass 4 is a **catch net**, not a **ratchet**. Its purpose is to surface defects that hid in plain sight during Passes 1-3, NOT to manufacture new findings round-after-round on closed-set themes.

```
PASS 4 SEVERITY DISCIPLINE:
  Default severities below are CEILINGS, not floors. Apply the SKILL.md
  Severity Definitions calibration anchor:
    MUST FIX = actual defects, security issues, regressions
    LOW + INFO = awareness-only, do NOT block

  Apply each lens VIVIDLY but HONESTLY. If applying a lens forces you to
  imagine an unlikely scenario (contrived attacker, scale 1000x not 10x,
  exotic partial-failure path with no real-world precedent), the finding
  is INFO at best — likely omit.

ROUND-OVER-ROUND DISCIPLINE:
  Each lens has different angles. On round 2+, the temptation is to
  surface NEW findings under a different angle of the SAME closed-set
  theme that round 1 already addressed.

  before flagging a NEW Pass 4 finding on round 2+:
    if theme was raised in round 1 AND remediated:
      do NOT re-flag under a different lens-angle
      that's the convergence-spiral failure mode
    if theme is genuinely NEW (different code area, different category):
      flag honestly with proper severity

CLOSED-SET CONVERGENCE:
  When the diff converges (Passes 1-3 produce no new findings, all prior
  in-scope CRITICAL/HIGH/MEDIUM remediated), Pass 4 should also converge.
  Pass 4 surfacing fresh issues on every round means the lenses are
  over-firing — STOP before adding the finding and ask:
    "Would a senior reviewer reading the diff today, blind to round 1's
     findings, independently flag this as MUST-FIX?"
  If no, downgrade to LOW or INFO.

THE PHASE 5 VALIDATION BAR APPLIES:
  Every Pass 4 finding must pass Phase 5 Finding Validation before
  publishing. Re-read SKILL.md § Phase 5: Finding Validation. Pass 4
  findings that fail the validation checklist (actually exploitable?
  real risk not theoretical? would a senior agree blocks PR?) get
  downgraded or omitted.
```

The lenses below describe WHAT to look for. The Calibration Anchor governs HOW HARD to flag. Working code that passes its tests and meets its acceptance criteria SHOULD reach `✅ APPROVED` by round 2 of a typical PR.

---

## Common Lenses (apply to every diff)

```
hostile_attacker:
  Re-read the diff as someone scanning for:
    - privilege escalation paths
    - authentication / authorization bypass
    - race conditions exploited by parallel requests
    - undocumented escape hatches (debug routes, admin override flags)
    - defaults that fail open (auth absent → allowed)
    - validation that runs after the action it's meant to gate
    - caller-controlled input flowing into a trust decision without server-side verify
  if a NEW attack vector overlooked by Pass 3:
    flag CRITICAL "<vector> — <how it would be exploited>"

scale_10x:
  Re-read assuming current load × 10. For each query, allocation, lock
  acquisition, network call: what fails first?
    - memory pressure (unbounded slice/map/cache growth)
    - connection pool exhaustion (DB, HTTP, downstream)
    - lock contention (mutex held during I/O)
    - tail latency (single slow dependency dominates p99)
    - quota / rate limit collisions
    - fan-out without back-pressure
  if the diff introduces a scale cliff:
    flag HIGH "scale risk at 10x — <what fails first, why>"

junior_in_one_year:
  Re-read as a junior engineer joining 12 months from now who must change
  something here. What is NOT obvious from naming/structure?
    - subtle invariants ("must call X before Y" / "only valid when Z is set")
    - coupling that crosses package/component boundaries silently
    - magic numbers / strings without rationale
    - rhyming-with-reality naming (Manager, Helper, Service, Util)
    - implicit ordering dependencies between async operations
  if the diff hides a subtle invariant:
    flag MEDIUM "implicit invariant — <what they'll miss when modifying>"

prod_incident_2am:
  Re-read as oncall paged at 2am with this system in alarm.
    - can you tell from logs / metrics what is failing?
    - does the failure mode have a clear signature?
    - are correlation IDs / request IDs / tenant IDs in the log line?
    - does the alarm point at the right component (not three layers up)?
    - is the runbook entry obvious from the error message?
  if observability is missing for a failure mode:
    flag MEDIUM "no observability for <failure mode> — <what's missing>"

partial_failure:
  Re-read assuming every external call fails 30% of the time. For each
  multi-step operation: what state survives partial completion?
    - DB write succeeds, event publish fails — orphaned state
    - email sent, audit log fails — drift from source-of-truth
    - cache updated, source-of-truth fails — wrong-answer steady state
    - retry loop without idempotency token — duplicate side effects
    - compensation action that itself can fail
  if partial-failure paths leave inconsistent state:
    flag HIGH "partial-failure inconsistency — <step that fails leaves <state>>"

silence_check:
  Re-read looking for SILENT failures. Anywhere errors are:
    - discarded (`_ = ...`, empty catch, ignored Promise rejection)
    - logged but flow continues when it should stop
    - retried indefinitely without a limit or backoff cap
    - timeouts default to infinite (no deadline)
    - wrapped in a way that loses the original
    - panic / exception recovered without alerting
  Stack-specific examples appear in each PE's Pass 4 section.
  if anything fails silently:
    flag HIGH "silent failure — <what's swallowed, where>"
```

---

## How to Apply Pass 4

```
for each lens (common + stack-specific):
  re-read the diff WITH THAT LENS IN MIND
  if a NEW finding surfaces (not already in Passes 1-3):
    pass it through the Calibration Anchor checklist above
    if it survives:
      add it to YAML output
      tag the surfacing lens in description: "Surfaced via Pass 4 / <lens_name>."
      use the lens's default severity unless judgment overrides DOWN

  if a lens surfaces NO new findings:
    OK — but you must have actually applied it
    skipping == dispatch-contract violation
```
