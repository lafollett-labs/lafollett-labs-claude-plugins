### Added
- **sdlc**: `review` tracks finding lineage. Each finding lists its `siblings`, the other
  places that state or repeat what its fix changes, and from round 2 names what
  `introduced_by` it (a prior finding's fix, still present, new, missed or pre-existing).
  Round 2+ dispatches carry the fix diff and the remediator's ripple receipts, and the
  review shows each round's fix cascade. After a round with gating findings, `review`
  prints a remediation pre-flight.
