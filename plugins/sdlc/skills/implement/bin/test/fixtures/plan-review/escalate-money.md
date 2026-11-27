```plan-review-verdict
{
  "verdict": "ESCALATE",
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
      "status": "fail",
      "note": "changes the late-fee rounding rule"
    },
    "prevention": {
      "status": "pass",
      "note": "ok"
    }
  },
  "adjustments": [],
  "follow_ups": [
    {
      "title": "Add a monitor on late-fee job duration",
      "kind": "prevention",
      "why": "would have paged before customers noticed"
    }
  ],
  "rollback": "revert the PR; no data migration",
  "escalation": {
    "reasons": [
      "money-semantics"
    ],
    "concern": "The plan changes how late fees round, not just the timeout; a person must decide the fee rule."
  }
}
```
