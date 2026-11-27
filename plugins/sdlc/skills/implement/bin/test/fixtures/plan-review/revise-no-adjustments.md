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
      "note": "too broad"
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
  "escalation": null
}
```
