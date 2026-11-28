# Legitimacy Gate

Loaded by SKILL.md at Phase 4, after `findings.js dedup` binds `consolidated`. Cross-PE checks and the bug-shape grep finish Phase 4; Phase 5 keeps only legitimate findings rated at the severity their impact earns; Phase 5.5 adds unmet acceptance criteria. Illegitimate findings are culled here, never allowed to reach the review file or trigger remediation.

## Contents

- Cross-PE verification (multi_pe only)
- Bug-shape grep
- Negative-receipt proof check
- Per-finding receipt check
- Skill-level second pass
- Severity adjustment
- Phase 5 → Phase 7 data flow
- Acceptance-criteria conformance (Phase 5.5)

## Cross-PE verification (multi_pe only)

When two or more PEs ran, read across their results for one contract seen from both sides: a value one side sets and the other reads, a permission granted and the call that needs it, an auth boundary declared and the code that enforces it. Raise a finding only with source proof from both sides, rated from SKILL.md § Severity Definitions, and pass it through § Per-finding receipt check like any other.

## Bug-shape grep

For every finding whose root cause is a PATTERN, not a single instance:

```text
for finding in consolidated where finding.is_pattern:   # the PE marks a shape that may recur
  grep_pattern = derive a shape regex from the finding (e.g. "goto Phase 4" or "ac_index without bounds check")
  for match in grep(grep_pattern, scope = changed_files ∪ adjacent_files):
    if match.location != finding.location and match.location not in finding.locations:
      finding.locations += [match.location]
```

## Negative-receipt proof check

Runs FIRST, so a re-emitted finding flows through every later Phase 5 check. The PE classifies each receipt (`claim:`, validated in Phase 4); only `claim == absence` is proof-checked. An indeterminate receipt is never proof-checked or promoted.

```text
proven(r) = r.evidence contains a command AND its output AND that evidence exercises the WHOLE claim
            # else unproven: no evidence, OR the evidence covers only part of the claim
out_of_bounds(r) = r.claim == "indeterminate" AND r.missing_source is non-empty   # a document claim whose source is outside SEARCH_ROOTS

unproven = {}                                # teammate name → [receipt]
for name, pe_output in collected_outputs.items():
  for receipt in pe_output.verification_receipts:
    if receipt.claim == "absence" and not proven(receipt):
      unproven[name] += [receipt]

for name, receipts in unproven:              # ONE re-dispatch per teammate listing ALL its unproven receipts — never a loop
  SendMessage(to: name, summary: "prove absence receipts", message:
    "These absence receipts lack proof covering the whole claim: {titles}. For EACH reply with ONE corrected
     YAML entry keyed by its id: the receipt with `evidence:` (the command + its output exercising the
     claimed-impossible path), the receipt narrowed to exactly what you ran, the receipt as claim: indeterminate
     with missing_source: when the claim's source lies outside SEARCH_ROOTS, or a finding. Keep the SAME id
     (e.g. `id: RECEIPT-003`) even when the entry is now a finding.")
  snapshot = collected_outputs[name]          # the Collect loop overwrites collected_outputs[name] with the partial reply
  pending.add(name); re-enter the Collect loop until the reply arrives (nudge / escalation apply as usual)
  reply_entries = collected_outputs[name]; collected_outputs[name] = snapshot   # restore the full output; merge the reply by id below
  for receipt in receipts:
    reply = the entry in reply_entries whose id == receipt.id, else None
    if reply is a finding:
      remove receipt from snapshot.verification_receipts
      run it through `findings.js validate` (input `moves_checked: [name]`, `prior_ids: session.prior_ids`; Phase 4 settled its coverage) + `dedup` (SKILL.md Phase 4); append the survivor to consolidated
    elif (reply is None                                                       # no reply == unproven
          or (reply.claim == "absence" and not proven(reply))
          or (reply.claim != "absence" and reply.attestation == receipt.attestation
              and not out_of_bounds(reply))):                                # relabelled, not narrowed
      replace receipt in snapshot.verification_receipts, preserving id, title, location and category:
        claim: below_bar                       # an unproven safety claim does not prove a defect
        attestation: "Absence unproven after one re-dispatch. Original claim: {receipt.attestation}"
    else:
      replace receipt with reply in snapshot.verification_receipts   # proven, or narrowed to exactly what was run
  for reply in reply_entries whose id matches no receipt:           # a re-id'd finding (e.g. HIGH-001) is still a finding
    if reply is a finding:
      run it through `findings.js validate` (input `moves_checked: [name]`, `prior_ids: session.prior_ids`; Phase 4 settled its coverage) + `dedup` (SKILL.md Phase 4); append the survivor to consolidated
```

## Per-finding receipt check

Apply Pass 5's proof requirement to every candidate, including re-emitted findings and later acceptance-criteria findings. A command or file citation alone is insufficient: verify reachable conditions, the actual path and the incorrect result or requirement violation; compare base/head for a regression. A reproducible test or complete source-backed trace suffices. Missing proof cannot be repaired by lowering severity.

Check whether the evidence establishes the premises the finding depends on, not just what would follow if they were true. If an essential premise remains unverified, preserve the concern as a non-gating verification receipt and identify the missing proof.

```text
for finding in consolidated:
  re-read finding.verification_receipt against the source and applicable caller/producer/contract
  if counter-evidence from the source disproves the finding:
    move to dismissed_findings[] citing that counter-evidence   # a false positive, as in § Skill-level second pass
  elif it is missing or does not prove the actual problem:
    demote: move finding to verification_receipts[] — never drop the concern
    preserve the original claim and missing proof in the receipt's attestation
    use claim: indeterminate + missing_source for an identified source outside SEARCH_ROOTS, otherwise below_bar
```

## Skill-level second pass

```text
for finding in consolidated:
  re-read finding against actual diff / source
  question:
    - Is the cited code at finding.location what the description claims it is?
    - Does the recommendation address a real defect or a theoretical concern?
    - Is the severity proportionate to the actual impact?

  if finding is a false positive:
    move to dismissed_findings[] with rationale (logged in review file under § Dismissed Findings)
    do NOT include in verdict computation
```

## Severity adjustment

```text
for finding in consolidated:
  evidence = re-examine code, tests, runtime behavior
  if evidence invalidates the finding's proof:
    return it to the receipt check or dismiss with counter-evidence; do not retain by lowering severity
    continue
  if finding.severity is HIGH/CRITICAL and its proven impact warrants a lower level:
    adjust to that level, never below MEDIUM, cite reason   # a proven finding leaves the gate only by dismissal with counter-evidence
  # MEDIUM is never demoted here — it is real (keep it) or a false positive (dismiss it in § Skill-level second pass)
  if finding.severity is LOW/INFO and evidence shows:
    - impact that meets MEDIUM's criteria (SKILL.md § Severity Definitions) → promote, cite reason
  # the category floor is applied once, by findings.js dedup
  log severity adjustment in dismissed_findings[] (kept-but-adjusted variant) with the cited reason
```

## Phase 5 → Phase 7 data flow

```text
dismissed_findings[]   → round.json `dismissed`         → review file § Dismissed Findings
demoted receipts       → round.json `receipts`          → § Verification Receipts
re-emitted findings    → per-finding receipt check → `consolidated` only with proof → § In Scope Findings
surviving findings[] (`consolidated` after culling) → round.json `findings` → § In Scope Findings; Phase 6's verdict is computed over `consolidated` AFTER Phase 5.5 appends any AC-conformance findings
```

## Acceptance-criteria conformance (Phase 5.5)

Skill-owned per-criterion check (PEs uninvolved, diff-focused). Runs every round — including clean PE rounds — so code that misses an AC cannot reach ✅ APPROVED.

```text
if session.ac_conformance != "pending":
  ⚠️ Warning — AC-conformance {session.ac_conformance}; this round reviews code only
  session.ac_results = []          # nothing to evaluate; the reason is recorded in the banner + report
  goto Phase 6

# Judge each acceptance criterion against the diff under review (the changed_files + their
# content) and the surviving PE findings. Judgment, not string-match — but every "satisfied"
# or "not-satisfied" verdict must cite proof from the working tree, else mark it not-verifiable.
session.ac_results = []
for i, ac in enumerate(session.ticket_acs, start=1):
  status = classify ac against the diff:
    "satisfied"      → code and/or a test in the diff demonstrably meets it  (cite file[:line] / test)
    "not-satisfied"  → the diff is in scope for this ac but does not meet it
    "not-verifiable" → cannot be confirmed from the diff alone (runtime / infra / manual-only)
  session.ac_results.append({index: i, ac: ac, status: status, evidence: <citation or reason>})

# Unmet in-scope criteria become gating findings. Append them to `consolidated` — the SAME
# surviving in-scope set Phase 6's verdict reads (Phase 5 → Phase 7 data flow). Phase 5.5 runs
# AFTER Phase 5, so apply the same per-finding receipt check before appending each AC finding.
# Missing proof makes the criterion not-verifiable; its `domains` controls rendering.
for r in session.ac_results where r.status == "not-satisfied":
  if r.evidence fails the per-finding receipt check:
    r.status = "not-verifiable"; continue
  append to consolidated:
    severity:       HIGH
    in_scope:       true
    domains:        ["Acceptance Criteria"]
    category:       "correctness"
    title:          "Unmet acceptance criterion #{r.index}"          # fixed per AC index — ledger fingerprint stays stable across rounds
    location:       "(acceptance-criteria)"                          # fixed sentinel, same reason
    description:    "{one-line ac} — targets {the file / area the ac targets, or "not implemented"}; proof: {r.evidence}"
    recommendation: "Implement to satisfy AC #{r.index}, or record an engineer override (Phase 6)."
    verification_receipt: r.evidence

# not-verifiable criteria are awareness-only — recorded in the report, never gating (never invent proof).
```
