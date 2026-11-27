```plan-review-verdict
{
  "verdict": "APPROVE",
  "checks": {
    "evidence": {
      "status": "pass",
      "note": ""
    },
    "narrowest": {
      "status": "pass",
      "note": ""
    },
    "safety": {
      "status": "pass",
      "note": ""
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
  "escalation": null
}
```
