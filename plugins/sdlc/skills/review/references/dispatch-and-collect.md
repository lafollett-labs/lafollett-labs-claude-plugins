# Dispatch and Collect

Loaded by SKILL.md at Phase 3, after it has read the dispatch playbook, the PE protocol and the review moves and bound `LENS_AUGMENTATIONS`, `TIER_CONTRACTS`, `PE_PROTOCOL` and `REVIEW_MOVES`. Covers everything from spawning the PE teammates to holding their validated output, including the Phase 4 tier-escalation check.

## Contents

- Model-by-review-tier setting
- Dispatch model
- Search roots + per-PE tier
- Model-by-review-tier resolution + DEEP guard
- Build root
- Lineage inputs
- Dispatch input contract
- Dispatch invocation
- Collect
- Round-to-round continuity
- Tier escalation check
- Round teardown

## Model-by-review-tier setting

Each PE runs on the model its effective review tier warrants when the setting is on. Precedence: CLI flag (parsed in SKILL.md Phase 1) > repo `.claude/sdlc.json` > user `~/.claude/sdlc.json` (`review.modelByTier`) > default on.

```text
repo_root  = `git rev-parse --show-toplevel`
user_home  = `bash -c 'echo "$HOME"'`         # resolve to an absolute path BEFORE Read — its contract requires one;
                                              # never a literal ~. NO -l: $HOME is already inherited, and a
                                              # login shell can leak profile banners into stdout. Empty/failed → skip.
# Tolerant read — ANY failure (file absent/unreadable, content not valid JSON, or the key absent) returns
# null → skip that tier.
read_model_by_tier(path):
  if Read(path) succeeds AND its content parses as JSON:  return the parsed object's .review.modelByTier   # bool or null
  return null

repo_model_by_tier        = read_model_by_tier("{repo_root}/.claude/sdlc.json")                         # per-repo
user_global_model_by_tier = read_model_by_tier("{user_home}/.claude/sdlc.json") if user_home else null  # per-engineer, every repo

# Track WHICH source won — the analogue of session.tier_source; surfaced in the Phase 7 header.
if session.model_by_tier_cli is not null:    session.model_by_tier = session.model_by_tier_cli;    session.model_by_tier_source = "CLI flag"                   # CLI wins over everything
elif repo_model_by_tier is not null:         session.model_by_tier = repo_model_by_tier;           session.model_by_tier_source = "repo .claude/sdlc.json"     # repo wins over user
elif user_global_model_by_tier is not null:  session.model_by_tier = user_global_model_by_tier;    session.model_by_tier_source = "user ~/.claude/sdlc.json"   # then user
else:                                        session.model_by_tier = true;                         session.model_by_tier_source = "default"                    # default on
```

## Dispatch model

```text
DISPATCH MODEL — by default one agent per matched PE per round. NEVER one agent per
lens, per pass, or per finding. A large diff MAY shard one PE into several same-type
agents, partitioned along domain/concern boundaries the primary judges at dispatch (NOT
a static file split). dispatch_count == len(session.teammates), ≥ len(matched_pes);
the pre-flight banner shows the one-per-PE baseline.

vocabulary (canonical — every sdlc governance file conforms to these):
  pass / phase = a sequential stage INSIDE one PE agent's five-pass protocol — never a dispatch unit
  lens         = an attention augmentation inside a dispatch prompt — a way of reading, never a dispatch unit
  tier         = the review depth contract (TRIVIAL | STANDARD | DEEP), classified in Phase 1,
                 carried in every dispatch prompt as TIER_CONTRACT

Gate does NOT change agent count or lens set — gate semantics live in Gate
detection (Phase 1) and the two-gate model (Phase 6).
```

## Search roots + per-PE tier

```text
# Search roots — the reviewed tree + declared sibling repos (review.searchRoots); a hard boundary below DEEP.
# A non-list → no siblings.
declared = session.settings.review."searchRoots"    # merged .claude/sdlc.json, bound in SKILL.md Phase 1
session.search_roots = [session.review_root]
for entry in (declared if declared is a list of strings else []):
  path = realpath(entry if entry is absolute else "{repo_root}/{entry}")   # repo_root, not review_root: a worktree is not beside the siblings
  if path is not an existing directory:
    log "search root '{entry}' skipped — not a directory"
  elif path == repo_root or path is an ancestor of repo_root or path == user_home or path is a filesystem/drive root:
    log "search root '{entry}' rejected — reviewed repo, a parent of it, home, or a drive root"
  else:
    session.search_roots += [path]

# Per-PE effective tier — a PE whose files are all non-code artifacts (none security- or content-risk-flagged)
# runs TRIVIAL; every other PE runs the round tier. Routing here is the judgment-refined map.
session.pe_tiers = stdout of `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/scope.js" pe-tiers` < {tier: session.tier, routing: session.routing, content_risk_files: session.content_risk_files}
# pe_tier is TOTAL: a PE with no routed files (Ad-hoc's pe-general-purpose) runs the round tier,
# so model_for_tier never sees an undefined tier.
pe_tier(pe) = session.pe_tiers[pe] if pe in session.pe_tiers else session.tier
```

## Model-by-review-tier resolution + DEEP guard

Per-dispatch model selection keys on each PE's effective tier `pe_tier(pe)`. The model is an `Agent()` argument at dispatch — NEVER a PE-frontmatter pin (pe-governance forbids it). Feature off, and the DEEP tier when on, OMIT the arg so the PE inherits `session.session_model`.

```text
model_for_tier(tier):                        # tier → Agent() model= arg, or OMIT (→ inherit session.session_model)
  if not session.model_by_tier:  return OMIT              # feature OFF → the PE inherits the session model
  match tier:                                            # tier is always TRIVIAL|STANDARD|DEEP — pe_tier is total + requested_tier is TIER_RANK-validated, so no default case is reachable
    case "TRIVIAL":  return "haiku"                        # forced Haiku class
    case "STANDARD": return "sonnet"                       # forced Sonnet class
    case "DEEP":     return OMIT                           # pass-through the session model

logged_model(tier)  = model_for_tier(tier) if model_for_tier(tier) != OMIT else session.session_model   # what a PE at {tier} actually ran on
pe_model_arg(pe)    = model_for_tier(pe_tier(pe))         # Agent() model= arg for pe's Phase-3 tier
pe_logged_model(pe) = logged_model(pe_tier(pe))           # header value for pe

# DEEP guard — reusable: called at initial dispatch AND on any escalation into DEEP (§ Tier escalation
# check). Feature ON only. DEEP passes
# through the session model, so a non-Opus session runs the tier that most needs the frontier reasoner on
# a weaker/over-provisioned model. Interactive: confirm before dispatch. --auto: proceed + record loudly.
deep_guard(deep_names):                      # deep_names = the PE/teammate names about to dispatch at DEEP
  if not (session.model_by_tier and deep_names non-empty and session.session_model != "opus"):
    return                                   # feature off, no DEEP dispatch, or Opus session → no guard
  if session.auto:
    note = "⚠️ DEEP tier on non-Opus session model ({session.session_model}) — proceeded unattended (--auto): {join(deep_names, ", ")}"
    session.deep_guard_note = (session.deep_guard_note + " · " + note) if session.deep_guard_note else note
    ⚠️ Warning — {note}
  else:
    AskUserQuestion → "DEEP-tier dispatch on non-Opus session model {session.session_model}: {join(deep_names, ", ")} will run on {session.session_model}. Proceed?"; options:
      (yes) "Proceed on {session.session_model}"
      (stop) "Stop — I'll restart the session on Opus first"
    match user_response:
      case yes:
        note = "⚠️ DEEP tier dispatched on {session.session_model} (engineer-confirmed; session not Opus): {join(deep_names, ", ")}"
        session.deep_guard_note = (session.deep_guard_note + " · " + note) if session.deep_guard_note else note
      case stop:
        🛑 stop — restart the session on Opus and re-run
        restore_stash()                                  # SKILL.md § Shared routines
        if session.by_name is bound and non-empty: run § Round teardown   # escalation call: reap the live team (teardown invariant); no-op at the initial call, where by_name is not yet bound
        exit

session.deep_guard_note = null
deep_guard([pe for pe in session.matched_pes if pe_tier(pe) == "DEEP"])   # initial-dispatch guard (pre-spawn: by_name unbound, so a stop here needs no teardown)

# Freeze what each teammate dispatches on, for the Phase 7 header (session.* resets per invocation; the
# durable record is the review file). Keyed PER TEAMMATE (shard) so a partial escalation reports each
# shard's own model/tier; sharded teammates of a PE still share pe_tier(pe) at spawn → same
# model per shard. Populated in § Dispatch invocation, once session.teammates (shard names) exist.
session.pe_dispatch = {}   # teammate name -> {model, tier}
```

## Build root

Runs once per round, after the initial DEEP guard (a stop there leaves nothing to release). The engineer chooses where front-end PEs install, build, and test once per branch (remembered in the checkout's local git config); `build-plan.js` then places the build root and picks each Angular / Vue project's build: the repo's local build script or a non-production configuration, never a production one. § Round teardown releases its scratch directory.

```text
d = node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/build-plan.js" detect <<'JSON'
{"root": "{session.review_root}", "routing": {session.routing as JSON, or {} when unbound}}
JSON
fe = d.front_end if exit == 0 else false   # a front-end file in a front-end project changed, whichever PE owns it
branch = `git -C "{session.review_root}" rev-parse --abbrev-ref HEAD`
branch_ok = branch != "HEAD" and branch matches ^[A-Za-z0-9._/-]+$ and not branch.startswith("-")   # detached, or a name unsafe to interpolate: nothing is remembered
if session.builds is unbound and (session.builds_flag or (fe and session.isolation == "in-place")):
  remembered = `git -C "{session.review_root}" config --get "branch.{branch}.sdlcReviewBuilds"` if branch_ok else ""
  if session.builds_flag:                                    session.builds = session.builds_flag
  elif remembered in ["worktree", "checkout", "off"]:        session.builds = remembered
    ℹ️ Front-end builds: {remembered} (remembered for {branch}; --builds changes it)
  elif session.auto:
    session.builds = "worktree"
    🤖 Auto-resolved — front-end builds run in a disposable worktree (--auto)
  else:
    🟡 AskUserQuestion → "This review covers front-end code. Where should the PEs install, build, and test it?"; options:
      (worktree) "Disposable worktree (recommended) — a throwaway git worktree of the reviewed changes in Claude Code's temp folder; PEs run npm ci, the build, and the tests there. Costs a copy of the checkout plus a full node_modules (about 1 GB for a large app) and the npm ci time, every round. Your checkout, node_modules, and dist/ are never touched; the round removes the worktree."
      (checkout) "My checkout, no install — builds and tests use your current node_modules; build output goes to a temp dir the round removes. PEs never run npm ci or npm install, so a missing node_modules skips the build and tests and a stale one can fail them. The build still refreshes .angular/cache (and tsconfig.federation.json in federation apps), as a local build does. A staged review builds your working tree, not only the index."
      (off) "No front-end builds — PEs review without installing, building, or running front-end tests."
    session.builds = the chosen key
  if branch_ok and session.builds != remembered and (session.builds_flag or not session.auto):   # the engineer's choice, never the --auto default
    `git -C "{session.review_root}" config "branch.{branch}.sdlcReviewBuilds" "{session.builds}"`

r = node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/build-plan.js" plan <<'JSON'
{"root": "{session.review_root}", "checkout": "{session.isolation}", "mode": "{mode}", "builds": "{session.builds, else worktree}", "routing": {session.routing as JSON, or {} when unbound}}
JSON
# mode is Phase 1 § Scope classification's scope.js mode
if exit != 0:
  ⚠️ build plan failed: {r.error} — PEs review without front-end builds this round
  session.build_scratch = null; session.build_plans = []
  session.build_root_line = "none — the build plan failed; run no front-end install, build, or test this round"
else:
  session.build_scratch   = r.scratch            # released at § Round teardown; null when nothing was created
  session.build_root_line = r.build_line
  session.build_plans     = r.plans
  if r.swept: ℹ️ removed {len(r.swept)} build scratch dir(s) left by interrupted review rounds
  if session.build_scratch: session.search_roots += [session.build_scratch]   # the disposable worktree or build output stays inside SEARCH_ROOTS

build_plans(pe) = [p for p in session.build_plans if p.pe == pe]
```

## Lineage inputs

```text
session.prior_ids = null
P = session.prior.latest.reviewed_sha if session.prior else null
if session.round_n > 1 and scope.ledger and P                                   # a committed range: Branch Diff or PR Review
   and `git -C "{session.review_root}" merge-base --is-ancestor {P} {session.head_sha}` succeeds:   # rebased or missing → no lineage
  session.prior_ids = ids in session.prior.latest.in_scope_findings ∪ session.prior.latest.advisory   # the latest prior round's ids
  lines = "<rule> → N restatements checked[; kept <path:line> — <why>] @ <sha>" lines in the invocation text,
          the PR body, or a hand-off message
  fixes = `git -C "{session.review_root}" rev-list {P}..{session.head_sha}`
  session.ripple.kept    = lines whose sha, lowercased, is 7–40 hex and a prefix of a commit in fixes
  session.ripple.dropped = lines whose sha is not hex or names no commit          # HEAD or a branch name is not a sha
                                                                                 # a receipt from an earlier round is neither
```

## Dispatch input contract

PEs have Bash access — they pull their own diffs. The skill provides METADATA ONLY (never pre-fetched diff content).

```text
DISPATCH_PROMPT(pe, tier = pe_tier(pe)):   # tier keys BOTH the TIER line and its contract (boundary + budget)
"""
You are reviewing {session.name} as the {pe} agent.

DIFF COMMAND (run this yourself — do NOT ask the caller to paste it):
  {diff_cmd} -- {file patterns for this PE's domain; a domain PE: each of session.domain_pes[pe].files as a quoted literal path}
  # diff_cmd null: Specific Files / Folder → review the KEY FILES below in full; Ad-hoc → review PASTED CODE

KEY FILES CHANGED:
  {bullet list of changed files relevant to this PE's domain, from `--stat` output; a domain PE: session.domain_pes[pe].files}

SCOPE:          {review_type}
TARGET BRANCH:  {target_branch}
SOURCE BRANCH:  {source_branch}
HEAD SHA:       {session.head_sha}
WORKTREE:       {session.review_root}   # worktree path in worktree mode, else repo root — PEs cd here for all Bash ops
SEARCH_ROOTS:   {session.search_roots, comma-separated}   # below DEEP, a hard boundary for every search and read except PRIOR REVIEW / PRIOR LEDGER (TIER_CONTRACT § Search Boundary)
BUILD ROOT:     {session.build_root_line}   # where front-end installs, builds, and tests run
ISSUE_ID:       {session.ticket_key, else session.name}
GATE:           {session.gate}
ROUND:          {session.round_n}
REPLY-TO:       {session.pe_reply_to}   # SendMessage your YAML block here — you run in background; plain text is NOT visible to the lead
TIER:           {tier}
TIER_CONTRACT:  {TIER_CONTRACTS[tier]}   # see references/dispatch-playbook.md § Depth Tier Contracts

LENSES — attention augmentations. Apply each of them through every pass and
re-apply each one explicitly during Pass 4 alongside the PE PROTOCOL's common lenses
and your agent's stack lenses (they augment, never replace them):
  1. semantic-consistency:             {LENS_AUGMENTATIONS["semantic-consistency"]}
  2. delivery-pipeline + integration:  {LENS_AUGMENTATIONS["delivery-pipeline + integration"]}
  3. adversarial-security:             {LENS_AUGMENTATIONS["adversarial-security"]}
  4. workflow-correctness:             {LENS_AUGMENTATIONS["workflow-correctness"]}
  5. pseudocode-hygiene + AC-coverage: {LENS_AUGMENTATIONS["pseudocode-hygiene + AC-coverage"]}

{optional} PROJECT SUBDIR: {e.g., "frontend/" for Angular monorepo subdir}
{optional} PRIOR REVIEW:   {review_file if round > 1}   # Phase 2 binds it
{optional} FIX DIFF:       git diff {session.prior.latest.reviewed_sha}..{session.head_sha}   # when session.prior_ids is set (§ Lineage inputs)
{optional} RIPPLE RECEIPTS: {session.ripple.kept, one per line, else "none"}   # when session.prior_ids is set
{optional} PASTED CODE (Ad-hoc only — review this in full; there is no file or diff):
  {session.adhoc_code}
{optional} PRIOR LEDGER:   {session.ledger_path if session.ledger_path and it exists}   # Gate 1 only; prior findings' raw title + category per round
{optional} TEST BUDGET:    none — run no build, test, or lint suite; the stack PE reviewing these files runs them
                           # only when pe in session.domain_pes (kind: domain)
{optional} BUILD PLAN:     one line per p in build_plans(pe): "- {p.dir} ({p.kind}): {p.status}{" · checks: skip" if p.checks == "skip" else ""} — {p.command or p.reason} · receipt: {p.receipt}"
                           # only when build_plans(pe) is non-empty

PE PROTOCOL — run it as written; your agent definition adds only stack knowledge
(owned files, commands, stack heuristics, stack lenses):
{PE_PROTOCOL}

REVIEW MOVES — apply every move after the five passes; return move: on each finding and moves_coverage:
{REVIEW_MOVES}

Run the PE PROTOCOL's five passes (all five at every tier):
  Pass 1 — Architecture
  Pass 2 — Quality + Tests
  Pass 3 — Security
  Pass 4 — Adversarial Re-read (required — includes the LENSES block above)
  Pass 5 — Self-Adversarial (required — verification receipt per finding)

TIER ESCALATION VALVE:
  If the diff demands more depth than TIER permits, STOP expanding scope and emit
  a top-level `tier_escalation:` field (requested_tier + one-line justification)
  in your YAML, plus the findings gathered so far. The caller re-dispatches you
  at the higher tier. Never silently exceed the tier; never silently under-review.

OUTPUT CONTRACT:
  Emit ONE YAML block matching PE PROTOCOL § Output Format and DELIVER it via
  SendMessage(to: REPLY-TO, summary: "<your expert> review findings", message: <the YAML block>) —
  summary is REQUIRED when message is a string; your plain-text turn output is NOT visible to
  the lead. Findings without a concrete recommendation: field will be REJECTED and the PE
  re-dispatched with a violation note. Items that fail your REPORTING BAR ("is this a real defect a
  senior reviewer would want fixed or flagged on this PR?") and positive attestations belong in verification_receipts[],
  not findings[]; every receipt sets `claim:` (absence|positive|below_bar|indeterminate), and an
  absence receipt must carry `evidence:` (command + its output). Only YOUR OWN absence assertions need
  evidence; below DEEP, a claim a reviewed document makes about a system outside SEARCH_ROOTS is
  claim: indeterminate with missing_source: naming that system. Set `category` on every finding and every absence receipt. A finding that re-flags
  a prior defect MUST reuse its title and category VERBATIM (ledger identity) — from PRIOR LEDGER when that finding is there,
  else from PRIOR REVIEW.
"""
```

## Dispatch invocation

PEs declare `background: true` — each runs async and delivers via `SendMessage(to: "main")`, NOT via
tool result. Each round spawns FRESH teammates under collision-proof names (`{pe}-r{round}-shard{n}`);
keep every teammate ALIVE for the whole round — even after it goes idle — so you can re-dispatch it by
name in Phase 4/5. Tear the team down at round end (§ Round teardown). Spawn ALL in a SINGLE message so they run in parallel:

```text
session.pe_reply_to = "main"        # the orchestrator running this skill IS main; injected into DISPATCH_PROMPT

# Collision-proof names: round# separates rounds, shard# separates same-type instances. One teammate per
# (pe, shard); default one shard per PE. To shard a big diff the primary widens `shards` to [1,2,…],
# splitting the PE's work by domain/concern at dispatch (judgment, not a static file split).
session.teammates = []
for pe in session.matched_pes:
  shards = [1]                      # default one shard; primary widens to [1, 2, …] to split this PE
  session.teammates += [ {name: "{pe}-r{session.round_n}-shard{s}", pe: pe} for s in shards ]
session.by_name = { a.name: a.pe for a in session.teammates }   # teammate name -> pe (idle/terminated events carry the NAME)
session.pe_dispatch = { a.name: {model: pe_logged_model(a.pe), tier: pe_tier(a.pe)} for a in session.teammates }   # per-shard freeze for the Phase 7 header

for a in session.teammates:
  model_arg = pe_model_arg(a.pe)                     # OMIT (feature off, or DEEP) → do NOT pass model=; PE inherits session.session_model
  Agent(
    subagent_type     = "sdlc:{a.pe}",               # carries the stack knowledge + background:true; the protocol rides in the prompt
    name              = a.name,                      # e.g. "pe-csharp-r4-shard1" — collision-proof; NEVER bare "{pe}"
    run_in_background = true,                         # explicit; the agent's background:true frontmatter also forces it
    model             = model_arg,                   # include this line ONLY when model_arg != OMIT
    description       = "{a.pe} review — round {session.round_n}, {pe_tier(a.pe)} tier, model {pe_logged_model(a.pe)}",
    prompt            = DISPATCH_PROMPT(a.pe)
  )

assert count(spawned teammates) == len(session.teammates)   # ≥ len(matched_pes); banner shows the one-per-PE baseline
```

## Collect (async — teammates SendMessage their YAML to main; kept alive for the round)

Each PE delivers ONE YAML block via `SendMessage(to: "main")`. Messages AND teammate idle
notifications arrive automatically — do NOT poll. Gather until every PE reports; a PE that goes idle
WITHOUT delivering is nudged, then escalated — never an unbounded wait.

```text
collected_outputs = {}                        # name → payload (keyed by teammate name; a re-dispatch to the same name overwrites)
pending = set(a.name for a in session.teammates)
nudges  = {}                                  # name → idle-nudge count
retries = {}                                  # name → terminated-without-delivery re-dispatch count
spawns  = {}                                  # root → fresh-name counter (monotonic; never reuses a dead name)
awaiting_direction = set()                    # teammates waiting on the engineer's build direction
direction_default = null                      # "skip" once the engineer picks (skip-all)

# respawn(name) — EVERY Collect re-spawn (crash auto-retry and both engineer-chosen re-dispatch options)
# goes through here, so a re-spawned teammate keeps its CURRENT tier, never pe_tier's original.
respawn(name):
  root = name with any trailing "-retry{k}" removed
  spawns[root] = (spawns[root] or 0) + 1
  new = "{root}-retry{spawns[root]}"           # FRESH name — never the dead one
  session.by_name[new] = session.by_name[name]
  session.pe_dispatch[new] = session.pe_dispatch.pop(name, {model: pe_logged_model(session.by_name[name]), tier: pe_tier(session.by_name[name])})   # move the dispatch record onto the fresh name — keeps pe_dispatch keyed to a live teammate for the header + any later escalation del
  t = session.pe_dispatch[new].tier            # the teammate's CURRENT tier — an escalated shard re-spawns escalated
  if esc_tier is bound and name in esc_tier: esc_tier[new] = esc_tier[name]   # Phase 4 re-collect: keep the escalation keyed to the live name
  Agent(name = new, model = model_for_tier(t) unless OMIT, …, prompt = DISPATCH_PROMPT(session.by_name[name], tier = t))
  pending.add(new); pending.remove(name)

while pending is not empty:
  await next event              # a teammate YAML message, an idle notification, OR a teammate-terminated notification
  if event is a message m whose first line is "build_direction" from `name` in pending:   # "build_direction\nproject: …\nquestion: …"
    if session.auto: answer = "skip"; 🤖 Auto-resolved — {name}: no non-production build for {m.project}; build skipped (--auto)
    elif direction_default: answer = direction_default
    else:
      🟡 AskUserQuestion → "{name} found no non-production build for {m.project}: {m.question}"; options:
        (skip)     "Skip the build — review without building (recommended)"
        (skip-all) "Skip this and every other build question this round"
        free-text "Other" reply → the script or configuration to build with
      answer = "skip" or the engineer's reply
      if (skip-all): direction_default = "skip"
    SendMessage(to: name, summary: "build direction", message: "build_direction answer: {answer}")
    awaiting_direction.add(name)                # forgive the idle the PE logged while it waited
  elif event is a YAML message m:
    name = the delivering teammate's identity (the message SENDER) — NOT the YAML `expert` field,
           which cannot disambiguate same-type shards
    if name in pending:
      collected_outputs[name] = parse(m)       # keyed off the ACTUAL YAML arriving — never an idle summary,
      pending.remove(name)                      # which can falsely read "findings sent" when nothing was sent
      awaiting_direction.discard(name)
  elif event is a teammate-terminated notification for `name` in pending:
    # Died WITHOUT delivering — a crash, or a stale shutdown_request inherited from a prior round. Re-dispatch
    # fresh; the retry cap is aggregate per ORIGINAL teammate (root = name minus any -retry suffix), not per fresh name.
    root = name with any trailing "-retry{k}" removed
    if (retries[root] or 0) < 2:
      retries[root] = (retries[root] or 0) + 1
      respawn(name)
    else:
      🛑 AskUserQuestion → "{root} terminated without delivering {retries[root]}×. How to proceed?"; options:
        (re-dispatch) "Spawn a fresh teammate under a new name, keep waiting"   # retries[root] = 0; respawn(name)
        (drop)        "Drop this teammate this round — proceed without its findings"   # pending.remove(name)
        (abort)       "Abort the round — run § Round teardown, then stop"   # then restore_stash(); exit
  elif event is an idle notification for `name` in pending:   # alive but idled without delivering
    if name in awaiting_direction: awaiting_direction.remove(name); continue   # the wait for build direction, not a stall
    nudges[name] = (nudges[name] or 0) + 1
    if nudges[name] <= 2:
      SendMessage(to: name, summary: "deliver findings",
                  message: "You idled without delivering. SendMessage your YAML block to main per your OUTPUT CONTRACT.")
    else:
      🛑 AskUserQuestion → "{name} dispatched but did not deliver after {nudges[name]} nudges. How to proceed?"; options:
        (re-dispatch) "Shut down the stuck teammate, spawn a fresh one under a NEW name, keep waiting"   # SendMessage(to: name, {type: shutdown_request}); respawn(name); nudges reset for the fresh name
        (drop)        "Drop this teammate this round — proceed without its findings"   # pending.remove(name)
        (abort)       "Abort the round — run § Round teardown, then stop"   # then restore_stash(); exit

# Dedup keys findings by (location, normalized_title) over collected_outputs.values() (Phase 4),
# independent of the collect key — name-keying changes nothing downstream.
# Phase 4/5 re-dispatch (tier escalation, schema/Pass violation, absence proof): message the SAME live
# teammate by its name, re-add that name to `pending`, and re-enter this loop until its replacement
# YAML arrives — collected_outputs[name] = replacement overwrites the stale entry.
```

## Round-to-round continuity

```text
if review_file exists and prior round exists:
  PEs read prior review under PRIOR REVIEW path
  for each finding in prior round:
    PE marks as STILL_PRESENT, RESOLVED, or PARTIALLY_RESOLVED
    if STILL_PRESENT or PARTIALLY_RESOLVED:
      re-emit with the prior title AND category verbatim     # findings-ledger fingerprint identity
    PE does NOT re-raise RESOLVED findings
```

## Tier escalation check (consume BEFORE schema validation)

```text
TIER_RANK = {TRIVIAL: 0, STANDARD: 1, DEEP: 2}
session.tier_escalations = []        # bind before any conditional read in Phase 7
esc_tier = {}                        # name -> escalated tier; effective tier is PER-TEAMMATE, not the
                                     # PE-type-keyed pe_tier — so sharding never lifts a sibling shard silently

for name, pe_output in collected_outputs.items():
  pe       = session.by_name[name]              # the PE behind this teammate (≥1 teammate per PE when sharded)
  eff_tier = esc_tier[name] if name in esc_tier else pe_tier(pe)   # this teammate's current tier
  esc      = pe_output.tier_escalation          # null when the teammate did not escalate
  if esc exists:
    if esc.requested_tier not in TIER_RANK:      # PE-authored, untrusted — drop malformed before any lookup / model_for_tier
      ignore; log "malformed tier_escalation.requested_tier '{esc.requested_tier}' from {name} dropped"
    elif TIER_RANK[esc.requested_tier] <= TIER_RANK[eff_tier]:
      ignore; log "non-escalating tier_escalation from {name} dropped"
    elif name already escalated this round:
      ignore; log "one escalation per teammate per round"
    else:
      old_tier = eff_tier
      new_tier = esc.requested_tier
      tell engineer: "{name} escalated {old_tier} → {new_tier}: {esc.justification}"
      esc_tier[name] = new_tier      # per-teammate — a sibling shard of the same PE keeps its own tier
      record (name, old_tier, new_tier, esc.justification) in session.tier_escalations
      discard this pe_output (partial); remove collected_outputs[name]
      # A live teammate's model is fixed at spawn. Feature ON, if the escalation crosses a model band a
      # SendMessage would run the higher tier on the lower tier's model (e.g. DEEP depth on sonnet),
      # violating and skipping the DEEP guard. Re-SPAWN fresh at the new tier's model instead (mirrors
      # the crash-path re-spawn), and re-evaluate the DEEP guard for it.
      if session.model_by_tier and model_for_tier(new_tier) != model_for_tier(old_tier):
        if new_tier == "DEEP": deep_guard([name])          # re-evaluate the guard for the escalated teammate
        SendMessage(to: name, {type: shutdown_request, reason: "re-spawning at {new_tier} model"})
        new = "{name}-esc{TIER_RANK[new_tier]}"            # FRESH name — a running agent's model cannot change
        session.by_name[new] = pe; esc_tier[new] = new_tier
        Agent(name = new, subagent_type = "sdlc:{pe}", run_in_background = true,
              model = model_for_tier(new_tier) unless OMIT, prompt = DISPATCH_PROMPT(pe, tier = new_tier))
        session.pe_dispatch[new] = {model: logged_model(new_tier), tier: new_tier}   # header: escalated SHARD only; sibling shards keep theirs
        del session.pe_dispatch[name]                       # `name` was shut down + replaced by `new`
        pending.add(new)                                    # `name` already left pending on delivery (§ Collect) — nothing to remove
      else:
        # feature OFF, or escalation within the same model band → message the live teammate
        re-dispatch teammate `name` at tier new_tier via SendMessage(to: name, DISPATCH_PROMPT(pe, tier = new_tier)); pending.add(name)
        session.pe_dispatch[name] = {model: logged_model(new_tier), tier: new_tier}   # same key; model unchanged feature-off, tier now current — header stays accurate after a same-band escalation
      re-enter the Collect loop until the replacement YAML arrives (collected_outputs[the re-dispatched name]
        = replacement), then RESTART this escalation scan from the top over the updated collected_outputs —
        never continue the mutated .items() iteration

# Termination: escalation must strictly increase the tier; three rungs → at most two re-dispatches per
# teammate per round, so the restart-from-top above always converges.
```

## Round teardown

Run on EVERY exit once teammates are spawned — the normal path and every abort branch — so no live team or build scratch directory leaks:

```text
for name in session.by_name:        # every teammate spawned this round, including -retry and -esc respawns
  SendMessage(to: name, summary: "round {session.round_n} complete",
              message: {type: "shutdown_request", reason: "review round {session.round_n} complete"})
if session.build_scratch:
  node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/build-plan.js" release --dir "{session.build_scratch}"   # non-zero → ⚠️ warn with its error; never blocks
```
