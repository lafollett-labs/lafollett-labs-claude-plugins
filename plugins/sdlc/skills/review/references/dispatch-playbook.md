# Dispatch Playbook — Lenses & Depth Tiers

Lens augmentations and depth-tier contracts for PE dispatch in `sdlc:review`. A lens is an attention augmentation inside a dispatch prompt — a way of reading the diff, never a unit of agent dispatch.

Consumption (SKILL.md Phase 3):

```text
LENS_AUGMENTATIONS — all 5 lenses fold into EVERY dispatch prompt's LENSES block;
                     dispatch count = len(session.teammates) (≥ len(matched_pes); a big diff may shard a PE), never PEs × lenses
TIER_CONTRACTS     — one depth contract per dispatch, keyed by pe_tier(pe)
```

---

## Contents

- Lens Definitions
- Depth Tier Contracts
- Judgment Pass
- Adding a Lens
- Adding a Tier

## Lens Definitions

### 1. semantic-consistency

```text
focus:        write/read symmetry, cross-file contract drift, conventions-vs-emission mismatch
catches:      schemas that get written but never read; assumptions about field shape that
              contradict the producer; documentation that disagrees with the code; convention
              files that lie about runtime behavior
key probes:
  - "for every write to {x}, is there a read that matches its shape?"
  - "does the convention file describe what the code actually emits?"
  - "if two files claim the same thing, do they agree byte-for-byte on the contract?"
prompt augmentation:
  "Apply a semantic-consistency lens. For every claim made in one file, locate the
   corresponding consumer or producer in another file and verify the shapes agree.
   Treat write-existence as half of a contract — the contract is only satisfied if
   the read agrees. Flag any field, schema, or invariant that is asserted in one
   place and contradicted (or silently ignored) in another."
```

### 2. delivery-pipeline + integration

```text
focus:        versioning, gate escape hatches, CI/CD wiring, cross-skill coupling, git-CLI correctness
catches:      version bumps that fail cache invalidation; CI steps that skip the gate they claim
              to enforce; merge strategies that don't match the branch policy; skills that
              quietly depend on other skills; git invocations that work locally but fail in CI
key probes:
  - "what version key does the consumer cache on, and does this change bump it?"
  - "is the gate in this CI step actually gating, or just logging?"
  - "if I run this command in a fresh clone, does it succeed?"
  - "does skill A silently rely on skill B's outputs?"
prompt augmentation:
  "Apply a delivery-pipeline + integration lens. Trace the artifact from author → CI →
   registry → consumer cache. Identify where caching, versioning, or gate semantics
   could let a broken change reach users. Verify git/gh commands work in headless/
   no-config contexts (no global git config, no interactive prompts, no stale local
   refs). Flag any cross-skill dependency that isn't explicit in the contract."
```

### 3. adversarial-security

```text
focus:        hostile_attacker threat model, secrets/IAM/RBAC, injection paths, scale_10x
catches:      auth bypass via assumption chains; secrets leaked via logs or error messages;
              IAM over-permissioning; injection paths (SQL, command, prompt); cost-of-failure
              at 10× scale; supply-chain risk
key probes:
  - "if I were a hostile attacker with access to {input}, what could I do?"
  - "what happens at 10× current scale — does anything fall over?"
  - "is any secret reachable from a log line, error response, or stack trace?"
  - "does IAM grant the minimum required for the actual API calls?"
prompt augmentation:
  "Apply an adversarial-security lens. Adopt the hostile_attacker mental model: assume
   the attacker has read access to the diff, source code, and observable runtime
   behavior. Trace every input from boundary to handler — what assumptions does the
   code make about its inputs, and which of those assumptions can be violated?
   Compare granted IAM actions against actual API calls. Verify secrets cannot escape
   via logs, error messages, or telemetry. Sanity-check behavior at scale_10x."
```

### 4. workflow-correctness

```text
focus:        silence_check, partial_failure, prod_incident_2am, junior_in_one_year
catches:      silent failures with no telemetry; partial-failure modes that aren't handled;
              code unreadable to a 2am-incident responder; brittle abstractions that confuse
              a junior engineer in a year
key probes:
  - "if this fails silently, how would the operator know?"
  - "what if step 2 of 3 succeeds and step 3 fails — is the system left in a recoverable state?"
  - "at 2am during a prod incident, can a tired engineer read this and understand it?"
  - "in a year, will a junior dev understand what this code is doing and why?"
prompt augmentation:
  "Apply a workflow-correctness lens. For every operation that can fail, ask: how does
   the operator notice? What recovery state does a partial failure leave behind? Is
   the failure mode logged with enough context to debug at 2am? Read the code as a
   junior engineer encountering it for the first time in 12 months — flag anything
   that requires institutional context to interpret correctly."
```

### 5. pseudocode-hygiene + AC-coverage

```text
focus:        governance file authoring against the repo's skill-authoring standard, in both
              directions; AC traceability against the story spec
catches:      control flow left as prose; judgment over-specified as imperative triggers or
              costume pseudocode; structural limits the diff introduces; behaviour changes with
              no eval or suite coverage; ACs not implemented or not testable; text that adds no behaviour
key probes:
  - "does each block's form match its task shape — pseudocode for real control flow, a script
     for deterministic logic, prose heuristics for judgment?"
  - "for each AC in the story spec, what code/section implements it?"
  - "for each section of the skill, what AC justifies its existence?"
prompt augmentation:
  "Apply an authoring-standard + AC-coverage lens. Read each governance file as a model
   parsing it on every invocation, and report a mismatch between form and task shape in
   either direction with equal weight. Under-specified: a gate, loop, or ordered side effect
   written as a prose decision tree, or deterministic logic the model must execute by hand.
   Over-specified: judgment written as an imperative trigger ('if X: flag <severity>') or as
   costume pseudocode with no real branch, variable, or ordering, stacked MUST/NEVER emphasis,
   or restated general knowledge; the fix is a prose heuristic. Report a structural limit
   the diff introduces: a SKILL.md or agent body past 500 lines, a reference that routes to
   another reference, a reference over 100 lines without a table of contents, or ticket
   history in an instruction body. Report a behaviour change that ships without an eval
   update. Text that explains instead of instructs is dead weight if removing it does not
   change what the model does. Cross-reference every AC in the story spec against the
   implementation; list any AC without a corresponding code/section, and any code/section
   without a corresponding AC."
```

---

## Depth Tier Contracts

The tier scopes WHICH files enter the review, the search boundary, and the tool budget — never the number of passes, never the YAML contract, never Pass 4/5 obligations. Every opened file is read IN FULL; the tier limits the file set, not the read depth of an opened file. TRIVIAL and STANDARD dispatch with § Search Boundary appended; DEEP does not.

### TRIVIAL

```text
prompt contract:
  "Scope every pass to the changed lines plus their direct blast radius: the
   immediate producers and consumers of exactly what changed (direct callers of
   a changed symbol; the reader of a changed config key; the template consuming
   a changed value). Read full files for changed files and direct blast-radius
   files ONLY. Do NOT explore the wider codebase or enumerate module trees.
   Grep only to confirm direct producers/consumers. Pass 2: run the narrowest
   discoverable test/build command covering the changed files — not the full
   suite. Budget: at most 10 search commands (find, grep, rg, ls -R, Glob,
   Grep) in total, each under SEARCH_ROOTS. Cost must be proportionate to the
   diff. If the tier underscopes the change, emit tier_escalation — never
   silently widen scope."
```

### STANDARD

```text
prompt contract:
  "Read full files for every changed file and trace each changed symbol to its
   callers/consumers across the affected project(s). Run the discoverable
   build/test/lint commands for the affected projects. Trace within the
   affected project directories of the reviewed tree; search a declared sibling
   SEARCH_ROOT only to verify a claim the diff or a reviewed document makes
   about that sibling. Budget: at most 30 search
   commands (find, grep, rg, ls -R, Glob, Grep) in total. Verifying a finding
   never widens scope or budget: past either, emit tier_escalation or an
   indeterminate receipt."
```

### Search Boundary

Appended to the TRIVIAL and STANDARD contracts at dispatch; never to DEEP.

```text
prompt contract:
  "SEARCH_ROOTS is a hard boundary. Every find, grep, ls, Read, and build/test
   command in every pass — including cross-*-verification and blind_spot_scan —
   targets a path inside SEARCH_ROOTS. Never run find or grep -r over a parent
   of a SEARCH_ROOT (a repos root, $HOME, a drive root, /).
   The PRIOR REVIEW and PRIOR LEDGER files named in the dispatch are inputs:
   read them wherever they are; the boundary applies to searches and every other read.
   A claim about a system whose source is not inside SEARCH_ROOTS: emit one
   verification_receipts[] entry with claim: indeterminate and missing_source:
   naming that system, then stop — do not search for it."
```

### DEEP

```text
prompt contract:
  "Full protocol at full depth: read full files, trace cross-project impact,
   run the complete discoverable build/test/lint suites, and chase every
   suspicious thread to ground truth. No exploration cap."
```

---

## Judgment Pass

Consumed by SKILL.md § Pre-dispatch judgment. The mechanical glob/path classifier is the deterministic floor; the judgment pass reads the diff CONTENT and refines routing + tier. These are signal *guidance* for genuine reasoning — not an exhaustive deterministic match. Judgment generalizes beyond the listed rows.

`CONTENT_STACK_SIGNALS` — stack identity the filename glob can miss; re-route the file to the target PE:

| Stack | Content signals (in the diff hunks) | Target PE |
| - | - | - |
| CloudFormation | `AWSTemplateFormatVersion`, top-level `Resources:` with `Type: AWS::*`, `!Sub`/`!Ref`/`!GetAtt`, `{{resolve:ssm:…}}` | `pe-aws-infra` |
| Terraform (non-`.tf` embed) | `resource "aws_*"`, `provider "…"`, HCL block syntax | `pe-aws-infra` |
| Docker (non-`Dockerfile` name) | `FROM …`, `RUN …`, `ENTRYPOINT`/`CMD` directives | `pe-aws-infra` |
| GitHub Actions (outside `.github/workflows/`) | top-level `on:` + `jobs:`, jobs with `runs-on:`/`steps:`/`uses:` | `pe-github-actions` |
| SQL embedded (non-`.sql`) | `CREATE TABLE`/`ALTER`/`CREATE PROC` or other DDL | `pe-sql-server` |

`CONTENT_RISK_SIGNALS` — risk carried in VALUES, not the path; floor the tier to STANDARD (mirrors the security-path floor in `bin/scope.js`, but content-detected):

```text
secrets/credentials:  {{resolve:ssm:…}} to a secret ARN | SecretString | ValueFrom a secret |
                      *_SECRET / *_TOKEN / *_KEY / *_PASSWORD env wiring | credential-shaped literals
iam / authz:          inline Action:/Effect:/Principal: policy statements | role/permission grants |
                      [Authorize]/auth-middleware/authz-decision logic
data integrity:       embedded schema/DDL, data migrations, money/financial calculations
```

Rules:

- **Routing is additive / coverage-preserving** — re-route or ADD a specialist; never drop a glob-matched PE, never remove a file from review. Every changed file stays mapped to exactly one PE. (Merge pseudocode + asserts: SKILL.md § Pre-dispatch judgment.)
- **Tier floor is one-directional** — content risk can only raise the tier (or hold it at STANDARD); judgment never lowers a tier below the `security_path`/`content_risk`/`deps_or_schema` floor.
- **Determinism + rationale** — the mechanical baseline is the recorded reference; any judgment deviation records a one-line rationale (`tier_source`, `routing_rationale`). Given identical inputs, the rationale must explain the deviation.

---

## Adding a Lens

```text
1. Pick a focus area not covered by the existing 5 lenses
2. Document:
   focus:               one-line scope
   catches:             types of defects this lens reliably surfaces
   key probes:          3-5 questions the PE should ask itself under this lens
   prompt augmentation: the exact string inserted into the dispatch prompt's LENSES block
3. Append to this file under a new "### N. {lens-name}" heading
4. Done — every lens in this file rides the LENSES block into every dispatch prompt; agent count is unaffected
```

## Adding a Tier

```text
1. Define the contract under § Depth Tier Contracts (file-set scope + tool budget; never pass count)
2. Add the rung to bin/scope.js (TIERS + classify, with a fixture test) AND the TIER_RANK in
   dispatch-and-collect.md § Tier escalation check — tiers stay totally ordered across both
3. Banner and override prompt pick up the new tier name from scope.js
4. No review-file change needed — review-file.js renders the tier name verbatim
```

Lens definitions and tier contracts live in this file (loaded by the skill at dispatch time). PEs do NOT load this file directly — the skill inlines the LENSES block and TIER_CONTRACT into each PE's dispatch prompt.
