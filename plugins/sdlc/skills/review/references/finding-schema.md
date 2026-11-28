# Finding Schema

Loaded by SKILL.md at Phase 4, before `findings.js validate`. The model transcribes each PE's YAML block into the JSON that `findings.js` reads — field for field, no edits.

## YAML Schema

PE sub-agents return findings in this exact format. `findings.js validate` enforces it.

```yaml
expert: <expert ID>                       # the ID the agent definition declares; findings.js replaces it with the dispatched pe
tier_escalation:                          # OPTIONAL — only when the dispatched TIER cannot reach what the diff touches
  requested_tier: STANDARD|DEEP           # must rank strictly above the dispatched TIER
  justification: "one line: what the diff touches that the dispatched tier cannot reach"
findings:
  - id: "CRITICAL-001"
    severity: CRITICAL|HIGH|MEDIUM|LOW|INFO
    in_scope: true|false
    is_pattern: true|false                  # true → triggers bug-shape grep in Phase 4
    category: data-integrity|migration|auth|secrets|security|correctness|concurrency|error-handling|performance|test-coverage|maintainability|docs|general   # REQUIRED — feeds the findings-ledger fingerprint + severity floor
    title: "Brief issue title"
    location: "src/full/path/from/repo/root.ts:123"
    locations: []                           # additional sites populated by Phase 4 bug-shape grep
    description: |
      Full description of the issue.
    recommendation: |                       # REQUIRED — concrete fix, not "consider X"
      How to fix it with code example if helpful.
    verification_receipt: |                 # Pass 5 receipt — grep result, test output, code reference
      Confirmed by `grep -rn "..." src/` returning N matches; tests at tests/foo.spec.ts:42 cover this path.
    move: M1|M2|M3|M4|M5|M6|M7|none          # the review move whose trigger it falls under; missing or unknown → none
    siblings: ["docs/a.md:12"]               # review-moves.md § Finding Keys — a list of path:line; missing → []
    introduced_by: MEDIUM-004|still-present|new|missed|pre-existing   # REQUIRED on round 2+ (prior_ids set)
moves_coverage:                              # REQUIRED — review-moves.md § Output; M1..M7 once each
  - move: M1
    status: applied|n/a
    checked: "2 changed contracts → 9 consumers grepped"   # REQUIRED when applied — what was examined, with a count
    note: ""                                 # REQUIRED when n/a — why no unit triggered the move
verification_receipts:                       # non-gating — items failing the PE REPORTING BAR + positive attestations; no recommendation
  - id: "RECEIPT-001"
    claim: absence|positive|below_bar|indeterminate   # REQUIRED — set by the PE; only absence is proof-checked (Phase 5)
    title: "Verified no other sites of bug-shape X"
    location: "src/"
    attestation: |
      No other sites of the bug shape exist; both known sites fixed in commit abc123.
    evidence: |                              # REQUIRED when claim: absence (Phase 5 § Negative-receipt proof check)
      $ grep -rn "bug-shape-X" src/
      src/a.ts:12  src/b.ts:40   (2 matches — both fixed)
    missing_source: "catalog-api repo"      # REQUIRED when claim: indeterminate because the source is outside SEARCH_ROOTS; never proof-checked
    category: auth                          # set on absence receipts (same enum as findings); receipts remain non-gating
```

## Schema enforcement

```text
finding without a concrete recommendation (empty, or opening with consider | review whether | think about | maybe | perhaps):
                                            → re-dispatch the PE once, then demote to a below_bar receipt (findings.js)
finding with an invalid severity:           → normalized first ("🔴 CRITICAL" → CRITICAL); else re-dispatch once, then record as MEDIUM (findings.js)
finding category outside the enum:                             → re-dispatch once, then record as general + note it (findings.js)
receipt without a valid claim:                                 → re-dispatch once, then treat as claim: absence (findings.js)
moves_coverage missing, short of a move, or an entry without its counted checked / note:
                                            → re-dispatch once, then keep the findings and record the gap in coverage_gaps (findings.js)
siblings not a list of path:line, or round 2+ introduced_by outside prior_ids ∪ the four labels:
                                            → re-dispatch once, then siblings: [] / introduced_by: null + a coverage_gaps entry (findings.js)
verification_receipts[] missing/empty:                         → ACCEPT (default to [])
finding without a verification_receipt proving the problem:     → DEMOTE to a receipt with the original claim + missing proof, never dropped; disproven → dismissed (Phase 5)
absence receipt without whole-claim evidence:                  → re-dispatch PE once, then retain as a receipt unless a finding proves an actual problem (Phase 5)
indeterminate receipt (missing_source set):                    → ACCEPT; never proof-checked or promoted (Phase 5)
tier_escalation present:                                       → handled by the tier escalation check (not a violation)
```
