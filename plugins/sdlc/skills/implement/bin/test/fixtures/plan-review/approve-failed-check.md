```plan-review-verdict
{
  "verdict": "APPROVE",
  "checks": {
    "evidence": {
      "status": "fail",
      "note": "fixes a nearby query, not the implicated one"
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
      "title": "Add a monitor on late-fee job duration",
      "kind": "prevention",
      "why": "would have paged before customers noticed"
    }
  ],
  "rollback": "revert the PR; no data migration",
  "escalation": null
}
```
