# PE Review Protocol

The five-pass review every PE agent runs. `sdlc:review` inlines this file into each PE dispatch prompt as `PE PROTOCOL`; the PE's own agent definition adds only its stack knowledge (owned files, commands, stack heuristics, stack lenses).

## Contents

- Inputs
- Workflow
- Passes 1–3: Architecture, Quality + Tests, Security
- Pass 4: Adversarial Re-read (Calibration Anchor, Common Lenses, How to Apply Pass 4)
- Pass 5: Self-Adversarial
- Scope Discipline
- Severity Definitions
- Output Format
- Constraints

## Inputs

The dispatch prompt provides metadata; the PE pulls its own diff and reads full files:

- **Diff command** — the git diff command to run (the PE executes it)
- **Key files changed** — the files routed to this PE (from `--stat`)
- **Scope** — Branch Diff, Staged Diff, or PR Review (affects in_scope determination)
- **Issue ID** — for cross-referencing in findings
- **Worktree** — the checkout under review (a review worktree, or the engineer's own checkout in place); `cd` here for every Bash operation
- **Build root** — where front-end installs, builds, and tests run (Constraints says which): a disposable worktree of the reviewed changes or the review worktree (install there), or the engineer's checkout (never install; each BUILD PLAN command writes its output to a scratch directory); `none` means run none of them and review statically
- **Build plan** (optional) — one entry per Angular / Vue project, its `dir` inside BUILD ROOT: `run` → run its command from `dir` exactly as given; `skip` → no build, a receipt with its reason; `introspect` → read the project's package.json scripts and the repo README / CLAUDE.md for its non-production build; `ask` → the direction rule under Constraints
- **Test budget** (optional) — `none` for a domain PE: run no build, test, or lint suite and record no build receipt; the stack PE reviewing the same files runs them. Pass 2 still runs the agent's read-only checks
- **Project subdir** (optional) — where this PE's files live; default repo root
- **Prior review / prior ledger** (round 2+) — prior findings with their raw title + category. The PRIOR REVIEW and PRIOR LEDGER files named in the dispatch are inputs: read them wherever they are; the boundary applies to searches and every other read.
- **Tier + TIER_CONTRACT + SEARCH_ROOTS** — review depth (TRIVIAL | STANDARD | DEEP); the contract scopes WHICH files enter the review, the search boundary, and the tool budget — never the five passes, never partial reads of opened files; below DEEP, SEARCH_ROOTS bounds every search and read in every pass, including the cross-verification and blind_spot_scan blocks; emit `tier_escalation` if insufficient
- **Lenses** — attention augmentations in the dispatch prompt; hold all of them through every pass and re-apply each explicitly in Pass 4

## Workflow

```text
1. Run the diff command. Restrict analysis to the KEY FILES CHANGED routed to you;
   files owned by another PE belong to that PE (see your agent's hand-offs).
2. Read the FULL FILE for every changed file in scope, not just the hunks — bugs hide in the
   interaction between the changed code and the rest of its module.
3. Round continuity (skip on round 1):
     for each prior finding from PRIOR LEDGER / PRIOR REVIEW:
       pattern still present → re-flag with the prior title + category verbatim
       pattern gone          → resolved; do not re-raise
4. Run the commands your agent definition lists (Pass 2). Capture exit code + a useful output tail.
5. Run the five passes in order. Passes 4 and 5 are mandatory at every tier. Then apply every move in
   the REVIEW MOVES block of the dispatch, and record each in moves_coverage.
6. Deliver the YAML (§ Output Format) via
     SendMessage(to: <REPLY-TO from the dispatch prompt; default "main">, summary: "<expert> review findings", message: <the YAML block — nothing else>)
   The PE runs in background; plain-text turn output is not visible to the lead, and summary is required when message is a string.
```

## Passes 1–3

Each pass reads the diff for one concern. The agent definition's stack heuristics say what tends to break in that stack; apply them with judgment, verify each suspicion with a command or a full-file read, and rate what survives from § Severity Definitions.

- **Pass 1 — Architecture.** Boundaries and dependency direction hold; public contracts (signatures, schemas, endpoints, config keys) still match every caller and consumer, including consumers this diff edits; new invariants are enforced, not assumed.
- **Pass 2 — Quality + Tests.** Run the build, test, and lint commands first. Then error handling, resource lifecycle, concurrency, dead code, and whether each new behavior has a test that would fail without it. Comments the diff adds should be one-line notes on a non-obvious constraint; report ones that carry ticket keys, change narration, or test pointers, or that restate the code (`maintainability`).
- **Pass 2b — Impact propagation.** Trace each changed public symbol, data shape, or migration to its callers and persisted data inside SEARCH_ROOTS, and imagine what breaks on deploy.
- **Pass 3 — Security.** Injection, authn/authz order and ownership checks, secrets, transport security, unsafe deserialization, and what reaches logs.

## Pass 4: Adversarial Re-read

After Passes 1–3, re-read the diff once more with every lens: the dispatched LENSES, the Common Lenses below, and the agent's stack lenses.

### Calibration Anchor (read BEFORE applying any lens)

Pass 4 is a **catch net**, not a **ratchet**. Its purpose is to surface defects that hid in plain sight during Passes 1-3, NOT to manufacture new findings round-after-round on closed-set themes.

```text
PASS 4 SEVERITY DISCIPLINE:
  The lenses carry no severities. Rate each finding from Severity Definitions:
    MUST FIX = actual defects, security issues, regressions

  REPORTING BAR: "Is this a real defect a senior reviewer would want fixed or flagged on this PR?" If not, it
  goes in verification_receipts[] (non-gating), not findings[]. Rate each
  finding at the severity its impact earns (Severity Definitions); which
  severities gate is defined once, by sdlc:review. Never pick a severity
  to change whether a finding gates.

  Apply each lens VIVIDLY but HONESTLY. If applying a lens forces you to
  imagine an unlikely scenario (contrived attacker, scale 1000x not 10x,
  exotic partial-failure path with no real-world precedent), it fails the
  REPORTING BAR and moves to verification_receipts[].

ROUND-OVER-ROUND DISCIPLINE:
  applies only when the dispatch's ROUND is 2+ — prior rounds are known
  from PRIOR REVIEW / PRIOR LEDGER, never from a review doc inside the diff.

  before flagging a NEW Pass 4 finding on round 2+:
    if theme was raised in an earlier round AND remediated:
      do not re-flag it under a different lens-angle (the convergence spiral)
    if theme is genuinely NEW (different code area, different category):
      flag it at the severity it earns

CLOSED-SET CONVERGENCE:
  When the diff converges (Passes 1-3 produce no new findings, all prior
  in-scope CRITICAL/HIGH/MEDIUM remediated), Pass 4 should also converge.
  Before adding a fresh Pass 4 finding on a converged diff, ask:
    "Would a senior reviewer reading the diff today, blind to round 1's
     findings, independently flag this as MUST-FIX?"
  If no, move to verification_receipts[].

PASS 5 VALIDATION BAR:
  Every Pass 4 finding must survive Pass 5 (Self-Adversarial) before
  publishing. Apply Pass 5's severity_honesty check: actually exploitable?
  real risk not theoretical? would a senior agree it is worth fixing or flagging?
  Findings that fail move to verification_receipts[].
```

The lenses below describe WHAT to look for. The Calibration Anchor governs HOW HARD to flag. Working code that passes its tests and meets its acceptance criteria should reach `✅ APPROVED` by round 2 of a typical PR.

### Common Lenses

- **hostile_attacker** — Read the diff as someone hunting for privilege escalation, auth bypass, races won by parallel requests, debug or override escape hatches, defaults that fail open, validation that runs after the action it gates, and caller-controlled input reaching a trust decision.
- **scale_10x** — Assume ten times today's load. For each query, allocation, lock, and network call, ask what fails first: memory growth, pool exhaustion, lock contention held across I/O, one slow dependency owning p99, rate limits, fan-out without back-pressure.
- **junior_in_one_year** — Read as an engineer changing this code a year from now. What is not obvious from names and structure: an implicit "call X before Y" invariant, coupling across boundaries, unexplained magic values, ordering between async steps?
- **prod_incident_2am** — Read as on-call with this code in alarm. Can logs and metrics say what failed, with correlation and tenant IDs, pointing at the right component?
- **partial_failure** — Assume each external call fails 30% of the time. What state survives a half-finished multi-step operation: an orphaned write, an unpublished event, a cache ahead of its source, a retry without an idempotency key, a compensation that can itself fail?
- **silence_check** — Look for failures that make no noise: discarded errors, log-and-continue where flow should stop, unbounded retries, missing timeouts, wrapping that loses the cause, background work that never reports its result. The agent's stack lenses name the stack's own forms of these.

### How to Apply Pass 4

```text
for each lens (dispatched LENSES + Common Lenses + your stack lenses):
  re-read the diff with that lens
  if it surfaces a finding not already drafted in Passes 1-3:
    run it through the Calibration Anchor
    if it survives:
      add it, rated from Severity Definitions
      tag the description: "Surfaced via Pass 4 / <lens_name>."
  a lens that surfaces nothing is fine — but it must actually be applied
```

## Pass 5: Self-Adversarial

Attack the draft before returning it.

Every finding is required to provide proof of an actual problem, not just evidence that something might be wrong. Show that the conditions can happen, trace the actual path, and explain the incorrect result. For a regression, demonstrate why the old version works and the new one doesn’t.

A reproducible test or a complete source-backed trace is sufficient; a production incident is not required. For documentation or quality findings, identify the applicable requirement and its violation.

Check whether the evidence establishes the premises the finding depends on, not just what would follow if they were true. If an essential premise remains unverified, preserve the concern as a non-gating verification receipt and identify the missing proof.

```text
for each finding in draft:
  verification_receipt:
    "Do the source or command results prove reachable conditions, the actual path and the incorrect result?"
    if a regression is claimed: compare base and head under the same conditions
    if the actual problem cannot be established:
      move to verification_receipts[], preserving the original claim and missing proof in attestation
      use claim: indeterminate + missing_source for an identified source outside SEARCH_ROOTS, otherwise below_bar
    else: include the key evidence in the finding

  false_positive_check:
    "Am I pattern-matching on a keyword, or is this actually broken?"
    Read the FULL file around the flagged line. Context that invalidates the finding
    (a documented invariant, a test-only path, a protocol constant) → remove it.

  severity_honesty:
    "Would this cause a build failure, runtime exception, security incident, or data loss?"
    if CRITICAL: yes, with immediate impact
    if HIGH: yes, and it will bite within days in production
    if no to both: it is MEDIUM or below; rate it from Severity Definitions

    REPORTING BAR: "Is this a real defect a senior reviewer would want fixed or flagged on this PR?"
      if no → move to verification_receipts[] (non-gating), not findings[]

  provenance_check:   # input-validation / normalization / malformed-input findings
    producer = who writes the flagged input (name the file, skill, or command)
    if producer is this repo's own code/skill/tool with an enum/schema contract,
       or a file only our tooling writes:
      if no real producer is shown emitting or permitting the bad value (test or source-backed trace):
        move to verification_receipts[] (non-gating), not findings[]
    else:   # human-authored, developer environment, external/network input
      keep; apply REPORTING BAR

  negative_receipt_proof:   # every verification_receipts[] entry
    set claim:   # sdlc:review proof-checks exactly the entries marked absence
      absence       = YOUR OWN assertion that something does not / cannot happen ("cannot happen", "never",
                      "no false lock", "not reachable", "fails closed", "only N sites", "X does not Y")
      positive      = attests a command that was run and passed
      below_bar     = a concern that failed the REPORTING BAR or provenance_check, or whose actual problem could not be established
      indeterminate = cannot be verified because an identified source is outside SEARCH_ROOTS; set missing_source
    a claim a reviewed document makes is not yours: verify it inside SEARCH_ROOTS and classify the result;
      below DEEP, its source outside SEARCH_ROOTS → claim: indeterminate, missing_source: <that system>, no evidence, no further search
    if claim == absence:
      first, construct the input MOST likely to break the claim and run it
        if it breaks → the claim is false: report what breaks (a finding, or per
                       provenance_check a receipt stating it breaks), never "safe"
      it must carry, in `evidence:`, the command + its output for every input it names
      word it to exactly the inputs run — "the 3 malformed inputs I ran exit 2",
        never a claim about the whole input class ("malformed input always exits 2")
      if no such evidence:
        narrow the attestation to what was actually run; report a finding only if the actual problem is proved
```

**Cross-verification.** Apply the agent's cross-verification heuristics: for each new surface (endpoint, handler, job, schema, template), read the layer on the other side of it inside SEARCH_ROOTS and confirm the contract, auth posture, and data shape agree.

**Blind-spot scan.** Ask which code inside SEARCH_ROOTS depends on each changed public symbol and grep for it; ask which tests exercise the changed path; check every data-shape assumption against the schema or fixture data.

## Scope Discipline

```text
for each finding:
  if line is added/modified by the diff:                 in_scope = true
  elif issue is in the symbol/section containing changes: in_scope = true
  else:                                                   in_scope = false  # pre-existing — awareness only
```

`location` uses the full path from repo root (`src/Catalog/SearchService.cs:42`, not `SearchService.cs:42`).

## Severity Definitions

Rate each finding by its impact. Which severities gate is defined once, by sdlc:review. An agent's own Severity Definitions table, where it has one, refines these levels for its stack; agent heuristics name a category, never a severity.

| Level | Criteria |
| - | - |
| 🔴 CRITICAL | Immediate impact: an exploitable security defect, data loss or corruption, a breaking change to existing consumers, a build, typecheck, or test command that fails |
| 🟠 HIGH | A real bug or design flaw that will bite in production within days: a failure mode that is silent or leaves inconsistent state, a resource or concurrency hazard, a missing test for new non-trivial behavior |
| 🟡 MEDIUM | A quality or maintainability defect that affects product behavior or operability: a failing lint or format command, an unenforced invariant, missing observability for a failure mode, a contract left undocumented |
| 🟢 LOW | Style, naming, or a minor improvement |
| ℹ️ INFO | Minor real defect that still clears the REPORTING BAR — observations, alternatives, and future considerations are NOT findings; they go in `verification_receipts[]` |

Findings in the data-integrity, migration, auth, or secrets categories are never rated below MEDIUM. Every row is subject to the REPORTING BAR: an item that is not a real defect worth fixing or flagging on this PR goes in `verification_receipts[]`, whatever its severity.

## Output Format

Deliver one YAML block — no prose before or after it — via SendMessage to REPLY-TO. `expert` is the expert ID your agent definition declares.

```yaml
expert: <expert ID>
findings:
  - id: "HIGH-001"
    severity: HIGH
    in_scope: true
    is_pattern: false         # true when the root cause is a shape that may recur in other files (the lead greps for it)
    category: error-handling  # data-integrity|migration|auth|secrets|security|correctness|concurrency|error-handling|performance|test-coverage|maintainability|docs|general — first 4 floor to MEDIUM; re-flagged findings reuse prior title + category verbatim
    title: "Brief issue title"
    location: "path/from/repo/root.ext:123"
    description: |
      What is wrong, why it matters, and how it was confirmed.
    recommendation: |         # required — a concrete fix, not "consider X"
      How to fix it, with a code example when it helps.
    verification_receipt: |    # Pass 5 — the command you ran + its key output
      <command> → <key output line(s) confirming the defect>
    move: M4                  # the REVIEW MOVES move whose trigger it falls under, or none
    siblings: []              # REVIEW MOVES § Finding Keys — every other path:line stating or repeating it
    introduced_by: new        # only when FIX DIFF is set: <prior finding id> | still-present | new | missed | pre-existing
moves_coverage:                 # REVIEW MOVES § Output — M1..M7, each exactly once
  - {move: M1, status: applied, checked: "<what you examined, with a count>", note: ""}
verification_receipts:          # non-gating — items that fail the REPORTING BAR + positive attestations
  - id: "RECEIPT-001"
    claim: positive             # absence | positive | below_bar | indeterminate (Pass 5 negative_receipt_proof)
    title: "Brief attestation title"
    location: "path/from/repo/root"
    attestation: |
      What was checked and what it showed.
    evidence: |                 # required when claim: absence — the command + output for every input the attestation names
      $ <command that exercises the claimed-impossible path>
      <its output>
    missing_source: "<system>"   # only for claim: indeterminate — the source outside SEARCH_ROOTS
    category: auth               # set on absence receipts (same enum as findings)
```

With no findings at any severity, return `expert: <expert ID>`, `findings: []` and `moves_coverage`.

If the dispatched TIER cannot reach what the diff touches, add a top-level `tier_escalation` with the findings gathered so far; the lead re-dispatches at the higher tier:

```yaml
tier_escalation:
  requested_tier: STANDARD|DEEP        # must rank strictly above the dispatched TIER
  justification: "one line: what the diff touches that the dispatched tier cannot reach"
```

## Constraints

- Review only changed lines; a pre-existing issue is `in_scope: false`.
- Review only the files routed to this PE; hand the rest to the owning PE.
- Do not modify files, commit, or push. Findings travel back as YAML only.
- Run only commands the project already wires up; add no dependencies.
- Run all five passes at every tier. A failing build or test command is reported, never skipped.
- Front-end projects, whose builds bake an environment's configuration into their output (Angular, Vue / Nuxt, Storybook, other JS bundlers), install, build, and test only where BUILD ROOT says, from the BUILD PLAN entry's `dir`. Never run an install (`npm ci`, `npm install`, or another package manager's) in the engineer's checkout. A git-ignored folder in the engineer's checkout (`dist/`, `storybook-static/`) is their served build, not scratch space. Never build a production configuration (one whose name or swapped-in environment file says prod / production) or a `build:prod` script. A front-end build that cannot run where BUILD ROOT says does not run; record a receipt saying why. When BUILD ROOT is the engineer's checkout, run only a `run` entry's command, exactly as given; an `introspect` or engineer-directed build there is skipped with a receipt. An entry with `checks: skip` also skips that project's tests, lint, and typecheck; record a receipt with its reason, not a failing command. .NET, Go, SQL, and IaC builds read their environment at runtime and keep their agent's own commands.
- When you cannot determine a non-production build — a BUILD PLAN `ask` entry, or an `introspect` entry your reading does not settle — do not guess and do not build. SendMessage(to: REPLY-TO, summary: "build direction", message: "build_direction\nproject: {project}\nquestion: {question}"), wait for the reply, then build as it directs or skip with a receipt.
- Record every build you run as a verification_receipts[] entry naming its configuration and output path (a BUILD PLAN entry's receipt line).
