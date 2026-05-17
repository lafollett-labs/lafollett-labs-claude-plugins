---
name: code-reviewer
description: Code reviews with stack-specific PE dispatch (pe-go, pe-vue, pe-aws-infra, pe-governance, pe-devtools). Four-pass protocol with mandatory adversarial re-read, scope discipline, SHA-locked rounds, de-duplicated findings in ./docs/code-reviews/. Engineer-driven multi-round loop with hard 3-round cap until APPROVED (LOW + INFO are awareness-only and do NOT block). pe-devtools calibrated for single-operator local threat model. Story-linked PRs additionally run Phase 4.5 Spec Coverage, asserting every story acceptance criterion is genuinely discharged or explicitly deferred.
---

# Expert Code Review

Lean, pragmatic code reviews with scope discipline. Stack-specific PE sub-agents do the heavy lifting; the parent skill orchestrates dispatch and consolidates findings.

---

## Phase 1: Scope Analysis

Determine review type from the user's request:

| User Request | Review Type | What to Review |
| --- | --- | --- |
| "Review my branch" / "Review this PR" | Branch Diff | `git diff main...HEAD` |
| GitHub PR URL or "Review PR #N" | PR Review | `git diff <target>...<source>` (auto-checkouts source branch) |
| "Review staged changes" | Staged Diff | `git diff --cached` |
| "Review these files: X, Y, Z" | Specific Files | Read and review entire files |
| "Review the src/services folder" | Folder | Read and review all files in folder |
| "Review this code" + pasted code | Ad-hoc | Review the provided code |

### Branch / Staged

```bash
git diff main...HEAD      # branch diff
git diff --cached         # staged changes
```

```
if current_branch == "main":
  ask user which branch to review (do NOT proceed)
```

### PR

```bash
gh pr view <PR_NUMBER> --json number,url,headRefName,baseRefName,author
git checkout <source_branch>
git pull
git diff <target_branch>...<source_branch>
```

Capture: source branch, target branch, PR number, PR URL, author. Store for Phase 6.

**Critical:** Review files MUST be committed to the source branch, never to main.

### Files / Folders / Ad-hoc

Read the files directly. No diff context — review entire content.

### Review Name (used for output filename)

```
if branch matches "<type>/<issue-id>-<description>":
  name = issue_id                 # e.g., "983"
elif on a branch (no issue ID):
  name = slugify(branch)          # e.g., "fix-code-reviewer-cleanup"
else:
  ask user for a short descriptive name
```

### PE Routing

```bash
git diff main...HEAD --stat | tail -1          # branch reviews (informational)
git diff <target>...<source> --stat | tail -1  # PR reviews (informational)
```

```
matching_pes = PEs whose Stack Map paths intersect with files in the diff

if matching_pes is empty:
  approach = "generic"     # primary runs generic three-pass (no PE expertise available)
elif len(matching_pes) == 1:
  approach = "single_pe"   # dispatch the one matching PE
else:
  approach = "multi_pe"    # dispatch all matching PEs in parallel
```

Diff size is informational only. Domain expertise is the constant — every review touching a stack with a matching PE dispatches that PE, regardless of line count.

---

## PE Agent Selection

The plugin ships five built-in PE sub-agents:

| Subagent | Domain | File patterns |
| --- | --- | --- |
| `code-reviewer:pe-go` | Go / PostgreSQL / AWS Lambda | `*.go`, `go.mod`, `go.sum`, `*.sql` |
| `code-reviewer:pe-vue` | Vue 3 / Nuxt 3 / TS / Tailwind / Storybook | `*.vue`, `*.tsx`, `*.jsx`, `tailwind.config.*`, `nuxt.config.*`, `vite.config.*`, `*.stories.*` |
| `code-reviewer:pe-aws-infra` | AWS CDK / Cloudflare CDKTF / Terraform / Docker / GH Actions | `cdk.json`, `*.tf`, `*.tfvars`, `Dockerfile*`, `docker-compose*`, `.github/workflows/*.yml` |
| `code-reviewer:pe-governance` | Agent definitions, skills, plugin instructions, CLAUDE.md | `.claude/agents/*.md`, `**/SKILL.md`, `plugins/**/agents/*.md`, `**/CLAUDE.md`, `.claude/rules/*.md`, `docs/rules/*.md` |
| `code-reviewer:pe-devtools` | Local dev tooling (single-operator threat model) — bash scripts, hooks, code-review wrappers | `scripts/dev/**`, `scripts/**/*.sh` with `# pe: devtools` header, `.githooks/**`, `lefthook.yml` |

Each agent has its own model (`claude-opus-4-7`), tools, and self-contained five-pass protocol (Architecture → Quality+Tests → Security → Adversarial → Self-Adversarial) — they do NOT need a reference file at runtime.

`pe-governance` reviews documents whose audience is the model (agent governance markdown). It does NOT review documents whose audience is humans (ADRs at `docs/architecture/*.md`, runbooks at `docs/runbooks/*.md`, review docs at `docs/code-reviews/*.md`, READMEs). Those fall to generic three-pass review.

`pe-devtools` reviews local dev tooling artifacts WITH A SINGLE-OPERATOR THREAT MODEL. Its adversarial pass asks "would this fail in normal operator use?" not "could a contrived attacker exploit this?" — calibrating against the over-hardening spiral that production-grade PEs (pe-aws-infra) generate when applied to local-only artifacts. Scripts that ARE production CI primitives (e.g., release workflows, multi-tenant ops tools) stay with pe-aws-infra.

### Selection Priority

```
1. .code-reviewer.yml (project config) — if it exists, read `stacks` array;
   match changed files against each stack's `paths` globs; map to subagent.
2. CLAUDE.md Stack Map — parse the table; map paths → stack → subagent.
3. File pattern fallback — match diff file extensions against the table above.
4. No match — generic three-pass review (Architecture → Quality → Security)
   without stack-specific test commands or domain checklists.
```

**Mixed diffs:** If the diff spans multiple stacks, dispatch ALL matching PE subagents in parallel (single message, multiple Agent calls). Each PE reviews only the portion of the diff relevant to its domain.

**Stacks not covered by built-in agents** (Rust, Python, Java, C#, etc.): primary agent runs the generic three-pass review directly. CLAUDE.md's Stack Map still tells the parent which paths are which stack and what test commands to run.

---

## Phase 2: Scope Discipline

```
diff-based reviews (Branch / Staged / PR):
  in_scope = issue is in lines added/modified OR in functions/types/components
             containing changes; pre-existing issues are in_scope=false (awareness)

file / folder / ad-hoc reviews:
  in_scope = true for everything provided
```

PEs apply this rule when assigning `in_scope` to each finding. Calling agent uses `in_scope=true` findings for verdict computation per § Verdict Logic.

---

## Phase 3: Review Execution

### Five-Pass Protocol

Each PE runs its own five-pass protocol — definitions live in PE files. The calling agent only invokes PEs and consolidates their YAML output. When NO matching PE exists (generic fallback case), the calling agent runs a three-pass equivalent itself:

```
generic fallback (calling agent runs directly when approach == "generic"):
  Pass 1 — Architecture:    SOLID, patterns, coupling, boundaries, migration safety
  Pass 2 — Quality + Tests: run Stack Map test commands; failures CRITICAL,
                            warnings HIGH
  Pass 3 — Security:        OWASP Top 10, auth, secrets, injection, supply chain
                            ("would this survive a pentest?", not "probably fine")
                            cross-file claim verification: doc-vs-artifact drift
                            on IAM/RBAC/auth claims is a security-grade finding

PE dispatch (approach == single_pe or multi_pe):
  PE runs five passes:
    Pass 1-3 — structured domain checks (read FULL files, not just diff hunks)
    Pass 4   — Adversarial Re-read (mandatory)
    Pass 5   — Self-Adversarial (mandatory — PE reviews its own findings for
               false positives, unverified assumptions, and cross-file blind spots)
  Skipping Pass 4 or 5 is a dispatch-contract violation.
```

### Dispatch

```
match approach:
  case "generic":
    # No matching PE — primary runs all three passes directly
    # using its own judgment + Stack Map's test commands.
    no sub-agent dispatch

  case "single_pe":
    Agent(
      subagent_type: "code-reviewer:pe-{stack}",
      prompt: <dispatch input — see below>
    )

  case "multi_pe":
    # Dispatch all matching PEs in parallel — single message, multiple Agent calls.
    for each pe in matching_pes:
      Agent(
        subagent_type: "code-reviewer:pe-{stack}",
        prompt: <dispatch input filtered to this PE's domain>
      )
```

### Dispatch Input

PEs have Bash access — they pull their own diffs. Do NOT pre-fetch or paste
diff content into the prompt. The calling agent provides metadata only:

```
You are reviewing changes for {ISSUE_ID}.

DIFF COMMAND (run this yourself — do NOT ask the caller to paste it):
  git diff {target}...{source} -- {file patterns for your domain}

KEY FILES CHANGED:
  {bullet list of changed files relevant to this PE's domain, from --stat output}

SCOPE: {Branch Diff | Staged Diff | PR Review}
TARGET BRANCH: {main | etc.}
SOURCE BRANCH: {current branch}
WORKTREE: {absolute path to repo root}
{optional} PROJECT SUBDIR: {e.g., "frontend/" for Vue/Nuxt subdir in a monorepo, "cdk/" for CDK subdir}
{optional} PRIOR REVIEW: {path to prior review doc if round 2+}
{optional} STORY_FILE: {absolute path to local story/epic markdown when PR is story-linked — PE may tag findings with discharges_ac: [AC-N] to enrich Phase 4.5 Spec Coverage}

Run your four-pass protocol (Architecture → Quality+Tests → Security → MANDATORY Adversarial Re-read).

DELIVERY CONTRACT — match your invocation mode:
  if dispatched as foreground Agent (no team_name):
    return YAML findings as your final tool-result message — calling agent
    receives it synchronously
  if dispatched as background teammate (team_name set):
    deliver YAML findings via the SendMessage tool to the team lead
    (typically `to: "team-lead"`) — rendering YAML in your session and
    going idle does NOT deliver to the calling agent
```

The PE returns ONLY a YAML block — see "YAML Finding Structure" below.

**Calling-agent contract:** when dispatching PEs with `team_name` set, the
calling agent MUST treat the PE as a background teammate and wait for a
SendMessage delivery, not a synchronous tool result. PEs that idle without
SendMessage have violated the team-mode contract and should be re-pinged.

---

## Phase 4: De-duplication + Cross-PE Verification

When consolidating sub-agent findings:

```
1. Merge duplicates:        same issue from multiple PEs = ONE finding
2. Tag domains:             merged finding gets `domains: [Security, Architecture]`
3. Keep highest severity:   if PEs disagree, use the higher severity

cross_pe_verification (when multiple PEs dispatched):
  Compare findings across PE domains for consistency:
    if PE-Go says "handler validates JWT" but PE-AWS-Infra says "no authorizer":
      flag the discrepancy — one PE may have missed something
    if PE-Go says "handler reads BEDROCK_MODEL_ID" but PE-AWS-Infra's stack
      doesn't set that env var:
      flag HIGH "env var mismatch between handler and CDK stack"
    if PE-AWS-Infra grants IAM actions the handler doesn't use:
      flag MEDIUM "over-permissioned IAM — handler doesn't call <action>"
    if handler makes AWS API calls PE-AWS-Infra didn't grant:
      flag HIGH "missing IAM grant — handler calls <api> but CDK doesn't grant it"
```

---

## Phase 4.5: Spec Coverage Trigger (Story-Linked PRs)

**Calling-agent responsibility only.** When the PR (or branch's primary linked issue) carries a `story` or `epic` label, the calling agent enriches PE dispatch inputs with the absolute path to the Spec Coverage protocol asset. PEs load the protocol themselves and run it as a story-linked-only pass (the protocol's pseudocode lives in `assets/spec-coverage-protocol.md` so reviewer agents — who do NOT see SKILL.md — actually have access to it).

### Trigger

```
issue_id = extract_issue_id(pr.title, pr.body, current_branch_name)
  # "Closes #NNN", "fix(#NNN)", "feat(#NNN)", or branch prefix <type>/<NNN>-<...>

if issue_id is None:
  story_linked = false
else:
  labels = bash: gh issue view <issue_id> --json labels --jq '.labels[].name'
  story_linked = ("story" in labels) or ("epic" in labels)

if not story_linked:
  # Non-story PR (chore, bugfix, task) — Phase 4.5 does not apply
  return
```

### Story File Resolution

```
# Priority order:
#   1. caller-provided STORY_FILE path
#   2. local epic file via docs/epics/*/.github-state.json mapping
#   3. GH issue body directly

story_file_path = None

if user passed STORY_FILE explicitly:
  story_file_path = <user value>
else:
  # Search local epics
  state_files = bash: find docs/epics -maxdepth 3 -name .github-state.json
  for state_file in state_files:
    if jq -r '.issues | to_entries[] | select(.value == <issue_id>) | .key' returns a filename:
      story_file_path = <state_file_dir>/<filename>
      break

  if story_file_path is None:
    # Fallback — fetch GH issue body to a temp file
    body = bash: gh issue view <issue_id> --json body --jq '.body'
    if body is empty or command failed (rate limit, network down):
      story_file_path = None  # keep None — fall through to gate
    else:
      bash: write body to /tmp/spec-coverage-<issue_id>.md
      story_file_path = /tmp/spec-coverage-<issue_id>.md

# FAILURE GATE — must run before Dispatch Input Enrichment
if story_file_path is None:
  # All three resolution paths failed. Do NOT enrich dispatch — dispatching
  # with STORY_LINKED: true + missing STORY_FILE would silently mis-fire.
  add to calling agent's own finding list:
    expert: "Spec Coverage"
    id: "SPEC-STORY-FILE-UNRESOLVED"
    severity: MEDIUM
    in_scope: true
    title: "Story link detected but story file unresolvable"
    description: |
      PR closes story-labeled issue #<issue_id> but neither caller-provided
      STORY_FILE, local docs/epics/*/.github-state.json mapping, nor
      `gh issue view <issue_id>` body-fetch fallback yielded a story file.
      Spec Coverage pass SKIPPED.
    recommendation: |
      Pass STORY_FILE explicitly via the skill invocation, OR add the issue
      to a local docs/epics/*/.github-state.json mapping, OR verify
      `gh issue view <issue_id>` works (auth + network).
  return  # do not proceed to Dispatch Input Enrichment
```

### Dispatch Input Enrichment

Resolve the absolute path to the protocol asset BEFORE dispatching — PEs must receive literal absolute paths, not `${CLAUDE_PLUGIN_ROOT}` placeholders:

```
plugin_root = bash: echo "$CLAUDE_PLUGIN_ROOT"
spec_coverage_protocol_path = plugin_root + "/skills/code-reviewer/assets/spec-coverage-protocol.md"

if plugin_root is empty:
  # Edge case: skill invoked outside plugin context. Fall back to absolute
  # path resolution via skill's own location (the file containing THIS
  # pseudocode is at <plugin_root>/skills/code-reviewer/SKILL.md):
  spec_coverage_protocol_path = bash: realpath "$(dirname "${BASH_SOURCE:-$0}")/assets/spec-coverage-protocol.md"
```

Append these fields to each PE's dispatch input:

```
STORY_LINKED: true
STORY_FILE: <absolute path resolved in § Story File Resolution>
SPEC_COVERAGE_PROTOCOL: <spec_coverage_protocol_path — absolute, no ${...} placeholders>
PR_NUMBER: <PR number, for `gh pr view <N>` calls inside the protocol>
```

The calling agent owns plugin-path resolution because it (the skill orchestrator) has reliable access to `$CLAUDE_PLUGIN_ROOT`. PEs at depth-1 do not — passing them a literal `${CLAUDE_PLUGIN_ROOT}/...` string would cause `Read()` to fail on the unresolved placeholder.

### PE Output for Spec Coverage Findings

PEs that detect AC-coverage failures emit findings with `expert: "PE-Spec-Coverage"` (sub-domain of their stack expertise) and append them to their YAML alongside stack findings. Phase 4 De-duplication consolidates these across PEs as it does any other finding category. Spec-Coverage findings carry the same severity discipline (BLOCKING for SPEC-MISSING / SPEC-EVIDENCE-MISSING / SPEC-DEFER-INVALID; CHANGES_REQUESTED for SPEC-WEAK-EVIDENCE / SPEC-FORMAT-MALFORMED).

The asset at `assets/spec-coverage-protocol.md` is the authoritative protocol — its parsing rules, evidence verification logic, finding shapes, and severity table govern PE execution.

---

## Phase 5: Finding Validation

Before writing the final report:

```
if sub-agents were used:
  for each finding:
    verify severity given full context
    dismiss false positives with brief rationale
    adjust severity if PE over/under-rated

elif primary reviewed directly:
  for each CRITICAL/HIGH finding:
    re-examine with full context
    confirm actionable and accurate
    downgrade if initial assessment was too harsh
```

**Validation checklist for any CRITICAL/HIGH:**

- [ ] Actually exploitable / broken?
- [ ] Does full context change the severity?
- [ ] Real risk, not theoretical?
- [ ] Would a senior engineer agree this blocks the PR?

Never publish a CRITICAL/HIGH without a second look.

---

## Phase 6: Output

### Step 1: Output Path

```
./docs/code-reviews/{name}-code-review.md
```

`{name}` resolution from Phase 1.

### Step 2: Write or Append

```
reviewed_sha = git rev-parse HEAD     # capture BEFORE writing

if file does NOT exist:
  write full report using assets/summary-report-template.md (relative to this skill's directory)
  populate:
    Reviewer       (`git config user.name`)
    Review Round   (1)
    Reviewed SHA   (reviewed_sha)
    PR fields      (number, URL, author — PR reviews only)

elif file exists (previous review):
  read existing file
  prior_sha = SHA recorded in latest round's "Reviewed SHA" field
  prior_verdict = top-level Verdict of latest round

  if prior_sha == reviewed_sha:
    # No new commits since last review.
    REFUSE: "No changes since round N (SHA {prior_sha}). Re-running adds no signal — abort."

  else:
    # New commits since last review.
    count `## Review Round` headings → next_round_number = N + 1
    if prior_verdict == "✅ APPROVED":
      round_header_note = "🚫 PRIOR ROUND INVALIDATED — re-reviewing post-approval changes"
    else:
      round_header_note = (none — standard remediation round)
    append new Review Round section before the `Generated with Claude Code` footer
    populate Reviewed SHA = reviewed_sha
    update top-level Verdict to reflect latest round
```

See `assets/summary-report-template.md` for exact format.

### Step 3: Commit

```bash
git add ./docs/code-reviews/{name}-code-review.md
git commit -m "docs: {name} code review"
```

Commit to the **current branch** (source branch for PR reviews, feature branch for branch reviews). Never commit review files to main.

### Step 4: PR Comment (PR Reviews Only)

```
Prompt: "Review complete and committed to {source_branch}.
         Would you like to post a summary comment on PR #{number}?"

if yes:
  post condensed summary via `gh pr comment`:
    - Verdict, finding counts by severity, link to review file
    - Key findings (CRITICAL/HIGH only, one line each)
    - Action items (Must Fix and Should Fix only)

  approve or request changes per Verdict:
    APPROVED          → gh pr review <PR> --approve
    CHANGES REQUESTED → gh pr review <PR> --request-changes
    BLOCKED           → gh pr review <PR> --request-changes
```

### Step 5: External Review Consolidation (PR Reviews Only, optional)

External reviewers (Copilot, third-party bots, human reviewers via GitHub UI)
post review comments asynchronously. Their comments are pinned to a specific
commit SHA. When HEAD advances past that SHA, some comments may already be
addressed by remediation commits.

```
Prompt: "Pull external PR review comments and consolidate against current HEAD?"

if yes:
  fetch open review threads:
    gh api graphql -f query='
      query { repository(owner, name) {
        pullRequest(number) {
          reviewThreads(first: 50) {
            nodes { id isResolved comments(first: 1) {
              nodes { databaseId author { login } path line body
                      commit { oid } }
            } }
          }
        }
      }'

  for each thread where isResolved == false:
    comment_sha = thread.comments[0].commit.oid
    if HEAD == comment_sha:
      status = "current"          # comment matches HEAD; full review needed
    else:
      # HEAD advanced — verify the comment's claim still holds
      grep the comment's claimed-missing or claimed-broken pattern against
      current HEAD's file at the comment's path.
      if pattern not found at HEAD:
        status = "stale"          # already addressed; reply with pointer to fixing commit
      else:
        status = "current"        # claim still holds at HEAD

  for each thread:
    if status == "stale":
      reply via gh api repos/{owner}/{repo}/pulls/{N}/comments/{commentId}/replies:
        "Already resolved in {sha} ({short message of fixing commit}). ✅"
      resolve thread via GraphQL resolveReviewThread mutation
    if status == "current":
      evaluate finding; if agree, fix in a remediation commit; reply with
      "Fixed in {sha}. ✅" and resolve thread; if disagree, reply with
      reasoning and leave thread open for author response.
```

External-review consolidation is optional — skip when reviewing pure branch
diffs or when no external reviews exist.

---

## Severity Definitions

| Level | Criteria | Action |
| --- | --- | --- |
| 🔴 CRITICAL | Security vulnerabilities, data loss, breaking changes, test failures | MUST FIX — blocks merge |
| 🟠 HIGH | Bugs, vet/typecheck warnings, significant design issues | MUST FIX — blocks merge |
| 🟡 MEDIUM | Code quality concerns, maintainability risks that affect product behavior | Should fix — changes requested |
| 🟢 LOW | Style, minor improvements, nice-to-haves | Awareness — does NOT block |
| ℹ️ INFO | Non-blocking observations, alternatives, future considerations | Awareness — does NOT block |

**Calibration anchor:** `MUST FIX` is reserved for actual defects, security issues, or regressions. `INFO` is the default verdict for non-blocking observations a reasonable senior engineer would consider taste-level, future-proofing, or minor preference. Working code that passes its tests and meets its acceptance criteria SHOULD reach `APPROVED` by round 2 of a typical PR.

If you find yourself elevating a style preference or theoretical edge case to `MEDIUM`, you are over-firing. Downgrade to `LOW` or `INFO`.

---

## Verdict Logic

```
if any CRITICAL with in_scope == true:    🚫 BLOCKED
elif any HIGH with in_scope == true:      🚫 BLOCKED
elif any MEDIUM with in_scope == true:    ⚠️  CHANGES REQUESTED
else (only LOW + INFO remaining):          ✅ APPROVED
```

`LOW` and `INFO` findings are awareness-only and do NOT block `✅ APPROVED`. Listing them is a service to the engineer; gating on them produces convergence spirals on minor preferences.

Engineers iterate the local review loop until the diff converges on `✅ APPROVED` with only `LOW`/`INFO` findings remaining (or no findings at all). See "Engineer-Driven Multi-Round Loop" below.

---

## Engineer-Driven Multi-Round Loop

```
ROUND_CAP = 3

each /code-reviewer invocation = one round
operator drives the loop by re-invoking after remediating

if round > ROUND_CAP:
  HALT to operator with finding counts and ask:
    "proceed (one more round, cap += 1) | abort | escalate"
  do NOT auto-continue
```

Round-to-round continuity is enforced inside each PE (PEs read the prior committed review doc on round 2+ before running their passes). See README.md for methodology rationale, convergence expectations, automation patterns, and the engineer-as-reviewer conflict mitigation.

---

## YAML Finding Structure

PE sub-agents return findings in this exact format. Primary agent parses YAML blocks and consolidates into the final report.

```yaml
expert: PE-Go|PE-Vue|PE-AWS-Infra|Primary
findings:
  - id: "CRITICAL-001"
    severity: CRITICAL
    in_scope: true
    title: "XSS via unsanitized HTML injection"
    location: "src/components/email-viewer.ts:207"
    description: |
      Email content is written to iframe using document.write()
      without any sanitization, allowing arbitrary script execution.
    recommendation: |
      Use DOMPurify to sanitize HTML before injection:
      ```typescript
      import DOMPurify from 'dompurify';
      const clean = DOMPurify.sanitize(emailContent);
      ```

  - id: "HIGH-001"
    severity: HIGH
    in_scope: true
    title: "Memory leak — event listener not removed"
    location: "src/components/email-viewer.ts:210"
    description: |
      Click event listener added to iframe but never removed
      when component is destroyed.
    recommendation: |
      Implement cleanup and remove the listener on unmount.
```
