# Planning Playbook — Phase 3

Detailed planning procedure for the `implement` skill. Load when entering Phase 3.

## Contents

- Foundational Rule
- Step 1 — Scope Scout
- Step 1.5 — Multi-Area Verification Gate
- Step 2 — Classify Size from Scout Findings
- Step 3 — Spawn Additional Explorers (M or larger only)
- Step 4 — Spawn Architect Agents
- Step 5 — Consolidate and Present
- Step 6 — HARD STOP

## Foundational Rule

```text
for every claim made by any agent (scout, explorer, architect) or the consolidated plan:
  if the claim is NOT backed by Read / Grep / Glob on a file that exists in the working tree:
    drop the claim
```

## Step 1 — Scope Scout

Spawn ONE agent before sizing:

```text
Agent(
  subagent_type = "Explore",
  description   = "Scope scout for {session.ticket_key}",
  prompt        = SCOUT_PROMPT
)
```

`SCOUT_PROMPT`:

```text
Given this ticket: {ticket_title} — {AC_summary}.

Identify every area of the codebase this work is likely to touch.
For each area, verify it exists in the working tree (Glob / Read).

Return:
  - Affected modules / files — file paths confirmed by Glob or Read
  - Cross-cutting concerns — auth, validation, shared types, DB schema, tests
  - Complexity signals — shared infrastructure, risky patterns, large fan-out
  - Unconfirmed areas — areas the ticket implies that are NOT present in
    the current working tree (e.g., a different repo, a microservice at
    a different path)

Distinguish clearly between "confirmed in working tree" and "implied by
ticket but not found here". Keep it brief — scope assessment, not deep-dive.
```

```text
read scout.findings in full
do NOT skip — even on tickets that read as trivial
```

## Step 1.5 — Multi-Area Verification Gate

```text
if scout.areas is empty:
  🛑 Hard stop — scope scout returned no areas
  AskUserQuestion → "Scope scout found no areas — how to proceed?"; options:
    (a) "Re-run scout with a refined prompt"
    (b) "Confirm ticket touches no code (docs-only / config-only)"
    (c) "Wrong working directory — open the right repo and re-run"
  do NOT proceed to size classification with empty scope

  match user_response:
    case (a):
      session.scope_scout_retries = (session.scope_scout_retries or 0) + 1
      if session.scope_scout_retries > 3:
        🛑 Hard stop — empty-scope re-scout limit reached after 3 attempts
        ask user to choose (b) confirm-docs-only or (c) wrong-repo; do NOT loop further
      else:
        re-run Step 1 (Scope Scout) with refined prompt
    case (b):
      record exclusion as KNOWN_ASSUMPTION ("ticket confirmed docs-only / config-only")
      session.plan_size = "XS"                # docs-only / config-only → trivial size
      goto Phase 4                            # bypass Step 2 sizing + Steps 3-5 planning
    case (c):
      ❌ Error — tell user to open the correct repo and re-run /implement; STOP

for area in scout.areas:
  if Glob(area.path) or Read(area.path) returned results:
    area.status = "verified"
  else:
    area.status = "not_found"

if all areas verified:
  goto Step 2
else:
  HARD STOP — present the gate block below
```

Gate (⚠️ Multi-area gap — planning cannot continue safely). List the gap areas in the
question context (one `• {area} — {why the ticket implies it}` per missing area), then:

```text
AskUserQuestion → "Areas relevant to this ticket are missing from the working directory — how to proceed?"; options:
  (a) "Provide the path(s) — open the missing repo(s) as an additional working directory or symlink them in, then re-run /implement {session.ticket_key}"
  (b) "Provide a description — paste the interface / API contract / schema / spec for each missing area so architects design without reading code"
  (c) "Confirm out of scope — this ticket does NOT touch the listed area(s); planning proceeds without them"
do NOT proceed past this gate until the user responds
```

Handle response:

```text
match user_response:
  case (a):
    session.scope_scout_retries = (session.scope_scout_retries or 0) + 1
    if session.scope_scout_retries > 3:
      🛑 Hard stop — Multi-Area Gate reached after 3 re-scout attempts
      ask user to choose (b) provide-description or (c) confirm-out-of-scope; do NOT loop further
    else:
      re-run Step 1 (Scope Scout) with new path(s) available
  case (b):
    record description as STATED_CONSTRAINT
    label: "⚠️ User-provided spec — not verified in working tree"
    architects MUST NOT infer beyond what was provided
  case (c):
    record exclusion as KNOWN_ASSUMPTION
    surface it in Step 5 under "Known risks, assumptions, or scope questions"
    session.plan_size = "XS"                # docs-only / config-only → trivial size
    goto Phase 4                            # bypass Step 2 sizing + Steps 3-5 planning
```

## Step 2 — Classify Size from Scout Findings

Size is determined by what the scout found, not by the ticket text.

| Size  | Scout signal                                                                  | Planning approach                                        |
| -     | -                                                                             | -                                                        |
| XS/S  | 1–3 files, localized, no cross-cutting concerns                               | No additional explorers; 1 architect agent.              |
| M     | A few related files, minor shared concerns                                    | 1 additional explorer + 1 architect agent.               |
| L/XL  | Many files, shared infrastructure, uncertain architecture, risky patterns     | 2 additional explorers + 2–3 architect agents.           |

```text
session.plan_size = chosen size from the table above
                    (XS / S / M / L / XL)

if scout finds unexpected complexity in a "simple" ticket:
  classify up — do not ignore the signal
```

## Step 3 — Spawn Additional Explorers (M or larger only)

Spawn each in a single message (parallel when count >= 2):

```text
for explorer_aspect in EXPLORER_ASPECTS_FOR_SIZE:
  Agent(
    subagent_type = "Explore",
    description   = explorer_aspect.description,
    prompt        = explorer_aspect.prompt
  )
```

`EXPLORER_ASPECTS_FOR_SIZE`:

```text
M:    [similar_features]
L/XL: [similar_features, architecture_and_abstractions, testing_patterns]
```

`EXPLORER_ASPECTS` — each aspect has a description and a fully-specified prompt:

```text
similar_features:
  description: "Find similar features in the codebase"
  prompt:      "Find 5–10 files in this codebase that implement features similar
                to {ticket.title}. Return file paths confirmed via Glob or Read,
                a one-line summary per file, and pattern names worth reusing.
                Mark any file you cannot verify as UNCONFIRMED."

architecture_and_abstractions:
  description: "Map the architectural seams this work will cross"
  prompt:      "Identify the architectural layers, abstractions, and module
                boundaries touched by {ticket.title}. Return: layer names,
                key interfaces, where the new work crosses each boundary,
                and any inversion-of-control / DI plumbing that affects design.
                Glob/Read each named file before claiming it."

testing_patterns:
  description: "Map testing conventions used in this area"
  prompt:      "Find the testing patterns / harness / fixtures used by code
                near the files touched by {ticket.title}. Return: test file
                naming, runner config, fixture conventions, and any pattern
                used to test behavior across the architectural seam this
                work will cross. Verify each file exists in the working tree."
```

Each explorer returns 5–10 key files to read. Files MUST be Glob- or Read-verified.

```text
after all explorers return:
  read the listed files before spawning architects
  if explorer listed unconfirmed files:
    treat as unconfirmed; do NOT pass to architects as facts
```

## Step 4 — Spawn Architect Agents

Spawn in parallel — single message, multiple `Agent` tool calls:

```text
for architect_approach in ARCHITECT_APPROACHES_FOR_SIZE:
  Agent(
    subagent_type = "Plan",
    description   = architect_approach.description,
    prompt        = architect_approach.prompt
  )
```

`ARCHITECT_APPROACHES_FOR_SIZE`:

```text
XS/S: [pragmatic]
M:    [minimal, clean]                # two architects, presented side-by-side
L/XL: [minimal, clean, pragmatic]
```

Approach definitions:

```text
minimal   — smallest-change, lowest risk
clean     — idiomatic, best long-term maintainability
pragmatic — balance of speed and quality
```

## Step 5 — Consolidate and Present

Present this to the user:

```text
1. Approach summaries        — 2–3 sentences each
2. Trade-offs                — table or bullets
3. Recommendation            — with reasoning
4. Key files                 — verified existing files to modify
                               new files clearly labelled (new)
5. Test strategy             — Red / Green / Blue TDD discipline
6. Known risks, assumptions, or scope questions:
   - Any areas excluded per Step 1.5 (c)         → labelled "assumed out of scope"
   - Any user-provided specs per Step 1.5 (b)    → labelled "⚠️ unverified: user-provided"
   - Any cross-project deps not verifiable locally
7. AC → behavior map         — for each ticket AC, list the behavior(s) and file(s)
                               that will implement it; engineers reference these
                               indices in Phase 4 commit-message footers
                               (e.g., commit body "AC: 1, 3")
8. PE-domain hint            — see PE_DOMAIN_HINT below

session.matched_pes = result of PE_DOMAIN_HINT pseudocode below
                      (carried into End block's completion summary)
```

`PE_DOMAIN_HINT` (informational only — actual PE dispatch happens in the `review` skill):

```text
matched_pes = []

for file in plan.key_files:          # a preview; skills/review/bin/scope.js holds the authoritative globs
  match file:
    case "*.cs" | "*.csproj" | "*.sln"                  → matched_pes += ["sdlc:pe-csharp"]
    case "*.ts" | "*.html" under Angular project        → matched_pes += ["sdlc:pe-angular"]
    case "*.sql" | "migrations/*"                       → matched_pes += ["sdlc:pe-sql-server"]
    case ".github/workflows/*.yml" | ".github/workflows/*.yaml"
       | "action.yml" | "action.yaml"                   → matched_pes += ["sdlc:pe-github-actions"]
    case "*.go" | "go.mod" | "go.sum"                   → matched_pes += ["sdlc:pe-go"]
    case "*.vue" | "nuxt.config.*" | "tailwind.config.*" → matched_pes += ["sdlc:pe-vue"]
    case "cdk.json" | "*.tf" | "Dockerfile*"
       | "template.yml" | "*.template.yaml"             → matched_pes += ["sdlc:pe-aws-infra"]
    case "**/SKILL.md" | "**/agents/*.md" | "**/commands/*.md"
       | "**/CLAUDE.md" | "**/CLAUDE.*.md" | "**/*.code.md" | "**/*.ceo.md"
       | ".claude/rules/**"
       | governance references/*.md, model-consumed assets/*.md, plugin/skill READMEs
                                                        → matched_pes += ["sdlc:pe-governance"]

session.matched_pes = unique(matched_pes)

if session.matched_pes is not empty:
  print "Review will dispatch: " + join(session.matched_pes, ", ")
else:
  print "Review will route to sdlc:pe-general-purpose (no PE domain match)"
```

## Step 6 — HARD STOP

Under `session.incident`, SKILL.md Phase 3 answers this gate with the plan reviewer instead; run this step only
when Phase 3 hands the gate back on escalate, with the reviewer's concern leading the question.

Apply the **🟡 Waiting on you** convention (see SKILL.md → User-Facing Output Conventions).

This gate is ALWAYS interactive — in `--auto` it is the single retained human stop (a concrete plan is
the strongest consent). Auto NEVER auto-approves the plan. When `session.auto`, include the reminder in
the question context so the approval is informed consent.

Present the plan above, then invoke the gate:

```text
AskUserQuestion → "Approve this plan? (--auto: approving runs implementation unattended; any halt hands control back)"; options:
  (a) "Approve & implement (recommended) — proceed to Phase 4"
  (b) "Revise — I'll describe changes (use the prompt's free-text / Other reply)"
```

Approval logic:

```text
if user picked option (a) OR user_response.lower().strip() in ["approved", "approve", "go", "lgtm", "proceed", "ship it"]:
  proceed to Phase 4 (Implementation)
else:   # option (b), or any free-text feedback (incl. partial approval like "looks good but tweak X")
  for every revision, surface a diff against the prior plan:
    added:     list new ACs, files, behaviors, or risk items
    removed:   list dropped items
    unchanged: indicate stability of the rest
  revise plan based on feedback, re-present (with the diff block)
  do NOT loop back to Phase 2
  do NOT start implementation

revision count is uncapped — engineer iterates until satisfied
```
