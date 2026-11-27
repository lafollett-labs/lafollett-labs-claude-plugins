Remove the refactor.

```plan-review-verdict
{
  "verdict": "REVISE",
  "checks": {
    "evidence": {
      "status": "pass",
      "note": "ok"
    },
    "narrowest": {
      "status": "fail",
      "note": "bundles a FineCalculator refactor"
    },
    "safety": {
      "status": "pass",
      "note": "ok"
    },
    "prevention": {
      "status": "pass",
      "note": "ok"
    }
  },
  "adjustments": [
    "Drop the FineCalculator extraction; it goes to a follow-up",
    "Keep only the index hint on the overdue-loans query"
  ],
  "follow_ups": [
    {
      "title": "Extract FineCalculator into a shared service",
      "kind": "scope",
      "why": "removed from the fix: refactor not needed to stop the timeout"
    },
    {
      "title": "Add a monitor on overdue-notice job duration",
      "kind": "prevention",
      "why": "would have alerted before members noticed"
    }
  ],
  "rollback": "revert the PR; no data migration",
  "escalation": null
}
```
