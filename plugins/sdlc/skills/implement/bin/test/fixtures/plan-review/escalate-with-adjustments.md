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
      "note": "changes the overdue-fine rounding rule"
    },
    "prevention": {
      "status": "pass",
      "note": "ok"
    }
  },
  "adjustments": [
    "Drop the 25-cent fine cap; it goes to a follow-up",
    "Keep the current fine rounding unchanged"
  ],
  "follow_ups": [
    {
      "title": "Add a monitor on overdue-notice job duration",
      "kind": "prevention",
      "why": "would have alerted before members noticed"
    }
  ],
  "rollback": "revert the PR; no data migration",
  "escalation": {
    "reasons": [
      "business-rule-semantics"
    ],
    "concern": "The plan changes how overdue fines round, not just the timeout; a person must decide the fine rule."
  }
}
```
