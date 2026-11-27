---
name: review
description: Code review with stack-specialized PE dispatch and a two-gate model (Gate 1 local lock decided by a deterministic findings-ledger controller; Gate 2 independent peer review). This skill should be used when the engineer says "review my branch", "review PR #N", "code review", "/sdlc:review", or invokes review via the deliver orchestrator. PEs run a five-pass protocol with mandatory Pass 4 (Adversarial Re-read) and Pass 5 (Self-Adversarial). Skill enforces severity-gated verdict (every in-scope MEDIUM+ finding requires remediation; LOW/INFO are advisory and listed, never gating), per-finding legitimacy validation, one-agent-per-matched-PE dispatch (all 5 lens augmentations folded into each prompt; classifier-chosen TRIVIAL/STANDARD/DEEP depth tier), bug-shape grep on PATTERN findings, acceptance-criteria conformance against the linked GitHub issue or local story, and append-only multi-round reviews committed under ./docs/code-reviews/.
argument-hint: "[cleanup] [--auto] [--model-by-review-tier | --no-model-by-review-tier] [--builds worktree|checkout|off]"
---

# Review (sdlc:review)

PE-dispatch orchestrator with a severity-gated verdict, a two-gate model, and legitimacy enforcement. Stack-specialized PE sub-agents do the reviewing; this skill scopes the change, dispatches them, validates and consolidates their findings, and records append-only reviews in the repo (`references/review-store.md`). Deterministic steps run as scripts in `${CLAUDE_PLUGIN_ROOT}/skills/review/bin/` — run them and act on their JSON; never re-derive their results by hand.

```text
phases:
  1 — Scope Analysis       review type, checkout, ticket + ACs, scope.js classify, gate, pre-dispatch judgment, banner
  2 — Round State          in_scope rule, round number, findings ledger, gate prerequisites   (references/round-state.md)
  3 — PE Dispatch          one agent per matched PE; lenses + tier contract; collect            (references/dispatch-and-collect.md)
  4 — Validate + De-dup    tier escalation, findings.js validate + dedup, cross-PE, bug-shape grep
  5 — Legitimacy Gate      receipt proof, second pass, severity adjust, rebuttals               (references/legitimacy-gate.md)
  5.5 — AC Conformance     unmet in-scope criterion → HIGH finding                              (references/legitimacy-gate.md)
  6 — Verdict + Rounds     Gate 2 CI gate, review-file.js verdict, Gate 1 convergence.js / Gate 2 gate2, persist, loop, override
  7 — Output               commit, progress comment, PR comment + verdict, Slack, stash restore, worktree teardown   (references/publish.md)
```

| Script | Commands | Used in |
| - | - | - |
| `bin/scope.js` | `classify`, `pe-tiers` | Phase 1, Phase 3 |
| `bin/findings.js` | `validate`, `dedup` | Phase 4, Phase 5 |
| `bin/review-file.js` | `parse`, `verdict`, `gate2`, `render` | Phases 2, 6, 7 |
| `bin/convergence.js` | `status`, `record` | Phases 2, 6 |
| `bin/worktree-cleanup.js` | `list`, `classify` | Phase 1, cleanup |
| `bin/build-plan.js` | `plan`, `detect`, `release` | Phase 3, round teardown |
| `${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js` | `branch` | Phase 1 |
| `${CLAUDE_PLUGIN_ROOT}/bin/pr-checks.js` | `check` | Phase 6 (Gate 2) |

Every Node script exits 2 with `{error}` on stdout when it fails. On exit 127 (no Node): ❌ Error — sdlc:review needs Node on PATH; STOP. On any other script error: ❌ Error with its message; STOP (restore any stash first) — unless the calling step branches on the exit code itself (the Phase 1 worktree notice, `git-conventions.js branch`, round-state.md's `convergence.js status` branches, Phase 6's `convergence.js record`, `gate2` and `render` (exit 2 tears the round down), ci-gate.md's `pr-checks.js check`, dispatch-and-collect.md's `build-plan.js` plan, detect, and release).

## Input Gate Rendering

Every human-input gate is presented by INVOKING the AskUserQuestion tool, never as prose:

```text
for each input gate (choice / yes-no / free-text):
  question = gate name + one-line context (branch, PR, verdict, what just happened); header = ≤12-char gate label
  options  = the gate's enumerated choices, each → { label, description }; a stated default is listed FIRST with "(recommended)"
  free-text answer → the user's "Other" reply; the selection feeds the gate's `match user_response` unchanged
  under --auto, only the gate's own `if session.auto:` branch resolves it (prints 🤖, never asks); a gate without one asks
```

Invoke AskUserQuestion only when the user must act, one per pause, in the canonical shape `AskUserQuestion → "{q}"; options:` then one `({tag}) "label"` per line.

---

## Phase 1 — Scope Analysis

### Review type

```text
session.review_root = repo_root = `git rev-parse --show-toplevel`   # worktree mode (PR reviews) may override below
session.isolation   = "in-place"
session.auto        = ("--auto" in tokenize(user_request))          # deliver passes it for unattended runs
tokens = tokenize(user_request)
session.model_by_tier_cli = true if "--model-by-review-tier" in tokens else false if "--no-model-by-review-tier" in tokens else null
session.builds_flag = the value after "--builds" in tokens, else null   # worktree, checkout, or off; anything else: ❌ Error naming the flag and its values; STOP
user_request = user_request minus those flags (and the --builds value), whitespace collapsed
session.session_model = the model class this skill is executing as (opus | sonnet | haiku | fable)   # self-identified, not shell-probed

read ${CLAUDE_PLUGIN_ROOT}/references/settings.md and run load_settings()        # binds session.settings
read ${CLAUDE_PLUGIN_ROOT}/references/github-preflight.md and run it             # binds session.gh_ok, session.repo
session.reviewer_username = `gh api user --jq .login` if session.gh_ok else the local part of `git config user.email`

match user_request:
  case "cleanup" | "/sdlc:review cleanup" | "clean up review worktrees":
    read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/worktree-cleanup.md and run its Cleanup procedure
    exit                                        # no review runs
  case "review my branch" | "review this PR" | "/sdlc:review":
    current_branch = `git rev-parse --abbrev-ref HEAD`
    open_prs = `gh pr list --head "{current_branch}" --state open --json number,title,baseRefName` parsed as an array if session.gh_ok (error or bad JSON → []), else []
    {number, title, baseRefName} = open_prs[0]
    if open_prs is non-empty and session.auto:
      🤖 Auto-resolved — reviewing PR #{number} (open on {current_branch}); review_type = "PR Review"; pr_number = number
    elif open_prs is non-empty:
      AskUserQuestion → "Branch {current_branch} has open PR #{number} '{title}' → {baseRefName} — review which?"; options:
        (a) "PR Review — review PR #{number} (gate per Gate detection; Gate 2 if you are not the author)"
        (b) "Branch Diff — local diff vs main (Gate 1)"
      review_type = "PR Review" (pr_number = number) if (a) else "Branch Diff"
    else:
      review_type = "Branch Diff"
  case "review PR #N" | <GitHub pull-request URL>:  review_type = "PR Review"; pr_number = parse(N)
  case "review staged changes":           review_type = "Staged Diff"
  case "review these files: X, Y, Z":     review_type = "Specific Files"; targets = [X, Y, Z]
  case "review the {path} folder":        review_type = "Folder";         targets = [path]
  case <pasted code>:                     review_type = "Ad-hoc"; session.adhoc_code = the pasted block verbatim

if review_type == "PR Review" and (pr_number does not match ^[0-9]+$ or not session.gh_ok or not session.repo):
  ❌ Error — a PR review needs a numeric PR and gh signed in to this repo's GitHub remote; STOP
if review_type == "Branch Diff" and current_branch == "main":
  🛑 ask user which branch to review; do NOT proceed

wt = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/worktree-cleanup.js" list`
if wt exited 0 and wt.worktrees is non-empty:
  read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/worktree-cleanup.md and run its Stale notice procedure   # one line; removes nothing
```

### Base fetch + checkout

```text
match review_type:
  case "Branch Diff":
    git fetch origin main            # a stale base mis-scopes the review
    if fetch fails: 🛑 stop — report the error; ask the user to resolve
  case "Staged Diff":
    git fetch origin main            # scope is index-vs-HEAD; a failure only warns
    if fetch fails: ⚠️ warn — could not refresh origin/main; Staged-Diff scope is unaffected
  case "PR Review":
    read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/checkout.md and run § Fetch + PR metadata   # binds session.pr, session.source_branch, session.remote_ref
    if session.auto: 🤖 Auto-resolved — checkout → worktree path (a PR branch already checked out here is reviewed in place; HEAD never moves); user_response = (b)
    else:
      AskUserQuestion → "Review PR #{session.pr.number} ({session.pr.headRefName}) in which checkout?"; options:
        (a) "in-place (recommended) — check the branch out on this repo; visible in your IDE"
        (b) "worktree — isolated git worktree; the primary checkout's HEAD never moves"
    bind § Name before Acquire (the worktree is named by the key_slug)
    if (b):
      read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/worktree-isolation.md and run its Acquire procedure
      session.isolation = "worktree" if session.review_root != repo_root else "in-place"   # Acquire falls back to repo_root
    if session.isolation == "in-place":
      run checkout.md § In-place checkout

source_branch = session.pr.headRefName if session.pr else `git -C "{session.review_root}" rev-parse --abbrev-ref HEAD`
target_branch = session.pr.baseRefName if session.pr else "main"
```

### Name

```text
branch = session.pr.headRefName if session.pr else `git rev-parse --abbrev-ref HEAD`   # the PR's branch name, never a local pr-<N>
kb = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" branch <<'EOF'
{branch}
EOF
session.ticket_key   = kb.ticket_key        # "#<N>" | "<CODE>" | null
session.issue_number = kb.issue_number      # int for a "#<N>" key, else null
session.name = kb.key_slug if kb.key_slug   # file and worktree names
               else slugify(branch) if branch != "HEAD"
               else ask the user for a short descriptive name
```

### Ticket + acceptance criteria

Resolve acceptance criteria for Phase 5.5 from the GitHub issue, else the local story file in `docs/epics/`. All reads run from `{session.review_root}`.

```text
session.story = null; session.ticket_type = null; session.ticket_acs = []
code = session.ticket_key if session.ticket_key and not session.ticket_key.startswith("#") else null
story_file = null
if code:
  story_file = first of `grep -rlE '^\*\*Code:\*\* +{code} *$' docs/epics` (none → null)
for map in `docs/epics/*/.github-state.json` files:             # {"epic": <N>, "issues": {"<filename>": <issueNumber>}}
  if story_file and map.issues[basename(story_file)] and dirname(map) == dirname(story_file): session.issue_number = that number
  if not story_file and session.issue_number in map.issues.values(): story_file = the file in dirname(map) mapped to it
if story_file and not code: code = the story file's **Code:** value

issue = `gh issue view {session.issue_number} --json title,body,labels,state` if session.issue_number and session.gh_ok, else null   # failure → ⚠️ warn, null
text  = issue.body if issue else contents(story_file) if story_file else null
session.story = {text, state: issue.state if issue else null} if text else null
session.ticket_type = "Bug" if issue and any label name equals "bug" (case-insensitive) else "Story"

done_at_target = (issue and issue.state == "CLOSED")
  or `git -C "{session.review_root}" grep -qE '{DONE_RE}' "origin/{target_branch}" -- docs/epics` exits 0
  # DONE_RE: ^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*(#[0-9]+[[:space:]]*(—|-)[[:space:]]*)?(\*\*|\[)?{code}([^0-9A-Za-z]|$)   (code set)
  #          or ^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*#{session.issue_number}([^0-9]|$)                                       (issue set)

if session.ticket_key is null:    session.ac_conformance = "skipped — no ticket key resolvable from the branch"
elif done_at_target:              session.ac_conformance = "skipped — {session.ticket_key} is already done at {target_branch}"
elif session.story is null:       session.ac_conformance = "skipped — no issue or story file found for {session.ticket_key}"
else:
  session.ticket_acs = criteria parsed from text's "Acceptance Criteria" / "Expected Behavior" section (checklist or numbered items) or Gherkin scenarios, in order — never invented
  session.ac_conformance = "pending" if session.ticket_acs else "skipped — {session.ticket_key} states no acceptance criteria"
```

### Scope classification

`scope.js` owns the changed-file set, the `docs/code-reviews/**` exclusion, the tier signals and classifier tier, and the first-match glob routing of each file to one PE.

```text
mode, extra = match review_type:
  "Branch Diff"                → "branch", --range origin/main...HEAD
  "PR Review"                  → "pr",     --range origin/{target_branch}...HEAD
  "Staged Diff"                → "staged"
  "Specific Files" | "Folder"  → "files",  --targets {comma-joined targets}
  "Ad-hoc"                     → "adhoc",  --adhoc-lines {pasted line count}
scope = stdout of `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/scope.js" classify --root "{session.review_root}" --mode {mode} {extra}`
if exit == 3:
  🛑 stop — {scope.stop} ({scope.excluded}); restore any stash and exit
bind changed_files, files_changed, lines_added, lines_removed, diff_cmd, signals, security_files from scope
session.tier = scope.tier; session.tier_source = scope.tier_source; session.tier_signals = scope.tier_signals; session.routing = scope.routing; session.matched_pes = scope.matched_pes; session.ledger = scope.ledger
```

`pe-governance` owns model-audience instruction files (skills, agents, commands, the CLAUDE.md family, rules, skill references and model-consumed assets, plugin READMEs); `pe-github-actions` owns workflows and composite actions; human docs and structured data route to `pe-general-purpose`, the last-resort fallback. The primary agent never reviews code itself.

### Gate detection

```text
if review_type in ["Specific Files", "Folder", "Ad-hoc", "Branch Diff", "Staged Diff"]: session.gate = "Gate 1"
elif session.pr.author.login == session.reviewer_username:                           session.gate = "Gate 1"   # author self-review on the PR
else:                                                                                 session.gate = "Gate 2"   # independent peer

if operator or context proposes a different gate:
  AskUserQuestion → "Derived gate is {session.gate}. Escalating to {proposed} makes this an independent-peer review with Gate 2 lock bookkeeping. Confirm?"; options:
    (yes) "Escalate to {proposed}"
    (no) "Keep derived gate {session.gate}"
  if yes: session.gate = proposed; record "gate: engineer-confirmed escalation" in round metadata
```

### Pre-dispatch judgment

The scope.js tier and routing are the deterministic baseline and safety floor. Before the banner, read the changeset and refine both the way a human lead would — a logged, overridable refinement, never a coverage reduction. The glob classifier keys on filenames; this pass keys on what the change does. Signal sets: `${CLAUDE_PLUGIN_ROOT}/skills/review/references/dispatch-playbook.md` § Judgment Pass (`CONTENT_STACK_SIGNALS`, `CONTENT_RISK_SIGNALS`).

Read `{diff_cmd}` (the full patch; when `signals.size_large`, read headers for every file plus hunks of the pe-general-purpose residual and any file matching `CONTENT_RISK_SIGNALS`). Decide (a) which specialist each file truly needs — does its content reveal a stack the glob missed? — and (b) whether the change is riskier or more novel than its size implies (gate type, blast radius, and secrets/IAM/auth/money/data-integrity/migration semantics carried in values, not paths). Then merge:

```text
routing_baseline = copy(session.routing); tier_baseline = session.tier

# ROUTING — additive only
for file whose content reveals a specialist the glob missed: session.routing[file] = that specialist
session.matched_pes = unique(session.routing.values()) if session.routing else session.matched_pes   # Ad-hoc: keep scope.js's pe-general-purpose
assert every changed_file maps to exactly one PE; every glob-matched specialist is still matched; matched_pes non-empty

# TIER — raise freely; lower only to the floor
session.content_risk_files = changed files whose hunks match CONTENT_RISK_SIGNALS
session.content_risk       = session.content_risk_files is non-empty
tier_floor   = "STANDARD" if (signals.security_path or session.content_risk or signals.deps_or_schema) else "TRIVIAL"
session.tier = judgment_tier, clamped to rank no lower than tier_floor (TRIVIAL < STANDARD < DEEP)

# RECORD — baseline vs refinement
if session.routing != routing_baseline or session.tier != tier_baseline:
  session.tier_source       = "agent judgment: {one-line why}"
  session.tier_signals      = "floor {tier_floor}; judged {session.tier} ({gate/novelty/blast-radius/risk evidence})"
  session.routing_rationale = ["{file}: glob {pe} → {pe2} ({why})", ...] for each re-routed file
else:
  session.routing_rationale = []
```

### Banner

Display before any review work. The PR / Source / Target / Merge-base rows render only for PR Review, Isolation only in worktree mode, Routing only when judgment re-routed a file. `ac_check_row` is `"{len(session.ticket_acs)} criteria from {session.ticket_key}"` when `session.ac_conformance == "pending"`, else the skip-reason verbatim.

```text
┌─ REVIEW SCOPE ──────────────────────────
│ Name:        {session.name}
│ Type:        {review_type}
│ PR:          #{session.pr.number}  {session.pr.title}
│ Source:      {source_branch} @ {head_sha7}
│ Target:      origin/{target_branch} @ {target_sha7}
│ Merge-base:  {merge_base_sha7}   (SHAs: git -C "{session.review_root}" rev-parse / merge-base)
│ HEAD:        {head_sha7}
│ Isolation:   worktree → {session.review_root}
│ Diff:        {files_changed} files, +{lines_added}/-{lines_removed} lines
│ Matched PEs: {pe_list}
│ Routing:     {one line per session.routing_rationale}
│ Gate:        {session.gate}
│ Tier:        {session.tier}  ({session.tier_source}: {session.tier_signals})
│ AC check:    {ac_check_row}
│ Agents:      {len(session.matched_pes)}  (one per matched PE; sharding a big diff adds same-type agents)
└─────────────────────────────────────────
```

```text
if session.auto:
  🤖 Auto-resolved — banner accepted (auto): tier {session.tier}, {len(session.matched_pes)} agent(s); proceed to Phase 2

AskUserQuestion → "Review scope OK? Tier {session.tier} dispatches {len(session.matched_pes)} agent(s)."; options:
  (yes) "Proceed at tier {session.tier}"
  (tier TRIVIAL) "Override → TRIVIAL: changed lines + blast radius only"
  (tier STANDARD) "Override → STANDARD: changed files + producers/consumers"
  (tier DEEP) "Override → DEEP: full exploratory depth, complete suites"
  (no) "Stop — something's wrong (wrong PR, target, or file count)"
match user_response:
  case yes: proceed to Phase 2
  case "tier {T}":
    if T == "TRIVIAL" and (signals.security_path or session.content_risk):
      restate the security signal; require an explicit second confirmation, else re-prompt
    session.tier = T; session.tier_source = "engineer override (classifier said {prior tier})"; re-render; re-prompt
  case no:
    🛑 stop — ask what's wrong; restore any stash (publish.md § Step 6); exit
```

---

## Phase 2 — Round State

Each PE assigns `in_scope` per the review type (passed as `SCOPE` in the dispatch prompt); out-of-scope findings never gate:

| Review type | `in_scope` assignment |
| - | - |
| Branch Diff / Staged Diff / PR Review | lines added/modified, or functions/types/components containing changes; pre-existing issues → `in_scope=false` |
| Specific Files / Folder / Ad-hoc | everything provided → `in_scope=true` |

Read `${CLAUDE_PLUGIN_ROOT}/skills/review/references/round-state.md` and run it in order. It binds `review_file`, `output_path`, `session.ledger_path`, `session.head_sha`, `session.round_n`, `session.prior`, and `session.gate1_skip_note`, and may stop the round (post-lock waive, missing Gate 1 lock).

---

## Phase 3 — PE Dispatch

```text
read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/dispatch-playbook.md
LENS_AUGMENTATIONS = the 5 lens definitions     # all 5 ride in every dispatch prompt
TIER_CONTRACTS     = the 3 depth contracts      # keyed TRIVIAL | STANDARD | DEEP
SEARCH_BOUNDARY    = the § Search Boundary contract
PE_PROTOCOL        = read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/pe-protocol.md   # whole file — the five-pass protocol every PE runs
if PE_PROTOCOL is empty or lacks "## Output Format":
  🛑 stop — "pe-protocol.md is missing or unreadable under ${CLAUDE_PLUGIN_ROOT}; update or reinstall the sdlc plugin" — dispatch nothing
  restore any stash (publish.md § Step 6); exit
TIER_CONTRACTS[t]  = TIER_CONTRACTS[t] + "\n" + SEARCH_BOUNDARY  for t in [TRIVIAL, STANDARD]   # DEEP: no boundary

read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/dispatch-and-collect.md; run § Model-by-review-tier setting through § Collect, then § Round-to-round continuity
```

One agent per matched PE per round (a large diff may shard a PE into same-type agents); never one agent per lens, pass, or finding. The gate never changes the agent count or lens set.

---

## Phase 4 — Validate + De-duplicate

Run dispatch-and-collect.md § Tier escalation check first. Then read `${CLAUDE_PLUGIN_ROOT}/skills/review/references/finding-schema.md`, transcribe each collected YAML block to JSON field for field, and validate:

```text
redispatched = {}                                  # kind → [teammate]; bound once per round
loop:
  v = stdout of `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/findings.js" validate` < {outputs: {name: {pe: session.by_name[name], ...collected YAML}}, redispatched}
  if v.redispatch is empty: break
  for r in v.redispatch:
    SendMessage(to: r.name, summary: "schema violation", message: r.note); pending.add(r.name)
    redispatched[k] += [r.name] for k in r.kinds
  re-enter the Collect loop until every re-dispatched reply arrives, then re-transcribe and continue
collected_outputs = v.outputs; session.category_fallbacks = v.category_fallbacks; session.demoted = v.demoted
consolidated = (stdout of `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/findings.js" dedup` < {outputs: collected_outputs}).consolidated
```

Read `${CLAUDE_PLUGIN_ROOT}/skills/review/references/legitimacy-gate.md` and run § Cross-PE verification and § Bug-shape grep over `consolidated`.

---

## Phase 5 — Legitimacy Gate + 5.5 AC Conformance

Run legitimacy-gate.md from § Negative-receipt proof check through § Acceptance-criteria conformance. Its output is the culled `consolidated` (plus any unmet-AC HIGH findings), `dismissed_findings[]`, rebuttal outcomes, demoted receipts, and `session.ac_results`.

---

## Phase 6 — Verdict + Multi-round Loop

For a Gate 2 round, first read `${CLAUDE_PLUGIN_ROOT}/skills/review/references/ci-gate.md` and run it; it binds `session.ci` and may add a CRITICAL finding to `consolidated`.

### Severity-gated verdict

```text
v = stdout of `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" verdict` < consolidated
session.verdict = v.verdict   # 🚫 BLOCKED on in-scope CRITICAL/HIGH · ⚠️ CHANGES REQUESTED on in-scope MEDIUM · else ✅ APPROVED
```

Out-of-scope findings are awareness only. Unmet acceptance criteria entered `consolidated` as HIGH in Phase 5.5, so clean code that misses an AC never reaches ✅ APPROVED.

### Gate status

Computed BEFORE the round is persisted; an engineer override (below) supersedes it.

```text
round_input = [{location, severity: f.severity_reported or f.severity, title, category, in_scope} for f in consolidated]
if session.ledger:
  write round_input as JSON to "{session.ledger_path}.round.json"
  session.convergence = stdout of
    `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/convergence.js" record --ledger "{session.ledger_path}" --target "$(git -C "{session.review_root}" rev-parse --abbrev-ref HEAD)" --round {session.round_n} --sha {session.head_sha} --gate "{session.gate}" < "{session.ledger_path}.round.json"`
  delete "{session.ledger_path}.round.json"

if session.gate == "Gate 1" and not session.ledger:
  session.gate_status = "OPEN — not a branch review; no findings ledger"
  session.convergence = {decision: "CONTINUE", reasons: []}     # files / folder / ad-hoc rounds never lock Gate 1
elif session.gate == "Gate 1":
  parsed = session.convergence as JSON, else null
  if exit != 0 or parsed is null:                # fail closed — never fall back to prose-parse convergence
    msg = parsed.error if parsed and parsed.error else trim(stderr) minus a leading "convergence: "; newlines → " ", "|" → "\|"
    session.convergence = {decision: "HUMAN_GATE", error: msg, reasons: [], gate_status: "HUMAN_GATE — convergence controller error: " + msg}
  session.gate_status = session.convergence.gate_status          # verbatim; LOCKED… | HUMAN_GATE… | OPEN…
  for r in session.convergence.reasons or []: render "  ℹ️ convergence: {r}"
  if a reason starts with "replaced ledger round":
    ⚠️ Warning — ledger round(s) {listed} re-recorded; if round 1 is among them the history was truncated and the streak restarts
else:                                            # Gate 2: a peer round is recorded (errors only warn) but never decides the lock
  (g, ec) = `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" gate2 --file "{review_file}" --head {session.head_sha}` < {reviewer: session.reviewer_username, verdict: session.verdict, ci: session.ci}
  (session.gate_status, session.ci_hold) = (g.gate_status, g.ci_hold) if ec == 0 else ("OPEN — Gate 2 status error: " + (g.error or "exit {ec}"), true)   # fail closed
```

Reviewer diversity is a feature: independent Gate 2 reviewers surface complementary findings across rounds, never intra-round agent multiplication.

### Persist round + triage

The review file is the durable record — write it BEFORE any engineer gate so findings are never presented and lost.

```text
round = {
  name: session.name, branch: `git -C "{session.review_root}" rev-parse --abbrev-ref HEAD`, title: session.pr.title or the branch description,
  date: today, pr: {number: session.pr.number, url: session.pr.url, author: session.pr.author.login} if PR else null,
  reviewer: session.reviewer_username, head_sha: session.head_sha, gate_status: session.gate_status,
  agents: [{pe: session.by_name[n], model: d.model, tier: d.tier} for n, d in session.pe_dispatch],
  tier: session.tier, tier_source: session.tier_source, model_by_tier: session.model_by_tier,
  model_by_tier_source: session.model_by_tier_source, deep_guard_note: session.deep_guard_note,
  tier_escalations: [{pe, from: old_tier, to: new_tier, justification}], routing_rationale: session.routing_rationale,
  convergence_reasons: (session.convergence.reasons if session.ledger else []),
  files_changed, lines_added, lines_removed, changed_files, gate1_skip_note: session.gate1_skip_note,
  summary: 2–3 sentences — what changed, what was found, overall assessment,
  ac_results: [{ac: "#{r.index} {one-line r.ac}", verdict: r.status, evidence: r.evidence}] if session.ac_conformance == "pending",
  ac_skip_reason: session.ac_conformance otherwise,
  findings: consolidated,                        # severity, in_scope, title, location, locations, domains, category, description, recommendation
  dismissed: [{title, rationale, original_severity, outcome}],   # outcome: "dismissed" | "adjusted → {SEV}"
  rebuttals: [{title: rebuttal.finding_title, evidence: rebuttal.body, outcome}],
  receipts: [{claim, title, location, attestation, missing_source}]   # every PE receipt; a demoted finding → claim indeterminate (with missing_source) or below_bar, original description + missing proof in attestation
  category_fallbacks: session.category_fallbacks
}
read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/review-store.md
outcome = run its § Persist with round
if outcome == "stopped": run dispatch-and-collect.md § Round teardown, then publish.md Step 6; exit
# render creates the file or appends "## Review Round {n}", numbers findings, syncs the top Verdict line, and lists advisory LOW/INFO under § Advisory Findings as an index only: every finding keeps its full entry under § In Scope Findings

if session.verdict == "✅ APPROVED":
  render "✅ Round {session.round_n}: clean — 0 gating, {len(v.advisory)} advisory finding(s) · {output_path}"
else:
  render "🟡 Round {session.round_n}: {session.verdict} — {len(v.gating)} gating finding(s) · full detail → {output_path}"
  for f in v.gating, severity desc: render "  • [{f.severity}] {f.location} — {f.title}"
for f in v.advisory: render "  • [{f.severity}] {f.location} — {f.title} (advisory)"
```

### Multi-round loop

Each invocation is one round; the engineer drives the loop by remediating and re-invoking. Gate 1 terminates by the convergence decision (round cap 8); Gate 2 runs until MERGEABLE (a CI hold means re-run Gate 2 once the checks on HEAD's code have finished and are readable).

```text
if session.gate == "Gate 1" and session.convergence.decision == "LOCKED":
  render "🔒 {session.gate_status}"            # no prompt — Gate 1 is closed
elif session.gate == "Gate 1" and session.convergence.error:
  🛑 Hard stop — {session.gate_status}; fix the ledger / round input, remediate this round's findings, then re-run sdlc:review
  run § Round teardown, then Phase 7; exit
elif session.gate == "Gate 1" and session.convergence.decision == "HUMAN_GATE":
  🛑 Hard stop — {session.gate_status}
  if session.auto: run § Round teardown, then Phase 7; exit     # never auto-resolved; the caller hands back
  AskUserQuestion → "🛑 Round {session.round_n}: {session.gate_status}. How to proceed?"; options:
    (a) "remediate + re-review (recommended) — two consecutive clean rounds still lock"
    (b) "engineer override — proceed with findings open"
    (c) "abort — round is persisted; run § Round teardown, then stop"
elif session.verdict != "✅ APPROVED":
  if session.auto: 🤖 Auto-resolved — {len(v.gating)} gating finding(s) → remediate + re-review (the caller drives the next round); run § Round teardown, then Phase 7; exit
  AskUserQuestion → "🟡 Round {session.round_n}: {len(v.gating)} gating finding(s) open (listed above). How to proceed?"; options:
    (a) "remediate + re-review (recommended) — drives toward the 2-consecutive-clean lock"
    (b) "engineer override — proceed with findings open"
    (c) "abort — round is persisted; run § Round teardown, then stop; gate stays OPEN"
  NEVER mark a finding resolved without a real fix or a recorded override
```

### Engineer override + round teardown

An override (option b) runs round-state.md § Engineer override — mandatory pushback on every open MEDIUM+ finding, then a recorded entry. Run dispatch-and-collect.md § Round teardown on EVERY exit once teammates are spawned, abort branches included, so no live team leaks.

---

## Phase 7 — Output

The round is already on disk (Phase 6 § Persist). Read `${CLAUDE_PLUGIN_ROOT}/skills/review/references/publish.md`, `${CLAUDE_PLUGIN_ROOT}/references/issue-progress-comment.md`, and (for a PR Review with `session.settings.slack.enabled`) `${CLAUDE_PLUGIN_ROOT}/assets/slack-templates.md`, then run publish.md Steps 3–6. Step 6 (stash restore) always runs.

Then, in worktree mode only: if `session.review_committed`, run worktree-isolation.md's Teardown procedure (it prompts, defaults to KEEP, and removes only on explicit confirmation); otherwise ⚠️ keep the worktree — its review doc is not pushed yet.

---

## Severity Definitions

| Level | Criteria | Gating |
| - | - | - |
| 🔴 CRITICAL | Security vulnerabilities, data loss, breaking changes, test failures | 🚫 BLOCKED (requests changes on the PR) |
| 🟠 HIGH | Bugs, vet/typecheck warnings, significant design issues | 🚫 BLOCKED (requests changes on the PR) |
| 🟡 MEDIUM | Code quality concerns, maintainability risks affecting product behavior | ⚠️ CHANGES REQUESTED (gates the Gate 1 lock) |
| 🟢 LOW | Style, minor improvements | Advisory — listed under § Advisory Findings and in the PR comment; never gates |
| ℹ️ INFO | Minor real defects that clear the PE REPORTING BAR (observations, alternatives, future considerations → verification_receipts[]) | Advisory — listed under § Advisory Findings and in the PR comment; never gates |

This table is the one gating definition; PE severity definitions supply rating criteria only, and `review-file.js verdict` and `convergence.js` enforce the same MEDIUM threshold. Findings in data-integrity, migration, auth, or secrets are never rated below MEDIUM.

---

## Key Rules

- **Scripts own the deterministic steps** — scope, routing, validation, dedup, verdict, gate status, and the review-file format come from `bin/`; never re-derive them by hand.
- **Every finding requires legitimacy validation** — a Pass 5 receipt at PE level plus the Phase 5 second pass; INFO is held to the same bar as CRITICAL.
- **Scope discipline** — `in_scope: true` only for lines added/modified or functions/types/components containing changes.
- **Severity decides gating** — every in-scope MEDIUM+ finding must be addressed before the gate locks; LOW/INFO are advisory.
- **Findings vs verification receipts** — items failing the PE REPORTING BAR and positive attestations go in `verification_receipts[]` and never gate; re-dispatch unproven absence claims once, then retain them as receipts unless a finding proves an actual problem. Sources outside SEARCH_ROOTS use `claim: indeterminate` + `missing_source`.
- **PE dispatch contract** — pass the diff COMMAND, never diff content (Ad-hoc pasted code is the exception: it rides in PASTED CODE); inline the PE protocol, all lenses, and the tier contract (PEs cannot resolve `${CLAUDE_PLUGIN_ROOT}` paths).
- **One agent per matched PE per round (shardable)** — named `{pe}-r{round}-shard{n}`; lenses and passes are never dispatch units.
- **Review depth is tier-governed** — classifier-assigned, security-floored, engineer-overridable at the banner, PE-escalatable via `tier_escalation`.
- **Gate 1 convergence is code** — `convergence.js` records every branch round and decides LOCKED / HUMAN_GATE / CONTINUE (round cap 8 per cycle, reopen-guard 2, MEDIUM floor for data-integrity/migration/auth/secrets); it never waives a finding, and controller errors fail closed to HUMAN_GATE. Specific Files / Folder / Ad-hoc rounds never write the branch ledger.
- **Reviews live in the repo** — `docs/code-reviews/{key_slug}-code-review.md` and `-findings-ledger.json`, committed on the reviewed branch with an ordinary commit; CI runs on it like any other commit.
- **Gate 1 locks at 2 consecutive clean rounds**; **Gate 2 unblocks on unanimous APPROVED at the same HEAD SHA with HEAD's checks passed or none reported**; an override needs mandatory pushback and is recorded.
- **Verdicts on GitHub** — every PR Review posts a summary comment; `gh pr review --approve | --request-changes` runs only when the reviewer is not the PR author.
- **Standalone** — works without `deliver` and without GitHub for a branch review with a local story; deliver invokes review, review never requires deliver.
- **Automated author review-loop replies are brief pointers** — use `assets/slack-templates.md` → **Author Review-Loop Reply**, only when a PR Announcement thread already exists and Slack is enabled.
- **Worktree isolation is PR-Review-only** — interactive runs default to in-place; `--auto` always takes the worktree path, which reuses the primary checkout when the PR branch is already checked out there; teardown defaults to KEEP and never auto-removes. Front-end installs, builds, and tests run where the engineer chose (a disposable worktree, their checkout without installing, or nowhere — `off` applies everywhere); otherwise a review worktree builds in itself, and in place `--auto` takes the disposable worktree unless the branch remembers a choice — never an install or build output in the engineer's checkout, never a production configuration.
- **Validate PR-sourced identifiers before shell interpolation** — `pr_number` must match `^[0-9]+$`, branch names must match a safe-ref allowlist; interpolate quoted with the options terminator after the ref (`git checkout "{branch}" --`). Free-text and PR-JSON values are untrusted input; branch names reach `git-conventions.js` on stdin through a quoted heredoc.
