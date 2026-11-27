The plan targets the implicated query and adds a failing test first.

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
  "adjustments": [
    "Name the failing test after the incident symptom"
  ],
  "follow_ups": [
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
