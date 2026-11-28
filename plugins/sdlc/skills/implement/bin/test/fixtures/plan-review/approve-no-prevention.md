```plan-review-verdict
{
  "verdict": "APPROVE",
  "checks": {
    "evidence": {
      "status": "pass",
      "note": "ok"
    },
    "narrowest": {
      "status": "pass",
      "note": "ok"
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
  "adjustments": [],
  "follow_ups": [
    {
      "title": "Extract FineCalculator into a shared service",
      "kind": "scope",
      "why": "removed from the fix: refactor not needed to stop the timeout"
    }
  ],
  "rollback": "revert the PR; no data migration",
  "escalation": null
}
```
