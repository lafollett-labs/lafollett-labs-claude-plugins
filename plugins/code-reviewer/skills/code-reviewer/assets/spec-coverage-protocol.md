# Spec Coverage Protocol (Story-Linked Pass)

You execute this protocol when your dispatch input includes:

- `STORY_LINKED: true`
- `STORY_FILE: <absolute path>`
- `SPEC_COVERAGE_PROTOCOL: <absolute path to this file>`
- `PR_NUMBER: <number>` — absent when no PR exists or `gh` is unavailable

`<target>` and `<source>` below are the dispatch input's TARGET BRANCH and SOURCE BRANCH.

If `STORY_LINKED` is absent or false: do not execute this protocol. Return only your stack-specific findings.

## Goal

Catch the failure mode where a PR ships a narrow code change but skips acceptance criteria the linked story explicitly mandates. Reference incident: Corebizy Phase 5/6 of Story #1435 shipped without integrating the Story #1443 hardening payload it was contracted to ship — narrow code change passed all four reviewer passes; story acceptance criteria were never verified.

## Acceptance Criteria Parsing

```
ac_source = Read(STORY_FILE)

ac_section = extract_section(ac_source,
  headings: ["Acceptance Criteria", "Acceptance criteria"])

acs = []
n = 1
for line in ac_section.lines:
  if line matches r"^\s*-\s*\[[ x]\]\s*(.+)$":
    acs.append({id: "AC-" + n, text: capture[1], shape: "checkbox"})
    n += 1
  elif line matches r"^\s*\d+\.\s*(.+)$":
    acs.append({id: "AC-" + n, text: capture[1], shape: "numbered"})
    n += 1

if acs is empty:
  flag CHANGES_REQUESTED:
    severity: MEDIUM
    id: "SPEC-NO-AC"
    title: "Story file has no parseable Acceptance Criteria section"
    location: <STORY_FILE>
    description: |
      Could not extract any acceptance criteria from the linked story.
      Either the story is missing an "Acceptance Criteria" section, or the
      section uses an unsupported shape (not checkbox / not numbered).
    recommendation: |
      Update the story file to include an "## Acceptance Criteria" section
      with either `- [ ]` checklist items or numbered (`1. ...`) items.
```

## Discharge Claims Parsing

```
headings = /^(#+\s*)?(Acceptance Criteria|Acceptance Checklist):?\s*$/i

if PR_NUMBER is set:
  claims_text = bash: gh pr view <PR_NUMBER> --json body --jq '.body'
  claims_loc  = "PR #<PR_NUMBER> description"
else:
  claims_text = ""; claims_loc = "branch commit messages (no checklist found)"
  for sha in bash: git log --format=%H <target>..<source>          # newest first
    body = bash: git log -1 --format=%B <sha>
    if extract_section(body, headings) is non-empty:
      claims_text = body; claims_loc = "commit <short sha> message"
      break

pr_section = extract_section(claims_text, headings)

pr_claims = []
for line in pr_section.lines:
  if line matches r"^\s*-\s*\[x\]\s*(AC-\d+)\s*[—-]\s*(.+?)\s*[—-]\s*evidence:\s*(.+)$":
    pr_claims.append({
      id: capture[1],
      claim: "addressed",
      evidence: capture[3]
    })
  elif line matches r"^\s*-\s*\[\s*\]\s*(AC-\d+)\s*[—-]\s*(.+?)\s*[—-]\s*deferred to\s*(#\d+|[A-Z]{2,5}-\d+|[A-Za-z0-9._/-]+\.md)$":
    pr_claims.append({
      id: capture[1],
      claim: "deferred",
      followup: capture[3]          # "#NNN" | story code | story file path
    })
  elif line is non-blank and contains "AC-":
    pr_claims.append({
      id: extract_ac_id(line),
      claim: "malformed",
      raw: line
    })
```

## Verification

```
for ac in acs:
  matching_claim = find(pr_claims, lambda c: c.id == ac.id)

  if matching_claim is None:
    flag BLOCKING:
      severity: HIGH
      id: "SPEC-MISSING-" + ac.id
      in_scope: true
      title: "Story AC " + ac.id + " not addressed in " + claims_loc
      location: <STORY_FILE>
      description: |
        Linked story declares acceptance criterion {ac.id}:
          "{ac.text}"
        {claims_loc} has no entry for this AC — neither addressed nor deferred.
      recommendation: |
        Either:
        (a) Add a checked entry to the PR description (or, with no PR, a commit
            message under an "Acceptance Criteria:" heading):
              - [x] {ac.id} — {ac.text} — evidence: <SHA or file:line>
            and verify the diff actually discharges it, OR
        (b) Add an unchecked entry with explicit deferral:
              - [ ] {ac.id} — {ac.text} — deferred to <#NNNN | STORY-CODE | path/to/story.md>
            (file the follow-up issue or story first)

  elif matching_claim.claim == "addressed":
    verify_evidence(matching_claim.evidence, ac)

  elif matching_claim.claim == "deferred":
    verify_deferral(matching_claim.followup, ac)

  elif matching_claim.claim == "malformed":
    flag CHANGES_REQUESTED:
      severity: LOW
      id: "SPEC-FORMAT-" + ac.id
      in_scope: true
      title: "AC checklist entry malformed"
      location: <claims_loc>
      description: |
        Could not parse the {claims_loc} line for {ac.id}: "{matching_claim.raw}"
      recommendation: |
        Use the canonical shape:
          - [x] AC-N — <text> — evidence: <SHA or file:line>
          - [ ] AC-N — <text> — deferred to <#NNNN | STORY-CODE | path/to/story.md>
```

## Evidence Verification

```
verify_evidence(evidence_str, ac):
  if evidence_str matches r"^[a-f0-9]{7,40}$":  # commit SHA
    sha = evidence_str
    in_pr = bash: git log <target>..<source> --format=%H | grep ^<sha>
    if not in_pr:
      flag BLOCKING:
        severity: HIGH
        id: "SPEC-EVIDENCE-MISSING-" + ac.id
        title: "AC " + ac.id + " claimed SHA not in the change's commits"
        description: |
          {claims_loc} claims AC {ac.id} discharged by commit {sha}, but that SHA is
          not in the range git log {target}..{source}.
        recommendation: |
          Use a SHA from <target>..<source>, or update the evidence to
          point at a file:line that lives in the diff.
    return

  if evidence_str matches r"^([A-Za-z0-9._/-]+):(\d+)$" and capture[1] has no "..":  # file:line — safe charset only
    file_path = capture[1]
    line_num = capture[2]
    diff = bash: git diff <target>..<source> -- <file_path>
    if file_path not in diff OR line_num not in added/modified hunks of diff:
      flag BLOCKING:
        severity: HIGH
        id: "SPEC-EVIDENCE-MISSING-" + ac.id
        title: "AC " + ac.id + " claimed file:line not in diff"
        description: |
          {claims_loc} claims AC {ac.id} discharged at {file_path}:{line_num}, but
          that line is not added/modified by this change's diff.
        recommendation: |
          Either point evidence at a real added/modified line in this change,
          or replace the evidence with a commit SHA from <target>..<source>.
    return

  # Descriptive prose evidence — heuristic keyword grep
  key_terms = extract_key_terms(ac.text)  # nouns + verbs, excluding stopwords
  diff = bash: git diff <target>..<source>
  hits = sum(1 for term in key_terms if grep -i <term> matches in diff)

  if hits == 0:
    flag CHANGES_REQUESTED:
      severity: MEDIUM
      id: "SPEC-WEAK-EVIDENCE-" + ac.id
      title: "AC " + ac.id + " claimed addressed but no diff evidence of key terms"
      description: |
        {claims_loc} claims AC {ac.id} addressed by "{evidence_str}" but the diff
        contains no reference to any key term from the AC text. Cannot
        confirm discharge from prose alone.
      recommendation: |
        Replace prose evidence with a specific commit SHA or file:line, or
        explain in {claims_loc} how the diff discharges the AC
        without referencing the AC's key terms.
```

## Deferral Verification

```
verify_deferral(followup, ac):
  match followup:
    "#<n>":                                            # GitHub issue
      if `gh repo view --json name` fails:             # gh missing, unauthenticated, or no remote
        flag INFO:
          severity: INFO
          id: "SPEC-DEFER-UNVERIFIED-" + ac.id
          title: "AC " + ac.id + " deferral to #" + n + " not verified — gh unavailable"
          recommendation: |
            Re-run with gh available, or defer to a local story code or file instead.
        return
      state = bash: gh issue view <n> --json state --jq '.state'
      if state is empty or command fails:  invalid(ac, "#" + n, "does not exist in the repo")
      elif state == "CLOSED":               closed(ac, "#" + n, "is already CLOSED")
    "<CODE>":                                          # local story code
      file = first line of: grep -rlE '^\*\*Code:\*\* +<CODE> *$' docs/epics --include='*.md'
      verify_local(ac, followup, file)
    "<path>.md":                                       # local story file
      if path contains ".." or starts with "/": file = None
      else: file = <path> if Glob(<path>) matches it (repo root) else None   # Glob/Read, never Bash
      verify_local(ac, followup, file)

verify_local(ac, followup, file):
  if file is None:                                     invalid(ac, followup, "resolves to no story file")
  elif realpath(file) == realpath(STORY_FILE):         invalid(ac, followup, "is the story under review")
  else:
    code = the `**Code:** <CODE>` value in file if it matches ^[A-Z]{2,5}-[0-9]+$, else None   # never interpolate other text
    if code and `grep -rqE '^\s*-\s*\[x\]\s*(\*\*|\[)?<code>\b' docs/epics --include='*.md'` succeeds:
      closed(ac, followup, "is checked off as done in its epic")

invalid(ac, target, why):
  flag BLOCKING:
    severity: HIGH
    id: "SPEC-DEFER-INVALID-" + ac.id
    title: "AC " + ac.id + " deferred to " + target + ", which " + why
    description: |
      {claims_loc} defers AC {ac.id} to {target}, which {why}.
    recommendation: |
      File the follow-up issue or story (a docs/epics story file with a `**Code:**` line),
      point the deferral at it, OR address the AC in this change.

closed(ac, target, why):
  flag BLOCKING:
    severity: HIGH
    id: "SPEC-DEFER-CLOSED-" + ac.id
    title: "AC " + ac.id + " deferred to " + target + ", which " + why
    description: |
      {claims_loc} defers AC {ac.id} to {target}, which {why}.
      Deferrals must point at open follow-up work.
    recommendation: |
      Open new follow-up work tracking the deferred AC, OR address the AC in this change.
```

## Optional Annotation on Stack Findings

While running your stack-specific passes (1-5) on the same PR, you MAY tag any stack finding with `discharges_ac: ["AC-N"]` if that finding addresses a specific acceptance criterion from the story file. Example:

- Stack finding `HIGH-001` flags a goroutine leak at `pkg/runtime/agent_loop.go:142`
- AC-7 in the linked story is "Tool-use loop hop ceiling prevents infinite loops; termination surfaces structured error"
- The fix recommendation describes adding a `MaxToolHops` ceiling
- Tag the finding: `discharges_ac: ["AC-7"]`

Multiple ACs per finding allowed. Annotation enriches the consolidated review but is OPTIONAL — Spec Coverage runs independently. Annotation is for stack findings; SPEC-* findings (from this protocol) do not carry `discharges_ac`.

## YAML Output Shape

Append these findings to your normal stack-PE YAML under the same `findings:` key. Distinguish them with the `id:` prefix (`SPEC-*`) and tag `expert: PE-{Stack}-SpecCoverage` if your stack PE emits both kinds. Example:

```yaml
expert: PE-Go
findings:
  - id: "HIGH-001"
    severity: HIGH
    in_scope: true
    title: "Goroutine leak — no completion signal"
    location: "pkg/runtime/agent_loop.go:142"
    description: |
      Goroutine launched without WaitGroup / errgroup / channel close...
    recommendation: |
      ...
    discharges_ac: ["AC-7"]   # optional annotation

  - id: "SPEC-MISSING-AC-3"
    severity: HIGH
    in_scope: true
    title: "Story AC-3 not addressed in PR description checklist"
    location: "docs/epics/020-crew-system-architecture/07-Story-...-Hardening.md"
    description: |
      Linked story declares acceptance criterion AC-3: "Pseudocode for the
      composition algorithm present in the ADR, deterministic, with inputs
      and output." PR description checklist has no entry for AC-3.
    recommendation: |
      Add `- [x] AC-3 — ... — evidence: <SHA>` to the PR description after
      confirming the pseudocode is present in the changed ADR file.
```

## Severity Discipline (Spec Coverage)

| Finding ID prefix | Severity | Verdict impact |
| --- | --- | --- |
| `SPEC-MISSING-*` | HIGH | BLOCKING |
| `SPEC-EVIDENCE-MISSING-*` | HIGH | BLOCKING |
| `SPEC-DEFER-INVALID-*` | HIGH | BLOCKING |
| `SPEC-DEFER-CLOSED-*` | HIGH | BLOCKING |
| `SPEC-DEFER-UNVERIFIED-*` | INFO | Awareness (does NOT block) |
| `SPEC-WEAK-EVIDENCE-*` | MEDIUM | CHANGES REQUESTED |
| `SPEC-FORMAT-*` | LOW | Awareness (does NOT block) |
| `SPEC-NO-AC` | MEDIUM | CHANGES REQUESTED (story file issue) |

## Constraints

- Only execute this protocol when `STORY_LINKED: true` is in your dispatch input.
- Pre-existing AC failures (the AC was already in the story before this PR opened) are still `in_scope: true` for this PR if the PR claims to address them OR the story is the same one this PR links to. Spec Coverage is not subject to the "diff-only" scope rule that gates technical findings.
- Do NOT generate findings for ACs that the claims source (PR description or commit message) correctly handles (addressed with valid evidence OR deferred with valid open follow-up). Spec Coverage is a gap-detector, not a checklist re-poster.
- Read this asset on first execution. Do not re-Read on each finding generation — load once, apply throughout.
