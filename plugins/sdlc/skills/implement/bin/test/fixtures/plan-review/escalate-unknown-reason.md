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
      "title": "Add a monitor on overdue-notice job duration",
      "kind": "prevention",
      "why": "would have alerted before members noticed"
    }
  ],
  "rollback": "revert the PR; no data migration",
  "escalation": {
    "reasons": [
      "vibes"
    ],
    "concern": "feels risky"
  }
}
```
