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
      "note": "bundles a FeeCalculator refactor"
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
    "Drop the FeeCalculator extraction; it goes to a follow-up",
    "Keep only the index hint on the late-fee query"
  ],
  "follow_ups": [
    {
      "title": "Extract FeeCalculator into a shared service",
      "kind": "scope",
      "why": "removed from the fix: refactor not needed to stop the timeout"
    },
    {
      "title": "Add a monitor on late-fee job duration",
      "kind": "prevention",
      "why": "would have paged before customers noticed"
    }
  ],
  "rollback": "revert the PR; no data migration",
  "escalation": null
}
```
