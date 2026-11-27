# Code Review: feat-sdlc

> Round 1 ran on #23 (`feat/sdlc-github`). #24 carries the same work as one clean commit, and rounds 2 onward review #24.

**Verdict:** ⚠️ CHANGES REQUESTED

| | |
| - | - |
| **Branch** | `feat/sdlc-github` |
| **PR** | [#23](https://github.com/lafollett-labs/lafollett-labs-claude-plugins/pull/23) |
| **Author** | @clafollett |
| **Reviewer** | Claude Code (`/code-reviewer` 2.14.1) for Cali LaFollett |
| **Review Round** | 1 |
| **Reviewed SHA** | `fe37302090551522c9b840cac09b6f1c16d6814c` |
| **Title** | feat(sdlc): GitHub-native delivery loop; deprecate issue-manager |
| **Files Changed** | 222 |
| **Lines Changed** | +20596 / -7 |
| **Date** | 2026-11-27 |

---

## Summary

Adds the `sdlc` plugin (plan, implement, review, pull-request, copilot-review, deliver; nine PE agents plus plan-reviewer) ported to GitHub, and deprecates issue-manager. The scripts and suites are solid, and the human docs and manifests check out, but the review loop has state bugs at its seams: review-doc commits move HEAD under SHA-locked gates, the stash is restored onto the wrong branch, a PR branch name reaches the shell, and pe-sql-server runs reviewed SQL on a live server. Four PEs reviewed it in two shards each (pe-governance on the model-read docs, pe-devtools on the scripts and suites under a single-operator threat model), and Primary reviewed the READMEs and manifests. Two duplicate pairs and one triple were merged, and one false positive was dismissed: the Copilot request endpoint is in GitHub's OpenAPI description.

---

## Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-Governance (review skill + agents) | none | doc-only; flags, exit codes and JSON fields cited by the docs checked against 8 scripts |
| PE-Governance (other skills + shared refs) | none | doc-only; 7 scripts' interfaces checked against their docs |
| PE-DevTools (review scripts) | lint-only | 6 suites pass; 24 mutations on temp copies, 19 caught |
| PE-DevTools (other scripts) | lint-only | 10 suites + run-pe-agent-tests.sh (139) pass from /tmp; shellcheck 0.11 clean on 13 files; 4 mutations, 3 caught |
| Primary | n/a | `bash scripts/ci/run-shell-tests.sh` → 25 suites, 0 failed; CI run 45956349386 green at fe37302 |

---

## Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-Governance (review + agents) | 18 rules → 8 scripts, 3 sibling skills, 4 shared refs | doc commit → HEAD through both gates; stash across 11 exits | 7 input classes incl. fork PR, non-main default, metacharacter branches | 5 guards incl. safe-ref allowlist | 6 failure paths, fork push reproduced | 2 example blocks vs agent IDs | git push, check-ref-format, SET PARSEONLY, gh flags verified |
| PE-Governance (other skills) | 5 shared-ref call shapes, 7 script interfaces, handoff names | resume menus → implement, fix loop, status lifecycle | 8 input cases (base, story code, Gate 1 states) | 5 guards both ways | 6 calls failed | 2 plan-review fixtures | sub-issue endpoints, reviewRequests slug, gh flags |
| PE-DevTools (review scripts) | 6 scripts / 15 subcommands vs 12 refs | 5 ledger scenarios, render→parse across gates | quoted/tab paths, 9 location forms | release, list, classify guards | ENOBUFS, corrupt ledger, worktree add failure | 24 mutations, 5 survived | 6 headers, BSD sed, merge.default |
| PE-DevTools (other scripts) | 9 CLIs → 16 doc consumers | copilot re-run, create resume, atomic write | digit-led branches, CRLF, merge subjects | on_feature, ticket-history, depth guards | pr-checks exits, copilot 409/422/403 | 4 mutations, 1 survived | copilot REST, gh 2.103 --help |
| Primary | 7-row migration table, agent count, reviewer fallback, settings keys vs skills | issue-manager folder → `create` linking traced through cmdCreate | n/a — no parser, loop or limit in docs/manifests | `.gitattributes` `*-crlf.* -text` vs all CR files (3 match, 0 missed) | n/a — no calls in docs/manifests | n/a — no test in this shard | CODEOWNERS lookup order, own-PR approval, Copilot endpoint in GitHub OpenAPI |

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 8 | 0 |
| 🟡 MEDIUM | 20 | 0 |
| 🟢 LOW | 24 | 0 |
| ℹ️ INFO | 2 | 0 |

---

## In Scope Findings

-Issues in the changed code - must address based on severity-

### 🟠 HIGH-001: Gate 2 can never reach MERGEABLE with 2+ reviewers: each reviewer's review-doc commit moves HEAD

**Domains:** [Architecture] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/SKILL.md:494`
**Siblings:** `plugins/sdlc/skills/review/SKILL.md:430`, `plugins/sdlc/skills/review/references/publish.md:35`, `plugins/sdlc/skills/review/references/review-store.md:10`, `plugins/sdlc/skills/review/references/ci-gate.md:37`, `plugins/sdlc/skills/review/bin/review-file.js:549`

Gate 2 unblocks on unanimous APPROVED at the same HEAD SHA, but publish.md makes every reviewer commit and push their review doc onto the PR branch. Reviewer 1 approves at A and pushes A'; reviewer 2 approves at A'; reviewer 1 is now stale, re-runs at A'' — the loop never ends once two reviewers take part. The same push dismisses stale approvals and voids the pusher's own approval under require_last_push_approval.

**Recommendation:**
Compare reviewed code, not commit SHAs: treat two SHAs as the same target when `git diff --quiet a b -- . ':!docs/code-reviews/'` exits 0 (pull-request already uses this test). Decide how a Gate 2 round is recorded without moving the author's head (e.g. PR comment only, doc commit only on the final approving round) and state its interaction with dismiss-stale-reviews.

---

### 🟠 HIGH-002: In-place PR review restores the stash onto the PR branch and never returns to the original branch

**Domains:** [Architecture] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/references/checkout.md:56`
**Siblings:** `plugins/sdlc/skills/review/references/publish.md:194`, `plugins/sdlc/skills/review/SKILL.md:118`

In-place checkout stashes the engineer's work on their current branch, runs `gh pr checkout`, and at Phase 7 Step 6 runs `git stash pop` without recording or returning to the original branch. A Gate 2 review started from a dirty feature branch pops that work onto someone else's PR branch.

**Recommendation:**
Record `session.orig_ref = git symbolic-ref --quiet --short HEAD` before stashing; in Step 6 check out `orig_ref` (refuse on a dirty tree) before `git stash pop`.

---

### 🟠 HIGH-003: Review-doc commit takes the whole index and can commit to the base branch

**Domains:** [Architecture, Security] · **Move:** M3
**Location:** `plugins/sdlc/skills/review/references/publish.md:35`
**Siblings:** `plugins/sdlc/skills/review/references/publish.md:49`, `plugins/sdlc/skills/deliver/references/override.md:24`

Step 3 runs `git commit -m "docs: …"` with no pathspec, so a Staged Diff review commits the staged code under review inside the docs commit and pushes it (unattended under --auto). A Staged, Files or Ad-hoc review on main commits and pushes to main despite the prose rule against it.

**Recommendation:**
Commit only the review paths (`git commit -m … -- <review file> <ledger>`), and skip commit + push when the branch is the default branch, detached, or the review is Ad-hoc.

---

### 🟠 HIGH-004: PR head branch name reaches the shell unvalidated, despite the safe-ref allowlist rule

**Domains:** [Security] · **Move:** M4
**Location:** `plugins/sdlc/skills/review/references/checkout.md:56`
**Siblings:** `plugins/sdlc/skills/review/SKILL.md:499`, `plugins/sdlc/skills/review/references/checkout.md:27`, `plugins/sdlc/skills/review/references/worktree-isolation.md:49`, `plugins/sdlc/skills/review/references/worktree-isolation.md:63`, `plugins/sdlc/skills/review/references/worktree-isolation.md:66`, `plugins/sdlc/skills/review/references/worktree-isolation.md:78`, `plugins/sdlc/skills/review/references/publish.md:37`, `plugins/sdlc/skills/review/references/worktree-cleanup.md:51`, `plugins/sdlc/skills/review/references/dispatch-and-collect.md:148`

`headRefName` is interpolated into shell commands (double-quoted, single-quoted and unquoted). `git check-ref-format --branch` accepts names containing `$(…)`, backticks, quotes and `;`, so anyone who can push a branch to the base repo can run commands on the machine of whoever reviews it. Only worktree-cleanup and build-plan apply the allowlist SKILL.md:499 states.

**Recommendation:**
Right after parsing the PR, refuse a head branch that does not match `^[A-Za-z0-9._/-]+$` or starts with `-`, before any checkout, worktree or push uses it; cite that step from SKILL.md:499.

---

### 🟠 HIGH-005: pe-sql-server parse check sends reviewed SQL to a live server, and the file can switch PARSEONLY off

**Domains:** [Security] · **Move:** M7
**Location:** `plugins/sdlc/agents/pe-sql-server.md:36`
**Siblings:** `plugins/sdlc/agents/pe-sql-server.md:48`

Each changed .sql file is piped to `sqlcmd -d tempdb` on the local default instance after `SET PARSEONLY ON`. PARSEONLY neither compiles nor resolves names (the doc says it compiles), and it is applied at parse time, so a reviewed file with `SET PARSEONLY OFF` + `GO` executes its later batches on the reviewer's server.

**Recommendation:**
Never send reviewed SQL to a server: use a server-free parser (e.g. `sqlfluff parse --dialect tsql` or the project's sqlproj build), and correct the claim to "parses only, no name resolution".

---

### 🟠 HIGH-006: deliver's resume menus hand an existing branch to sdlc:implement, which always cuts a new one

**Domains:** [Architecture] · **Move:** M5
**Location:** `plugins/sdlc/skills/deliver/references/resume-menus.md:42`
**Siblings:** `plugins/sdlc/skills/deliver/references/resume-menus.md:16`, `plugins/sdlc/skills/deliver/references/resume-menus.md:22`, `plugins/sdlc/skills/deliver/references/resume-menus.md:30`, `plugins/sdlc/skills/deliver/references/resume-menus.md:38`, `plugins/sdlc/skills/deliver/SKILL.md:175`, `plugins/sdlc/skills/implement/SKILL.md:313`, `plugins/sdlc/skills/implement/SKILL.md:335`

resume-menus.md says implement owns existing-branch handling, but implement Phase 2 always checks out base, pulls, and runs `git checkout -b <branch>` with no existing-branch path or failure branch. Resume, start-over and "make more changes" therefore fail on `checkout -b`, or cut a second branch when the title changed, after moving the engineer off the feature branch.

**Recommendation:**
Give implement Phase 2 an existing-branch step before the base prompt: on a match for `<type>/<key_slug>-*`, resume checks it out and skips branch creation; start-over asks before deleting or renaming. Pass deliver's intent (resume | start-over) in, and make resume-menus.md:42 true.

---

### 🟠 HIGH-007: copilot-review request treats HTTP 409 (review already pending) as a hard error

**Domains:** [Code Quality] · **Move:** M5
**Location:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:218`
**Siblings:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:16`, `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:34`, `plugins/sdlc/skills/copilot-review/SKILL.md:32`, `plugins/sdlc/skills/copilot-review/SKILL.md:40`, `plugins/sdlc/skills/pull-request/references/copilot-review.md:15`, `plugins/sdlc/skills/copilot-review/README.md:38`, `plugins/sdlc/skills/copilot-review/bin/test/run-copilot-review-tests.sh:83`

GitHub's OpenAPI description for `POST /repos/{owner}/{repo}/pulls/{pull_number}/copilot-code-review` returns 409 when a request is already pending (failure_reason REQUEST_CONFLICT). The script skips the POST only for a submitted review, so a re-run after a wait timeout, or any repo with automatic Copilot review, exits 2 and never reaches `wait`.

**Recommendation:**
Map HTTP 409 to exit 0 with status `pending` (no quota spent), have SKILL.md treat it like `requested`, update the headers, and add a 409 stub case.

---

### 🟠 HIGH-008: gate2 reports MERGEABLE while a peer's CHANGES REQUESTED stands: round 1's verdict is read from the overwritten top line

**Domains:** [Code Quality] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/bin/review-file.js:489`
**Siblings:** `plugins/sdlc/skills/review/bin/review-file.js:321`, `plugins/sdlc/skills/review/bin/review-file.js:258`, `plugins/sdlc/skills/review/bin/review-file.js:542`, `plugins/sdlc/skills/review/bin/test/run-review-file-tests.sh:137`, `plugins/sdlc/skills/review/SKILL.md:385`

parseText takes round 1's verdict from the top `**Verdict:**` line, which appendRound rewrites to the latest verdict; the initial meta table has no Verdict row. Reproduced: a Gate 2 round 1 requesting changes, then two approvals at the same head → gate2 prints MERGEABLE.

**Recommendation:**
Add a Verdict row to the initial block's table, read round 1's verdict from it, use the top line only for single-round files, return null (not approved) for older multi-round files, and add the regression case.

---

### 🟡 MEDIUM-001: deliver, pull-request and review hard-code `main`; implement resolves the real base

**Domains:** [Architecture] · **Move:** M1
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:157`
**Siblings:** `plugins/sdlc/skills/deliver/SKILL.md:222`, `plugins/sdlc/skills/deliver/SKILL.md:224`, `plugins/sdlc/skills/pull-request/SKILL.md:121`, `plugins/sdlc/skills/pull-request/SKILL.md:154`, `plugins/sdlc/skills/pull-request/SKILL.md:201`, `plugins/sdlc/skills/pull-request/SKILL.md:210`, `plugins/sdlc/skills/review/SKILL.md:95`, `plugins/sdlc/skills/review/SKILL.md:108`, `plugins/sdlc/skills/review/SKILL.md:111`, `plugins/sdlc/skills/review/SKILL.md:128`, `plugins/sdlc/skills/review/SKILL.md:184`, `plugins/sdlc/skills/implement/SKILL.md:278`

implement takes the base from `origin/HEAD` or a ticket-named release branch. deliver counts commits against a literal `origin/main` (two-dot spike diff), pull-request --auto always targets `main`, and review's Branch Diff fetches `origin main`. On a `master`/`develop` repo these fail; on a release-branch ticket the PR targets main and the review diff carries the release delta.

**Recommendation:**
Resolve one base everywhere: PR baseRefName when a PR exists, else `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` minus `origin/`, else `main`; use three-dot diffs.

---

### 🟡 MEDIUM-002: deliver treats any ticket's feature branch as this ticket's progress

**Domains:** [Architecture] · **Move:** M4
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:153`
**Siblings:** `plugins/sdlc/skills/deliver/SKILL.md:170`, `plugins/sdlc/skills/deliver/SKILL.md:171`, `plugins/sdlc/skills/deliver/references/resume-menus.md:3`, `plugins/sdlc/skills/deliver/references/resume-menus.md:9`, `plugins/sdlc/bin/git-conventions.js:26`

`on_feature` is true for any `<type>/<key_slug>` branch; deliver never compares the parsed key with `session.key_slug`. `/sdlc:deliver #43` on `feat/42-…` opens Menu B and reviews #42's branch inside the #43 run.

**Recommendation:**
Set `session.on_feature = b.on_feature and b.key_slug == session.key_slug`; on another ticket's branch, warn and start fresh. Show the branch in the resume-menu preamble.

---

### 🟡 MEDIUM-003: deliver's End claims the PR was opened without checking

**Domains:** [Code Quality] · **Move:** M5
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:432`
**Siblings:** `plugins/sdlc/skills/deliver/SKILL.md:52`, `plugins/sdlc/skills/deliver/SKILL.md:440`, `plugins/sdlc/skills/deliver/SKILL.md:444`

Phase 7 invokes pull-request then `goto End` unconditionally; End prints "delivered" and the status move. pull-request has many gates that exit without a PR, so --auto can report a delivery that never happened.

**Recommendation:**
After pull-request returns, look up the open PR for the branch; if none, report that it stopped before the PR and exit; otherwise print End from the PR's number and URL.

---

### 🟡 MEDIUM-004: Gate 1 lock is "any round ever LOCKED": stale locks pass and OVERRIDDEN does not

**Domains:** [Architecture] · **Move:** M4
**Location:** `plugins/sdlc/skills/pull-request/SKILL.md:281`
**Siblings:** `plugins/sdlc/skills/pull-request/SKILL.md:284`, `plugins/sdlc/skills/pull-request/SKILL.md:306`, `plugins/sdlc/skills/review/references/round-state.md:133`, `plugins/sdlc/skills/review/references/round-state.md:164`, `plugins/sdlc/skills/deliver/references/override.md:22`, `plugins/sdlc/skills/deliver/SKILL.md:46`, `plugins/sdlc/skills/review/bin/convergence.js:397`

A lock at A followed by a dirty Gate 1 round at B still passes (and the drift check compares the latest round's SHA, so no drift shows); convergence.js treats that lock as broken. A Gate 1 closed by override (`OVERRIDDEN — …`) reads as unlocked, so pull-request asks for a second override and exits under --auto.

**Recommendation:**
Define the lock once as "the latest Gate 1 round's gate_status starts with LOCKED or OVERRIDDEN" (Gate 1 rounds exclude MERGEABLE / OPEN — Gate 2), expose it from `review-file.js parse`, use it in pull-request and round-state, and compare that round's SHA for drift.

---

### 🟡 MEDIUM-005: 'Confirm out of scope' skips the whole plan, including the approval gate

**Domains:** [Architecture] · **Move:** M2
**Location:** `plugins/sdlc/skills/implement/references/planning-playbook.md:129`
**Siblings:** `plugins/sdlc/skills/implement/references/planning-playbook.md:80`, `plugins/sdlc/skills/implement/references/planning-playbook.md:83`, `plugins/sdlc/skills/implement/references/planning-playbook.md:106`, `plugins/sdlc/skills/implement/SKILL.md:21`, `plugins/sdlc/skills/implement/references/incident-plan-review.md:3`

Option (c) says planning proceeds without the excluded areas, but the code does `plan_size = "XS"; goto Phase 4`, skipping Steps 2–5, the Step 6 HARD STOP approval and, under --incident, the plan-reviewer. The empty-scope branch does the same.

**Recommendation:**
In 1.5(c) record the exclusion and `goto Step 2`; in empty-scope (b) set XS and `goto Step 5` with a one-line plan. Never jump to Phase 4 from Step 1.5.

---

### 🟡 MEDIUM-006: Version-collision guard applies this repo's release rule to every plugin-marketplace repo

**Domains:** [Architecture] · **Move:** M4
**Location:** `plugins/sdlc/references/version-collision-guard.md:3`
**Siblings:** `plugins/sdlc/references/version-collision-guard.md:25`, `plugins/sdlc/references/version-collision-guard.md:34`, `plugins/sdlc/skills/pull-request/references/push-and-create.md:17`, `plugins/sdlc/skills/pull-request/SKILL.md:55`

The guard fires whenever `.claude-plugin/marketplace.json` exists and hard-stops on any version change, stating that every marketplace stamps versions after merge. Marketplaces that bump by hand are blocked; version fields outside `plugins/*/` and `plugins[].version` are never read.

**Recommendation:**
Run the guard only where versions are stamped after merge (e.g. `changelog.d/` plus a release workflow, or a setting), reword line 3 as that convention, and derive plugin.json paths from marketplace `plugins[].source`.

---

### 🟡 MEDIUM-007: Team reviewer slug gets the org prefix twice; the nudge mention reaches no one

**Domains:** [Code Quality] · **Move:** M7
**Location:** `plugins/sdlc/skills/pull-request/references/push-and-create.md:113`
**Siblings:** `plugins/sdlc/skills/pull-request/references/nudge.md:26`

`gh pr view --json reviewRequests` already returns a team's `slug` as `org/team`; both docs prefix the owner again, so post-create verification always warns and the nudge comment mentions `@org/org/team`.

**Recommendation:**
Use the slug as gh returns it for both the comparison and the mention.

---

### 🟡 MEDIUM-008: Post-lock check treats the review's own doc commit as new code; the --auto branch has no else

**Domains:** [Architecture] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/references/round-state.md:98`
**Siblings:** `plugins/sdlc/skills/pull-request/SKILL.md:284`, `plugins/sdlc/skills/review/references/publish.md:67`, `plugins/sdlc/skills/review/references/publish.md:91`, `plugins/sdlc/skills/review/references/round-state.md:130`

`head_sha != last_locked_round.sha` compares raw SHAs while Phase 7 always pushes a doc commit, so every re-run after a lock shows "HEAD advanced" and the once-per-SHA comment dedupe never matches. The `if session.auto:` branch has no else, so the prompt also runs under --auto, and two paths leave `gate1_skip_note` unbound.

**Recommendation:**
Gate the stale check on code drift (`git diff --name-only <sha>..HEAD -- . ':!docs/code-reviews/'`), restructure as if/else, and bind `gate1_skip_note` on every path.

---

### 🟡 MEDIUM-009: Several exits leave the engineer's work stashed without restoring it

**Domains:** [Code Quality] · **Move:** M5
**Location:** `plugins/sdlc/skills/review/references/checkout.md:53`
**Siblings:** `plugins/sdlc/skills/review/references/checkout.md:57`, `plugins/sdlc/skills/review/references/round-state.md:119`, `plugins/sdlc/skills/review/references/dispatch-and-collect.md:358`, `plugins/sdlc/skills/review/references/dispatch-and-collect.md:369`

The detached-HEAD check runs after the stash then stops; a failed `gh pr checkout`, the waive exit and both abort paths stop without popping the stash or saying so.

**Recommendation:**
Move the detached-HEAD check above the stash and route every exit through one `restore_stash()`.

---

### 🟡 MEDIUM-010: Phase 6 gate prompts have no match on the answer; abort skips the stash restore

**Domains:** [Code Quality] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/SKILL.md:447`
**Siblings:** `plugins/sdlc/skills/review/SKILL.md:441`, `plugins/sdlc/skills/review/SKILL.md:456`, `plugins/sdlc/skills/review/SKILL.md:462`

Both gate prompts list remediate / override / abort with no `match user_response`; abort runs teardown then stops, skipping Phase 7 Step 6, which SKILL.md says always runs.

**Recommendation:**
Add a match after each prompt; abort runs teardown then publish.md Step 6.

---

### 🟡 MEDIUM-011: Fork PR review doc is never pushed: bare `git push` from `pr-<N>`

**Domains:** [Code Quality] · **Move:** M7
**Location:** `plugins/sdlc/skills/review/references/publish.md:36`
**Siblings:** `plugins/sdlc/skills/review/references/checkout.md:29`, `plugins/sdlc/skills/review/references/worktree-isolation.md:66`

For a cross-repo PR the local branch is `pr-<N>` while its upstream is the PR head ref, so `git push` under the default push.default fails (reproduced) and every fork review lands in the push-failed branch.

**Recommendation:**
Push with an explicit refspec only when `maintainerCanModify` is true (`git push <head repo url> HEAD:refs/heads/<headRefName>`, name validated as in HIGH-004); otherwise skip the push with a notice.

---

### 🟡 MEDIUM-012: Directory-existence check records a finding nothing ever collects

**Domains:** [Code Quality] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/references/round-state.md:26`
**Siblings:** `plugins/sdlc/skills/review/references/pe-protocol.md:57`, `plugins/sdlc/skills/review/SKILL.md:296`

Phase 2 records a "Pass-2b" finding before `consolidated` exists; nothing later reads it, it lacks the schema fields findings.js requires, and "Pass 2b" already names impact propagation.

**Recommendation:**
Delete the section, or append a schema-valid finding to `consolidated` in Phase 5.5 under a distinct name.

---

### 🟡 MEDIUM-013: Rebuttal mechanism has no input format, re-reads its own output, and can spawn non-existent agents

**Domains:** [Architecture] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/references/legitimacy-gate.md:171`
**Siblings:** `plugins/sdlc/skills/review/references/legitimacy-gate.md:173`, `plugins/sdlc/skills/review/references/legitimacy-gate.md:188`, `plugins/sdlc/skills/review/SKILL.md:411`, `plugins/sdlc/skills/review/bin/review-file.js:240`

Nothing defines where an engineer writes a rebuttal; detection matches the renderer's own Rebuttals section, so old rebuttals are re-adjudicated each round; field names drift (evidence vs body); rebutting a CI or AC finding spawns `sdlc:CI` / `sdlc:Acceptance Criteria`.

**Recommendation:**
Define a distinct input section returned by `review-file.js parse`, use one field name, and let the lead re-evaluate CI/AC rebuttals itself.

---

### 🟡 MEDIUM-014: Cross-PE verification is a pair loop that cannot find what it targets, with fixed severities

**Domains:** [Architecture] · **Move:** M6
**Location:** `plugins/sdlc/skills/review/references/legitimacy-gate.md:20`
**Siblings:** `plugins/sdlc/skills/review/references/dispatch-playbook.md:123`, `plugins/sdlc/agents/pe-governance.md:59`

The finding × finding loop looks for env-var, IAM and auth drift, which are properties of code, not finding pairs, and assigns HIGH/MEDIUM directly, against the plugin's own rule that heuristics name a category, never a severity.

**Recommendation:**
Replace it with a prose heuristic: read across PE results for one contract seen from both sides; raise a finding only with source proof from both sides, rated by the severity table, through the per-finding receipt check.

---

### 🟡 MEDIUM-015: Overridden Findings block can be deleted by the next round's render

**Domains:** [Code Quality] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/references/round-state.md:165`
**Siblings:** `plugins/sdlc/skills/deliver/references/override.md:19`, `plugins/sdlc/skills/review/references/review-store.md:3`, `plugins/sdlc/skills/review/bin/review-file.js:311`

The override is appended at end of file; `beforeFooter` keeps only text before the last footer, so the next render drops the block and its reasons. Both are hand-writes against the single-writer rule.

**Recommendation:**
Add `review-file.js override` as the single writer (insert before the footer) and point round-state and deliver/override.md at it.

---

### 🟡 MEDIUM-016: pe-governance requires a CLAUDE.md Stack Map that sdlc:review never reads

**Domains:** [Code Quality] · **Move:** M1
**Location:** `plugins/sdlc/agents/pe-governance.md:44`
**Siblings:** none

The required-sections table lists "Stack Map (if sdlc:review is used)" for CLAUDE.md; sdlc:review routes with scope.js globs, so every CLAUDE.md gets a false missing-section finding.

**Recommendation:**
Drop the Stack Map clause from the CLAUDE.md row.

---

### 🟡 MEDIUM-017: ON_FEATURE_RE has no boundary after the key: `feat/2fa-login` parses as issue #2

**Domains:** [Code Quality] · **Move:** M3
**Location:** `plugins/sdlc/bin/git-conventions.js:51`
**Siblings:** `plugins/sdlc/bin/git-conventions.js:26`, `plugins/sdlc/bin/git-conventions.js:92`, `plugins/sdlc/skills/review/SKILL.md:138`, `plugins/sdlc/skills/review/references/publish.md:78`, `plugins/sdlc/bin/test/run-git-conventions-tests.sh:75`

A digit-led description with no key (`feat/2fa-login`, `feat/3d-viewer`) yields on_feature true and ticket `#2`; review binds those fields without checking `ok`, grades the PR against issue #2 and posts to it.

**Recommendation:**
Add `(?![A-Za-z0-9])` after the key group and suite cases for `feat/2fa-login` and `feat/42abc`.

---

### 🟡 MEDIUM-018: validate-story.js rejects CRLF stories, so `validate --issue N` fails on web-edited bodies

**Domains:** [Code Quality] · **Move:** M3
**Location:** `plugins/sdlc/skills/plan/bin/validate-story.js:53`
**Siblings:** `plugins/sdlc/skills/plan/SKILL.md:155`, `plugins/sdlc/skills/plan/bin/publish-body.js:84`, `plugins/sdlc/skills/pull-request/bin/extract-test-plan.js:74`

The user-story regex needs bare `\n`; issue bodies edited in the GitHub UI come back CRLF, so a valid story fails. Every sibling CLI already strips CR.

**Recommendation:**
Normalise line endings on read and add a CRLF fixture.

---

### 🟡 MEDIUM-019: Copilot coverage fails open: an unparsed overview reports full coverage

**Domains:** [Code Quality] · **Move:** M5
**Location:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:187`
**Siblings:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:44`, `plugins/sdlc/skills/copilot-review/SKILL.md:94`, `plugins/sdlc/skills/copilot-review/SKILL.md:111`, `plugins/sdlc/skills/pull-request/references/copilot-review.md:21`

When the unverified coverage regex does not match, `partial` is false and the run reports coverage "full", so the skipped-files warning never prints.

**Recommendation:**
Return `partial: null` on no match, report coverage "unknown", and treat a "Files not reviewed" heading as partial.

---

### 🟡 MEDIUM-020: Ticket-history guard only detects Jira-style keys; GitHub `#N` history passes

**Domains:** [Code Quality] · **Move:** M4
**Location:** `plugins/sdlc/bin/test/run-skill-structure-tests.sh:70`
**Siblings:** `plugins/sdlc/bin/test/run-pe-agent-tests.sh:49`, `plugins/sdlc/bin/test/run-pe-agent-tests.sh:55`, `plugins/sdlc/bin/test/run-skill-structure-tests.sh:22`

Seeding "Since #20 merged … (regression from #17)" leaves the check green, and `SHA-256` false-fires. The sibling in run-pe-agent-tests.sh already matches `#[0-9]{3,}` with placeholders.

**Recommendation:**
Use the sibling's alternation and placeholders, exempt `SHA-n`/`ISO-n`, and add a `#517` mutation case.

---

### 🟢 LOW-001: Retry and stale-file branches never run because run_gi stops on exit 1

**Domains:** [Code Quality] · **Move:** M5
**Location:** `plugins/sdlc/skills/plan/references/create.md:33`
**Siblings:** `plugins/sdlc/skills/plan/references/import.md:13`, `plugins/sdlc/skills/plan/SKILL.md:87`

gh-issues.js exits 1 when errors exist, and run_gi stops before the caller sees the output, so create's one retry and import's stale-file prompt are dead.

**Recommendation:**
Return `(out, code)` from run_gi on exit 1 and let each caller decide, or delete both branches.

---

### 🟢 LOW-002: Fix-loop commit never stages and has no failure branch

**Domains:** [Code Quality] · **Move:** M5
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:357`
**Siblings:** none

`git commit -m …` runs with nothing staged; the loop then re-reviews the same SHA.

**Recommendation:**
Stage the touched paths, and on an empty index warn and flip to interactive.

---

### 🟢 LOW-003: status:done is never set, and skip mode leaves two status labels

**Domains:** [Code Quality] · **Move:** M1
**Location:** `plugins/sdlc/references/issue-status-labels.md:10`
**Siblings:** `plugins/sdlc/references/issue-status-labels.md:3`, `plugins/sdlc/skills/pull-request/references/push-and-create.md:43`

No skill sets `done`; the printed skip-mode command adds `status:in-review` without removing `status:in-progress`.

**Recommendation:**
Describe `done` as set by hand or automation (closed counts as done) and add `--remove-label status:in-progress` to the printed command.

---

### 🟢 LOW-004: Auto banner reads only the repo settings file

**Domains:** [Code Quality] · **Move:** M1
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:199`
**Siblings:** `plugins/sdlc/references/settings.md:3`

Phase 0.5 checks `.claude/sdlc.json` directly, so Slack enabled only in `~/.claude/sdlc.json` is missing from the --auto consent banner.

**Recommendation:**
Use `load_settings()` and `session.settings.slack.enabled`.

---

### 🟢 LOW-005: Pseudocode costume: `record … as KNOWN_ASSUMPTION` / `STATED_CONSTRAINT`

**Domains:** [Code Quality] · **Move:** none
**Location:** `plugins/sdlc/skills/implement/references/planning-playbook.md:81`
**Siblings:** `plugins/sdlc/skills/implement/references/planning-playbook.md:122`, `plugins/sdlc/skills/implement/references/planning-playbook.md:126`

Neither token is read anywhere; Step 5 uses prose labels.

**Recommendation:**
Replace each with the plain sentence Step 5 consumes.

---

### 🟢 LOW-006: End summaries read variables some paths never set

**Domains:** [Code Quality] · **Move:** M3
**Location:** `plugins/sdlc/skills/pull-request/SKILL.md:358`
**Siblings:** `plugins/sdlc/skills/deliver/SKILL.md:442`

`session.status_move` is unset when Phase 8 exits early; deliver's End prints `(round {n})` with `n` unbound.

**Recommendation:**
Initialise `status_move` at Phase 8 entry and bind `n` from the parsed latest round.

---

### 🟢 LOW-007: finding-schema.md lists lowercase expert IDs; agents declare `PE-*`

**Domains:** [Code Quality] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/references/finding-schema.md:10`
**Siblings:** `plugins/sdlc/skills/review/references/pe-protocol.md:227`

The documents disagree; findings.js overwrites the field anyway.

**Recommendation:**
Document `expert` as the agent's declared ID, replaced by findings.js.

---

### 🟢 LOW-008: AGENTS.md and Copilot instruction files are not routed to pe-governance

**Domains:** [Code Quality] · **Move:** M1
**Location:** `plugins/sdlc/agents/pe-governance.md:19`
**Siblings:** `plugins/sdlc/skills/review/SKILL.md:196`, `plugins/sdlc/skills/review/bin/scope.js:96`, `plugins/sdlc/agents/pe-general-purpose.md:28`

`**/AGENTS.md`, `.github/copilot-instructions.md` and `.github/instructions/*.instructions.md` fall to pe-general-purpose as human docs.

**Recommendation:**
Add them to pe-governance's patterns and scope.js, with a routing fixture.

---

### 🟢 LOW-009: Recommendation hard-check may drop findings and uses a different regex from findings.js

**Domains:** [Code Quality] · **Move:** M4
**Location:** `plugins/sdlc/skills/review/references/legitimacy-gate.md:161`
**Siblings:** `plugins/sdlc/skills/review/bin/findings.js:32`, `plugins/sdlc/skills/review/references/legitimacy-gate.md:118`, `plugins/sdlc/skills/review/references/finding-schema.md:52`

"OR drop" contradicts "never drop the concern"; the regex adds terms findings.js lacks.

**Recommendation:**
Demote instead of dropping, and state the regexes as one rule.

---

### 🟢 LOW-010: Silent failures: gh pr comment and Gate 2 ledger-record errors

**Domains:** [Code Quality] · **Move:** M5
**Location:** `plugins/sdlc/skills/review/references/publish.md:130`
**Siblings:** `plugins/sdlc/skills/review/SKILL.md:384`, `plugins/sdlc/skills/review/references/publish.md:122`

A failed `gh pr comment` still links the summary; Gate 2 never renders a convergence error; the temp dir is never removed.

**Recommendation:**
Warn on comment failure and skip the dependent verdict text, render the ledger error, remove the temp dir.

---

### 🟢 LOW-011: Bug-shape status marks have no consumer

**Domains:** [Code Quality] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/references/legitimacy-gate.md:51`
**Siblings:** none

RESOLVED / PARTIALLY_RESOLVED marks are never read, and extra sites are written twice.

**Recommendation:**
Delete the marking block and the duplicate `description +=`.

---

### 🟢 LOW-012: Reference-depth guards match only lowercase read/load

**Domains:** [Code Quality] · **Move:** M4
**Location:** `plugins/sdlc/bin/test/run-skill-structure-tests.sh:59`
**Siblings:** `plugins/sdlc/bin/test/run-pe-agent-tests.sh:274`

"Read `…/references/x.md`" and "Load …" pass both guards.

**Recommendation:**
Match case-insensitively with `(read|load)s?` and add a capitalised mutation case.

---

### 🟢 LOW-013: UNVERIFIED — Copilot's REST review login

**Domains:** [Code Quality] · **Move:** M7
**Location:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:43`
**Siblings:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:41`

The login regex is unconfirmed against a live review; a different bot login breaks wait, already_reviewed and pushed. (The quota literal NO_QUOTA_REMAINING is confirmed by GitHub's OpenAPI description and already matched.)

**Recommendation:**
Also accept `user.type == "Bot"` with a login starting `copilot`, and confirm on a live PR.

---

### 🟢 LOW-014: PR commit check flags merge and revert subjects

**Domains:** [Code Quality] · **Move:** M3
**Location:** `plugins/sdlc/skills/pull-request/SKILL.md:242`
**Siblings:** `plugins/sdlc/bin/git-conventions.js:137`

Merging main into the branch produces a Conventional Commits warning and prompt on every run.

**Recommendation:**
Pass `--no-merges` to the log.

---

### 🟢 LOW-015: Free-text `key` reads UTF-8 / SHA-256 / ISO-8601 as story keys

**Domains:** [Code Quality] · **Move:** M3
**Location:** `plugins/sdlc/bin/git-conventions.js:58`
**Siblings:** `plugins/sdlc/bin/git-conventions.js:30`, `plugins/sdlc/bin/git-conventions.js:165`

No caller uses free-text mode yet, but its leftmost match beats `#42`.

**Recommendation:**
Prefer a `#N` match and exclude standard terms, or drop the mode.

---

### 🟢 LOW-016: `update --file F --key N` silently overrides the tracked number

**Domains:** [Code Quality] · **Move:** M4
**Location:** `plugins/sdlc/skills/plan/bin/gh-issues.js:503`
**Siblings:** none

With F tracked as #M, `--key N` overwrites #N from F with no warning.

**Recommendation:**
Refuse when the key and the tracked number differ.

---

### 🟢 LOW-017: validate suite cannot fail when the user-story format check is removed

**Domains:** [Code Quality] · **Move:** M6
**Location:** `plugins/sdlc/skills/plan/bin/test/run-validate-tests.sh:49`
**Siblings:** `plugins/sdlc/skills/plan/bin/validate-story.js:53`

The only failing fixture lacks the whole section.

**Recommendation:**
Add a malformed-story fixture and a CRLF fixture.

---

### 🟢 LOW-018: Header drift in validate-story.js and copilot-review.js

**Domains:** [Code Quality] · **Move:** M7
**Location:** `plugins/sdlc/skills/plan/bin/validate-story.js:2`
**Siblings:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:16`

validate-story.js documents no exit codes; the request header omits `review_id`.

**Recommendation:**
Document exit codes and add `review_id`.

---

### 🟢 LOW-019: build-plan release test cannot catch a location-guard regression

**Domains:** [Code Quality] · **Move:** M6
**Location:** `plugins/sdlc/skills/review/bin/test/run-build-plan-tests.sh:526`
**Siblings:** `plugins/sdlc/skills/review/bin/build-plan.js:521`

Both refusal cases fail the prefix check, so dropping the location check passes 101/101.

**Recommendation:**
Add a correctly named directory outside the temp base and assert refusal.

---

### 🟢 LOW-020: No worktree-cleanup case depends on the merge-tree content check

**Domains:** [Code Quality] · **Move:** M6
**Location:** `plugins/sdlc/skills/review/bin/test/run-worktree-cleanup-tests.sh:208`
**Siblings:** `plugins/sdlc/skills/review/bin/worktree-cleanup.js:341`, `plugins/sdlc/skills/review/bin/worktree-cleanup.js:349`

Disabling the content check passes 98/98.

**Recommendation:**
Assert reason `content matches` and add a squashed-commits case.

---

### 🟢 LOW-021: appendRound's fail-closed check has no test

**Domains:** [Code Quality] · **Move:** M6
**Location:** `plugins/sdlc/skills/review/bin/review-file.js:325`
**Siblings:** `plugins/sdlc/skills/review/references/review-store.md:15`

Disabling the throw passes 78/78.

**Recommendation:**
Add a case with an unfenced round heading in a description; assert exit 2 and an unchanged file.

---

### 🟢 LOW-022: review-file verdict skips the category floor that convergence applies

**Domains:** [Code Quality] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/bin/review-file.js:98`
**Siblings:** `plugins/sdlc/skills/review/bin/convergence.js:176`, `plugins/sdlc/skills/review/bin/findings.js:30`, `plugins/sdlc/skills/review/references/legitimacy-gate.md:151`

A LOW auth finding is APPROVED by review-file and floored to MEDIUM by convergence.

**Recommendation:**
Apply the floor once in findings.js.

---

### 🟢 LOW-023: Round-heading note says 'a 2nd clean round locks Gate 1' on Gate 2 rounds

**Domains:** [Code Quality] · **Move:** M7
**Location:** `plugins/sdlc/skills/review/bin/review-file.js:319`
**Siblings:** `plugins/sdlc/skills/review/bin/test/fixtures/review-file/expected-gate2.md:228`

The note ignores the gate; the golden file bakes the wrong text in.

**Recommendation:**
Emit the notes only for Gate 1 rounds whose prior round is not locked.

---

### 🟢 LOW-024: scope and build-plan suites inherit the operator's global git config

**Domains:** [Code Quality] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/bin/test/run-scope-tests.sh:39`
**Siblings:** `plugins/sdlc/skills/review/bin/test/run-build-plan-tests.sh:64`

A global blocking pre-commit hook fails 32 and 49 checks; worktree-cleanup's suite is hermetic.

**Recommendation:**
Copy worktree-cleanup's hermetic git preamble into both suites.

---

### ℹ️ INFO-001: The same gate-rendering block is copied into three skills that load together

**Domains:** [Code Quality] · **Move:** M1
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:71`
**Siblings:** `plugins/sdlc/skills/implement/SKILL.md:61`, `plugins/sdlc/skills/pull-request/SKILL.md:71`

About 15 lines repeated in deliver, implement and pull-request.

**Recommendation:**
Optionally move it to a shared reference.

---

### ℹ️ INFO-002: `Closes #N` closes the issue only on merge into the default branch

**Domains:** [Code Quality] · **Move:** M7
**Location:** `plugins/sdlc/assets/pr-description-template.md:45`
**Siblings:** none

A PR into a release base leaves the issue open.

**Recommendation:**
Add the condition to the sentence.

---

## Out of Scope

-Pre-existing issues not introduced by this PR - log to backlog, don't block-

None: every file is new in this PR.

---

## Action Items

### Must Fix (blocks merge)

- [ ] HIGH-001: fix `plugins/sdlc/skills/review/SKILL.md:494` + 5 siblings
- [ ] HIGH-002: fix `plugins/sdlc/skills/review/references/checkout.md:56` + 2 siblings
- [ ] HIGH-003: fix `plugins/sdlc/skills/review/references/publish.md:35` + 2 siblings
- [ ] HIGH-004: fix `plugins/sdlc/skills/review/references/checkout.md:56` + 9 siblings
- [ ] HIGH-005: fix `plugins/sdlc/agents/pe-sql-server.md:36` + 1 siblings
- [ ] HIGH-006: fix `plugins/sdlc/skills/deliver/references/resume-menus.md:42` + 7 siblings
- [ ] HIGH-007: fix `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:218` + 7 siblings
- [ ] HIGH-008: fix `plugins/sdlc/skills/review/bin/review-file.js:489` + 5 siblings

### Required

- [ ] MEDIUM-001: fix `plugins/sdlc/skills/deliver/SKILL.md:157` + 12 siblings
- [ ] MEDIUM-002: fix `plugins/sdlc/skills/deliver/SKILL.md:153` + 5 siblings
- [ ] MEDIUM-003: fix `plugins/sdlc/skills/deliver/SKILL.md:432` + 3 siblings
- [ ] MEDIUM-004: fix `plugins/sdlc/skills/pull-request/SKILL.md:281` + 7 siblings
- [ ] MEDIUM-005: fix `plugins/sdlc/skills/implement/references/planning-playbook.md:129` + 5 siblings
- [ ] MEDIUM-006: fix `plugins/sdlc/references/version-collision-guard.md:3` + 4 siblings
- [ ] MEDIUM-007: fix `plugins/sdlc/skills/pull-request/references/push-and-create.md:113` + 1 siblings
- [ ] MEDIUM-008: fix `plugins/sdlc/skills/review/references/round-state.md:98` + 4 siblings
- [ ] MEDIUM-009: fix `plugins/sdlc/skills/review/references/checkout.md:53` + 4 siblings
- [ ] MEDIUM-010: fix `plugins/sdlc/skills/review/SKILL.md:447` + 3 siblings
- [ ] MEDIUM-011: fix `plugins/sdlc/skills/review/references/publish.md:36` + 2 siblings
- [ ] MEDIUM-012: fix `plugins/sdlc/skills/review/references/round-state.md:26` + 2 siblings
- [ ] MEDIUM-013: fix `plugins/sdlc/skills/review/references/legitimacy-gate.md:171` + 4 siblings
- [ ] MEDIUM-014: fix `plugins/sdlc/skills/review/references/legitimacy-gate.md:20` + 2 siblings
- [ ] MEDIUM-015: fix `plugins/sdlc/skills/review/references/round-state.md:165` + 3 siblings
- [ ] MEDIUM-016: fix `plugins/sdlc/agents/pe-governance.md:44` + 0 siblings
- [ ] MEDIUM-017: fix `plugins/sdlc/bin/git-conventions.js:51` + 5 siblings
- [ ] MEDIUM-018: fix `plugins/sdlc/skills/plan/bin/validate-story.js:53` + 3 siblings
- [ ] MEDIUM-019: fix `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:187` + 4 siblings
- [ ] MEDIUM-020: fix `plugins/sdlc/bin/test/run-skill-structure-tests.sh:70` + 3 siblings

### Optional

- [ ] LOW-001: fix `plugins/sdlc/skills/plan/references/create.md:33` + 2 siblings
- [ ] LOW-002: fix `plugins/sdlc/skills/deliver/SKILL.md:357` + 0 siblings
- [ ] LOW-003: fix `plugins/sdlc/references/issue-status-labels.md:10` + 2 siblings
- [ ] LOW-004: fix `plugins/sdlc/skills/deliver/SKILL.md:199` + 1 siblings
- [ ] LOW-005: fix `plugins/sdlc/skills/implement/references/planning-playbook.md:81` + 2 siblings
- [ ] LOW-006: fix `plugins/sdlc/skills/pull-request/SKILL.md:358` + 1 siblings
- [ ] LOW-007: fix `plugins/sdlc/skills/review/references/finding-schema.md:10` + 1 siblings
- [ ] LOW-008: fix `plugins/sdlc/agents/pe-governance.md:19` + 3 siblings
- [ ] LOW-009: fix `plugins/sdlc/skills/review/references/legitimacy-gate.md:161` + 3 siblings
- [ ] LOW-010: fix `plugins/sdlc/skills/review/references/publish.md:130` + 2 siblings
- [ ] LOW-011: fix `plugins/sdlc/skills/review/references/legitimacy-gate.md:51` + 0 siblings
- [ ] LOW-012: fix `plugins/sdlc/bin/test/run-skill-structure-tests.sh:59` + 1 siblings
- [ ] LOW-013: fix `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:43` + 1 siblings
- [ ] LOW-014: fix `plugins/sdlc/skills/pull-request/SKILL.md:242` + 1 siblings
- [ ] LOW-015: fix `plugins/sdlc/bin/git-conventions.js:58` + 2 siblings
- [ ] LOW-016: fix `plugins/sdlc/skills/plan/bin/gh-issues.js:503` + 0 siblings
- [ ] LOW-017: fix `plugins/sdlc/skills/plan/bin/test/run-validate-tests.sh:49` + 1 siblings
- [ ] LOW-018: fix `plugins/sdlc/skills/plan/bin/validate-story.js:2` + 1 siblings
- [ ] LOW-019: fix `plugins/sdlc/skills/review/bin/test/run-build-plan-tests.sh:526` + 1 siblings
- [ ] LOW-020: fix `plugins/sdlc/skills/review/bin/test/run-worktree-cleanup-tests.sh:208` + 2 siblings
- [ ] LOW-021: fix `plugins/sdlc/skills/review/bin/review-file.js:325` + 1 siblings
- [ ] LOW-022: fix `plugins/sdlc/skills/review/bin/review-file.js:98` + 3 siblings
- [ ] LOW-023: fix `plugins/sdlc/skills/review/bin/review-file.js:319` + 1 siblings
- [ ] LOW-024: fix `plugins/sdlc/skills/review/bin/test/run-scope-tests.sh:39` + 1 siblings
- [ ] INFO-001: fix `plugins/sdlc/skills/deliver/SKILL.md:71` + 2 siblings
- [ ] INFO-002: fix `plugins/sdlc/assets/pr-description-template.md:45` + 0 siblings

---

## Files Reviewed

| File | Findings |
| - | - |
| `plugins/sdlc/agents/pe-governance.md` | 2 |
| `plugins/sdlc/agents/pe-sql-server.md` | 1 |
| `plugins/sdlc/assets/pr-description-template.md` | 1 |
| `plugins/sdlc/bin/git-conventions.js` | 2 |
| `plugins/sdlc/bin/test/run-skill-structure-tests.sh` | 2 |
| `plugins/sdlc/references/issue-status-labels.md` | 1 |
| `plugins/sdlc/references/version-collision-guard.md` | 1 |
| `plugins/sdlc/skills/copilot-review/bin/copilot-review.js` | 3 |
| `plugins/sdlc/skills/deliver/SKILL.md` | 6 |
| `plugins/sdlc/skills/deliver/references/resume-menus.md` | 1 |
| `plugins/sdlc/skills/implement/references/planning-playbook.md` | 2 |
| `plugins/sdlc/skills/plan/bin/gh-issues.js` | 1 |
| `plugins/sdlc/skills/plan/bin/test/run-validate-tests.sh` | 1 |
| `plugins/sdlc/skills/plan/bin/validate-story.js` | 2 |
| `plugins/sdlc/skills/plan/references/create.md` | 1 |
| `plugins/sdlc/skills/pull-request/SKILL.md` | 3 |
| `plugins/sdlc/skills/pull-request/references/push-and-create.md` | 1 |
| `plugins/sdlc/skills/review/SKILL.md` | 2 |
| `plugins/sdlc/skills/review/bin/review-file.js` | 4 |
| `plugins/sdlc/skills/review/bin/test/run-build-plan-tests.sh` | 1 |
| `plugins/sdlc/skills/review/bin/test/run-scope-tests.sh` | 1 |
| `plugins/sdlc/skills/review/bin/test/run-worktree-cleanup-tests.sh` | 1 |
| `plugins/sdlc/skills/review/references/checkout.md` | 3 |
| `plugins/sdlc/skills/review/references/finding-schema.md` | 1 |
| `plugins/sdlc/skills/review/references/legitimacy-gate.md` | 4 |
| `plugins/sdlc/skills/review/references/publish.md` | 3 |
| `plugins/sdlc/skills/review/references/round-state.md` | 3 |
| all other files in the diff (READMEs, manifests, fixtures, remaining scripts and suites) | 0 |

---

## Merge Eligibility

**Locked to SHA:** `fe37302090551522c9b840cac09b6f1c16d6814c`
**Status:** 🚫 Not mergeable — 8 HIGH and 20 MEDIUM findings open. Any commit after this SHA requires re-review (`/code-reviewer` again before merge).

---

## Review Round 2

**Verdict:** 🚫 BLOCKED

| | |
| - | - |
| **Reviewer** | @Cali LaFollett |
| **PR** | [#24](https://github.com/lafollett-labs/lafollett-labs-claude-plugins/pull/24) |
| **Reviewed SHA** | `217a9b659ecb292dcdabf7b8bf3872075b04f5ed` |
| **Date** | 2026-11-27 |
| **Fix cascade** | 21 / 27 in-scope findings introduced by a prior fix |
| **Ripple receipts** | 64 spot-checked |

### Summary

Every round-1 finding the PEs re-checked is fixed at this SHA: 20 in the other skills, the review scripts' 12, and shard B's 9 by suite and mutation. Severity is falling, but the fixes opened three gating gaps. The resume path added for HIGH-006 puts origin branch names into shell commands without the safe-ref allowlist (the HIGH-004 class, reproduced). deliver reads a stopped `--resume` run as progress and goes on to review and the PR. And a Gate 2 prior review now lives outside the PEs' search boundary. The LOWs are edge refinements, most in themes round 1 already raised. One duplicate pair was merged (deliver's base never reads the PR), Primary added one LOW, and nothing was dismissed.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-Governance (review skill + agents) | none | doc-only; run-pe-agent-tests.sh 141/0 and run-skill-structure-tests.sh 28/0 at HEAD; same_code and pathspec commit run on temp repos |
| PE-Governance (other skills + shared refs) | none | doc-only; run-skill-structure-tests.sh 28/0; resume-branch injection reproduced in a temp repo |
| PE-DevTools (review scripts) | lint-only | 6 suites from / → 592 checks, 0 failed; shellcheck clean; 3 suites re-run under a hostile global git config; 49 mutations, 43 caught |
| PE-DevTools (other scripts) | lint-only | 11 suites from / pass; shellcheck clean on 13 files; check-pr.sh clean; 50 mutations, 43 caught |
| Primary | n/a | `bash scripts/ci/run-shell-tests.sh` → 25 suites, 0 failed; CI run 45965604186 green at 217a9b6 |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-Governance (review + agents) | 14 receipts, 4 unreceipted rules, 1 contract conflict | stash over 13 exits, Gate 2 local store, ledger gap vs Files rounds | 9 input classes | 4 guards both ways | 6 failure paths incl. sqlfluff absent | 3 example blocks + baseline assertion | pathspec forms, check-ref-format, self-approval, sqlfluff output |
| PE-Governance (other skills) | 31 receipts, 10 greps | deliver → implement → deliver over 6 stop paths | gate1 states, PR absent/new/pre-existing, marketplace sources | on_feature vs metacharacter branch, open-PR guard | checkout, override, gh pr view, base exit 2 | n/a — no test in this shard | team slug, closing keywords, marketplace pluginRoot, for-each-ref |
| PE-DevTools (review scripts) | 11 receipts, review-file.js CLI → 14 doc call sites | override → next render, gate2 across doc-only commits | gate2 review states, override inputs, --local paths, nested routing | 10 guards both ways | gh failure modes → exit 2 | 49 mutations, 6 survived | GitHub review states, git diff --quiet, Copilot instruction dirs, os.homedir |
| PE-DevTools (other scripts) | 12 receipts, 1 drift | sdlc-base config, Copilot 409 → wait, update --key | base, ON_FEATURE, free-text key, revert subjects, CRLF | 8 guards both ways | base --pr failures, Copilot POST codes | 50 mutations, 7 survived | Copilot REST, overview changelog, git branch -m config |
| Primary | 6 README/changelog restatements vs scripts (Gate 2 notes path, base row, override, resume flags) | Gate 2 CI read across a fresh push | n/a — no parser or loop in this shard | review-file suite HOME isolation | n/a — no calls in docs/manifests | n/a — no test in this shard | GitHub check registration delay (seen on #23) |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 1 | 0 |
| 🟡 MEDIUM | 2 | 0 |
| 🟢 LOW | 22 | 0 |
| ℹ️ INFO | 2 | 0 |

### In Scope Findings

#### 🟠 HIGH-001: Existing-branch resume puts origin branch names into shell commands without the safe-ref allowlist

**Domains:** [Governance] · **Move:** M4
**Location:** `plugins/sdlc/skills/implement/references/existing-branch.md:32`
**Introduced by:** HIGH-006
**Siblings:** `plugins/sdlc/skills/implement/SKILL.md:269`, `plugins/sdlc/skills/implement/references/existing-branch.md:32`, `plugins/sdlc/skills/implement/references/existing-branch.md:33`, `plugins/sdlc/skills/implement/references/existing-branch.md:37`, `plugins/sdlc/skills/implement/references/existing-branch.md:45`, `plugins/sdlc/skills/implement/references/existing-branch.md:51`, `plugins/sdlc/skills/implement/references/existing-branch.md:52`, `plugins/sdlc/skills/implement/references/spike.md:20`, `plugins/sdlc/skills/implement/references/spike.md:23`, `plugins/sdlc/skills/review/SKILL.md:88`, `plugins/sdlc/skills/review/SKILL.md:496`, `plugins/sdlc/skills/review/references/checkout.md:27`

Phase 2 gathers `found` from `refs/remotes/origin/*/{key_slug}-*` when no local branch matches. It keeps a
name only if git-conventions `branch` reports on_feature, and on_feature checks just the `<type>/<key>` prefix.
existing-branch.md then puts the name inside single quotes in `git checkout --track 'origin/{b}'`,
`git checkout '{b}'`, `base --branch '{b}'`, `git show-ref … '{b}'` and `git branch -m/-D '{b}'`, and spike.md
does the same with `retype --name` and `branch -m`.
Reproduced in a mktemp repo: `feat/42-x';touch${IFS}pwned;'` passes `git check-ref-format --branch`, the
on_feature filter keeps it (key_slug 42), and the `git checkout` command built from it created the file.
Anyone who can push a branch to origin can run commands on the machine of whoever implements that
issue. Under --auto (directly, or through deliver's fresh path) the resume is picked automatically, so this
runs with nobody watching. review applies the allowlist (SKILL.md:88, checkout.md:27); implement does not.
This is the HIGH-004 class, brought in by the HIGH-006 fix.

**Recommendation:**
Apply the allowlist in the SKILL.md:269 filter, before existing-branch.md sees any name:
```
keep each b in found that matches ^[A-Za-z0-9._/-]+$, does not start with "-",
  and whose git-conventions.js branch reports on_feature and key_slug == session.key_slug
⚠️ Warning for each dropped name: "{ticket_key}: ignoring branch with unsafe characters"
```
Then quote with the options terminator where git accepts it (`git checkout '{b}' --`).

#### 🟡 MEDIUM-001: Gate 2 PRIOR REVIEW now lives outside SEARCH_ROOTS, which TRIVIAL/STANDARD PEs are forbidden to Read

**Domains:** [Governance] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/references/round-state.md:36`
**Introduced by:** HIGH-001
**Siblings:** `plugins/sdlc/skills/review/references/dispatch-and-collect.md:224`, `plugins/sdlc/skills/review/references/dispatch-and-collect.md:205`, `plugins/sdlc/skills/review/references/dispatch-playbook.md:179`, `plugins/sdlc/skills/review/references/pe-protocol.md:30`, `plugins/sdlc/skills/review/references/pe-protocol.md:41`, `plugins/sdlc/skills/review/references/review-store.md:9`

HIGH-001's fix moves a Gate 2 reviewer's rounds to ~/.claude/sdlc/reviews/<owner>/<repo>/<name>-code-review.md, and
dispatch-and-collect.md:224 passes that path as PRIOR REVIEW from round 2 on. session.search_roots is [review_root]
plus declared siblings (user_home is explicitly rejected), so the file is never inside SEARCH_ROOTS. Below DEEP, the
Search Boundary (dispatch-playbook.md:179) and pe-protocol.md:30 make SEARCH_ROOTS "a hard boundary" for every Read.
A PE obeying the contract cannot read the prior review that pe-protocol.md:41 (round continuity) and the
round-over-round discipline depend on, so a Gate 2 round 2+ at TRIVIAL/STANDARD either violates the hard rule or
reviews blind to round 1 (re-raised resolved findings, new lens-angle churn, titles not reused verbatim). Gate 1 is
unaffected (its doc is under review_root).

**Recommendation:**
Name the dispatch inputs as readable wherever they live — append to the Search Boundary contract in dispatch-playbook.md:
"The PRIOR REVIEW and PRIOR LEDGER files named in the dispatch are inputs: read them wherever they are; the boundary applies to searches and to every other read."
and mirror it in pe-protocol.md § Inputs. (Alternative: for Gate 2 append dirname(review_file) to session.search_roots.)

#### 🟡 MEDIUM-002: deliver reads a stopped --resume run of sdlc:implement as progress and continues to review and the PR

**Domains:** [Governance] · **Move:** M2
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:241`
**Introduced by:** HIGH-006
**Siblings:** `plugins/sdlc/skills/deliver/SKILL.md:241`, `plugins/sdlc/skills/deliver/SKILL.md:247`, `plugins/sdlc/skills/deliver/references/resume-menus.md:24`, `plugins/sdlc/skills/deliver/references/resume-menus.md:33`, `plugins/sdlc/skills/deliver/references/resume-menus.md:41`

After Phase 1, deliver detects that implement stopped in only two cases: a start-over
(`HEAD == head_before`) or zero commits ahead. A [resume] option from Menu B, C or D passes `--resume` on a
branch that already has commits. If implement then stops before committing, for example at the dirty-tree gate
("Commit first — exit"), a multi-branch abort, Step 1.5 (c), or a plan the engineer never approves,
commits_ahead is still above 0 and deliver goes to Phase 2.
Under --auto, deliver's session.auto is untouched (implement's HALT flips only its own flag). The
review → auto-remediate → Phase 6.5 auto-approve → PR chain therefore runs unattended after the engineer
declined at implement's one retained human stop. Before the fix this path could not be reached:
`checkout -b` failed after implement had moved to base, so commits_ahead was 0.

**Recommendation:**
Use the start-over check for every mode deliver passes to implement:
```
if session.implement_mode and `git rev-parse HEAD` == head_before:
  ✅ Done — sdlc:implement added no commits on {session.branch}; re-run sdlc:deliver {ticket_key} when ready
  if session.auto_decisions: print "Auto log:\n" + …
  exit
```
Keep the start-over-specific message inside that branch.

#### 🟢 LOW-001: Step 3.6 tests prior_same, which is unbound when Step 3.5 skips at its first guard

**Domains:** [Governance] · **Move:** M3
**Location:** `plugins/sdlc/skills/review/references/publish.md:91`
**Introduced by:** MEDIUM-008
**Siblings:** `plugins/sdlc/skills/review/references/publish.md:67`

The fix replaced Step 3.6's own SHA-prefix dedupe with a reference to Step 3.5's prior_same, but prior_same is
bound at line 67, after Step 3.5's first skip (line 63: no ticket, empty ac_results, or not committed). The
"Bound before either step's guards" comment covers only session.rounds_now. A Bug issue with no Acceptance
Criteria / Expected Behavior section (ac_results = []) skips Step 3.5 at line 63, then Step 3.6 reaches
`if prior_same is non-empty` with nothing bound; the model improvises the dedupe. post_comment replaces the
bug-rca section in place, so the cost is a redundant edit plus a preview prompt every round on unchanged code.

**Recommendation:**
Bind it beside rounds_now, before either guard:
```
session.rounds_now = (...).rounds if session.review_committed else []
prior_same = [r for r in session.rounds_now[:-1] if same_code(r.reviewed_sha, session.head_sha)]
```
and delete the line-67 assignment.

#### 🟢 LOW-002: pe-sql-server parse loop cannot tell a missing sqlfluff from a clean parse

**Domains:** [Governance] · **Move:** M5
**Location:** `plugins/sdlc/agents/pe-sql-server.md:38`
**Introduced by:** HIGH-005
**Siblings:** `plugins/sdlc/agents/pe-sql-server.md:42`, `plugins/sdlc/agents/pe-sql-server.md:48`

The new offline check pipes `sqlfluff parse ... 2>&1 | grep -E 'PRS|unparsable' | head -20`. With sqlfluff not on
PATH, "command not found" is filtered out: reproduced on a malformed file (`SELEC 1`) — the loop printed only
"== <file>" and the pipeline exited 0, identical to a clean parse. A sqlfluff config/templater error is hidden the
same way. Line 48 tells the PE to read the exit code and to record a receipt when sqlfluff is unavailable, but the
pipeline keeps grep's exit code and shows nothing about availability; the lint line (42, `2>/dev/null || true`) is
silent too. The PE can attest "parse clean" when no parse ran.

**Recommendation:**
```
command -v sqlfluff >/dev/null || echo "sqlfluff not installed — no parse ran"
for f in <changed_sql_files>; do
  echo "== $f"; sqlfluff parse --dialect tsql "$f" > /tmp/sqlfluff.out 2>&1; echo "exit=$?"
  grep -E 'PRS|unparsable' /tmp/sqlfluff.out | head -20
done
```

#### 🟢 LOW-003: Specific Files / Folder / Ad-hoc rounds count as the branch's latest Gate 1 round

**Domains:** [Governance] · **Move:** M3
**Location:** `plugins/sdlc/skills/review/references/round-state.md:33`
**Introduced by:** MEDIUM-004
**Siblings:** `plugins/sdlc/skills/review/bin/review-file.js:617`, `plugins/sdlc/skills/review/bin/convergence.js:336`, `plugins/sdlc/skills/review/SKILL.md:387`, `plugins/sdlc/skills/pull-request/SKILL.md:288`, `plugins/sdlc/skills/deliver/SKILL.md:110`

Every Gate 1 round, partial-scope ones included, renders into the branch's <name>-code-review.md, and gate1 is now
"the latest round not MERGEABLE / OPEN — Gate 2". Reproduced on a temp copy: a Files round ("OPEN — not a branch
review") after a locked round 3 turns parse.gate1 from locked into {state: open, round: 4}, so pull-request and the
Gate 2 prerequisite treat Gate 1 as open on unchanged code; recovery takes two more clean branch rounds because
convergence.js also sees round 4 missing from the ledger and resets the streak. Conversely, overriding a Files or
Ad-hoc round (override does not refuse one) marks Gate 1 overridden for the whole branch though only those files
were reviewed. An Ad-hoc round is written into the working tree uncommitted and swept into the next Gate 1 commit.

**Recommendation:**
Keep partial-scope rounds out of the branch's Gate 1 record: render them to a separate doc (e.g. `{name}-files-review.md`)
or tag them so gate1Of and convergence's gap check skip them, and have `review-file.js override` refuse a round whose
status is "OPEN — not a branch review".

#### 🟢 LOW-004: A Gate 2 'Gate 1 skipped' record never reaches the PR

**Domains:** [Governance] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/references/publish.md:122`
**Introduced by:** HIGH-001
**Siblings:** `plugins/sdlc/skills/review/references/round-state.md:103`, `plugins/sdlc/skills/review/references/round-state.md:112`, `plugins/sdlc/skills/review/references/review-store.md:23`

Option (b) "Proceed anyway — record that Gate 1 was skipped" (and the --auto path) sets gate1_skip_note. Since
Gate 2 stopped committing, that note lands only in the reviewer's local doc under ~/.claude; the round's record
for everyone else is the Step 4 PR comment, whose contents list omits gate1_skip_note. The author, other reviewers
and the merger never see that peer review ran without a closed Gate 1.

**Recommendation:**
Add to the review-comment.md contents in Step 4: `"{session.gate1_skip_note}" if session.gate1_skip_note`.

#### 🟢 LOW-005: Gate 2 local store is keyed by key_slug only: PRs for the same ticket share one doc

**Domains:** [Governance] · **Move:** M3
**Location:** `plugins/sdlc/skills/review/references/review-store.md:9`
**Introduced by:** HIGH-001
**Siblings:** `plugins/sdlc/skills/review/bin/review-file.js:459`, `plugins/sdlc/skills/review/references/round-state.md:36`, `plugins/sdlc/skills/review/README.md:62`

The Gate 2 doc is ~/.claude/sdlc/reviews/<owner>/<repo>/<session.name>-code-review.md and session.name is the
key_slug, so two PRs for one issue (e.g. fix/42-retry and a backport fix/42-backport to a release base) both
resolve to "42". The second PR's Gate 2 round continues the first PR's numbering and its PEs receive the other PR's
findings as PRIOR REVIEW to mark resolved/still-present. In-repo Gate 1 docs avoided this because each branch
carried its own copy.

**Recommendation:**
Key the local doc by PR: `--name "{session.name}-pr{session.pr.number}"` in round-state.md (or add `--pr` to
parse --local so the path becomes `<owner>/<repo>/pr-<N>/<name>-code-review.md`), and update review-store.md and
the README row.

#### 🟢 LOW-006: Findings-ledger check's skip condition moved from pseudocode into a prose sentence

**Domains:** [Governance] · **Move:** none
**Location:** `plugins/sdlc/skills/review/references/round-state.md:46`
**Introduced by:** MEDIUM-008
**Siblings:** none

The prior block opened with `if not session.ledger: ... skip`; the rewrite states "Skipped when not
session.ledger (Gate 2, ...)" in prose above a code block that runs convergence.js status unconditionally. A
skimming agent on a Gate 2 round has ledger_path null; probe shows `--ledger ""` exits 2 ("missing --ledger"),
which the next branch reads as "findings ledger unreadable" and STOPs the review.

**Recommendation:**
Put the guard back in the block:
```
if session.ledger:
  status = `node ... convergence.js status ...`
  ...
```

#### 🟢 LOW-007: Phase 3 dereferences a null Gate 1 round when sdlc:review recorded none

**Domains:** [Governance] · **Move:** M3
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:102`
**Introduced by:** missed
**Siblings:** `plugins/sdlc/skills/deliver/SKILL.md:282`, `plugins/sdlc/skills/deliver/SKILL.md:295`, `plugins/sdlc/skills/deliver/SKILL.md:408`

Phase 2 goes straight to Phase 3 after invoking sdlc:review. When review exits without recording a Gate 1 round
(scope-banner abort, nothing to review, an early error), `gate1_round(r)` returns null and parse_latest_round
reads `g.verdict` and `g.counts`. Under --auto this lands in a "0 in-scope findings" remediation, an empty
index, and a confusing interactive prompt. The same dereference existed on `r.latest`.

**Recommendation:**
At the top of Phase 3 (or the end of Phase 2):
`if read_review().gate1.state == "none": ✅ Done — sdlc:review recorded no Gate 1 round; re-run sdlc:deliver {ticket_key}; print auto log; exit`.

#### 🟢 LOW-008: The open-PR check passes for a PR that existed before Phase 7, even when pull-request stopped before pushing

**Domains:** [Governance] · **Move:** M4
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:465`
**Introduced by:** MEDIUM-003
**Siblings:** `plugins/sdlc/skills/pull-request/SKILL.md:155`, `plugins/sdlc/skills/pull-request/references/push-and-create.md:67`

On a re-run against a branch that already has an open PR (Menu C → fix loop → Phase 7), pull-request can stop
before pushing: push rejected, version guard, SHA-drift "re-run review", or a dirty tree. `gh pr view` still
finds the old OPEN PR, so End prints "delivered" with that PR while the fix commits stay local.

**Recommendation:**
Also fetch `headRefOid` and require it to equal `git rev-parse HEAD`:
`(v, ec) = gh pr view --json number,url,state,headRefOid`; `if ec != 0 or v.state != "OPEN" or v.headRefOid != HEAD: stopped before the PR …`.

#### 🟢 LOW-009: Version guard misses plugin.json for bare sources under metadata.pluginRoot and for source "."

**Domains:** [Governance] · **Move:** M7
**Location:** `plugins/sdlc/references/version-collision-guard.md:26`
**Introduced by:** MEDIUM-006
**Siblings:** `plugins/sdlc/references/version-collision-guard.md:3`, `plugins/sdlc/references/version-collision-guard.md:40`

plugin_json returns null for any source that does not start with "./". Claude Code's marketplace reference
also allows a bare directory name resolved under `metadata.pluginRoot` (e.g. "formatter" with pluginRoot
"./plugins"), and "." for the marketplace root. In stamped marketplaces with that layout, hand edits to
plugin.json versions pass the guard.

**Recommendation:**
```
if p.source == "." : dir = ""
elif p.source starts with "./": dir = strip "./" and trailing "/"
elif p.source is a string without "/" and head_m.metadata.pluginRoot: dir = pluginRoot (minus "./", trailing "/") + "/" + p.source
else: return null
```

#### 🟢 LOW-010: deliver's override commit has no pathspec, unlike the fixed Gate 1 commit

**Domains:** [Governance] · **Move:** M1
**Location:** `plugins/sdlc/skills/deliver/references/override.md:24`
**Introduced by:** HIGH-003
**Siblings:** `plugins/sdlc/skills/review/references/publish.md:41`

HIGH-003 listed override.md:24 as a sibling, and it still reads "commit the review-file update (an ordinary
commit)". When a fix-loop commit failed (the new failure branch), the touched paths stay staged. Picking
override next then commits those unreviewed fixes inside the override commit.

**Recommendation:**
`git commit -m "docs: {session.name} review override" -- '{session.review_file}'`, mirroring publish.md:41.

#### 🟢 LOW-011: Resume checkout has no failure branch; a failed checkout leaves later commits on the current branch

**Domains:** [Governance] · **Move:** M5
**Location:** `plugins/sdlc/skills/implement/references/existing-branch.md:33`
**Introduced by:** HIGH-006
**Siblings:** `plugins/sdlc/skills/implement/SKILL.md:338`

`git checkout '{b}'` (or `--track`) fails when b is checked out in another worktree. implement itself suggests
one worktree per story (SKILL.md:410). The step still sets `session.branch_name = b` and returns resume, so
Branch cut and Phase 4 run on whatever branch is checked out, for example the default branch. The same fix
added a failure branch to `git checkout -b` (SKILL.md:338) but not here.

**Recommendation:**
`if the checkout fails: ❌ Error — cannot check out {b}: {git's message}; STOP`.

#### 🟢 LOW-012: Copilot instruction files in a subdirectory of .github/instructions route to pe-general-purpose

**Domains:** [DevTools] · **Move:** M7
**Location:** `plugins/sdlc/skills/review/bin/scope.js:99`
**Introduced by:** LOW-008
**Siblings:** `plugins/sdlc/agents/pe-governance.md:3`, `plugins/sdlc/agents/pe-governance.md:24`, `plugins/sdlc/agents/pe-general-purpose.md:28`, `plugins/sdlc/skills/review/SKILL.md:217`, `plugins/sdlc/skills/review/bin/test/run-scope-tests.sh:143`, `plugins/sdlc/skills/review/bin/test/run-scope-tests.sh:156`

GitHub's Copilot docs say path-specific instructions live "within or below the .github/instructions directory" and invite subdirectories. scope.js's `*` stays within one path segment (scope.js:31). Reproduced with classify: .github/instructions/backend/go.instructions.md → pe-general-purpose, while .github/instructions/go.instructions.md → pe-governance. The four doc restatements state the same single-level glob.

**Recommendation:**
Use `.github/instructions/**/*.instructions.md` in scope.js and the four restatements, and add a nested path to the routing check at run-scope-tests.sh:143/156.

#### 🟢 LOW-013: Six new fail-closed guards survive mutation: override parse-back, gate2 input checks, same_code SHA guard, VAGUE anchor

**Domains:** [DevTools] · **Move:** M6
**Location:** `plugins/sdlc/skills/review/bin/review-file.js:439`
**Introduced by:** MEDIUM-015
**Siblings:** `plugins/sdlc/skills/review/bin/review-file.js:676`, `plugins/sdlc/skills/review/bin/review-file.js:679`, `plugins/sdlc/skills/review/bin/review-file.js:694`, `plugins/sdlc/skills/review/bin/review-file.js:124`, `plugins/sdlc/skills/review/bin/findings.js:36`

These mutants all pass run-review-file-tests.sh (119/119) or run-findings-tests.sh (32/32): override's parse-back check replaced with `if (false)` (it is reachable through a reviewer value containing a newline); gate2's --head SHA test dropped; the reviews-array check dropped; the --root existence check dropped; sameCode's SHA guard dropped (it keeps a GitHub-sourced commit oid away from option position in git argv); and VAGUE unanchored to match anywhere in the text. This is the same gap as round-1 LOW-021 (appendRound), whose fix added a test. The new siblings have none.

**Recommendation:**
Add one case per guard and assert exit 2 with the file unchanged: an override whose reviewer holds "\n## Review Round 9"; gate2 with --head HEAD, with a stub returning {"author":{...}} and no reviews, and with --root on a missing path; a stubbed review whose commit.oid is "--output=x" (assert "not the current code"); and a concrete recommendation with "consider" mid-sentence (assert no re-dispatch).

#### 🟢 LOW-014: The suite's --local test writes into the real Windows profile, because os.homedir() ignores HOME there

**Domains:** [DevTools] · **Move:** M7
**Location:** `plugins/sdlc/skills/review/bin/test/run-review-file-tests.sh:27`
**Introduced by:** HIGH-001
**Siblings:** `plugins/sdlc/skills/review/bin/test/run-review-file-tests.sh:432`, `plugins/sdlc/skills/review/bin/test/run-build-plan-tests.sh:29`, `plugins/sdlc/skills/review/bin/test/run-scope-tests.sh:25`, `plugins/sdlc/skills/review/bin/test/run-worktree-cleanup-tests.sh:29`

The suite's hermetic preamble only exports HOME. The new `parse --local` case renders into $HOME/.claude/sdlc/reviews/octo-org/octo-repo. The Node docs say os.homedir() reads USERPROFILE on Windows, so under Git Bash review-file.js writes into the contributor's real ~/.claude/sdlc/reviews, and the markdown_path equality check fails. build-plan.js and its suite handle Windows explicitly (cygpath), so Git Bash is a platform this shard has in mind. CI is ubuntu-only, so CI never sees this.

**Recommendation:**
After `export HOME=…`, add `export USERPROFILE="$HOME"` to the preamble at run-review-file-tests.sh:27. The other three suites can take the same line if a later test resolves os.homedir().

#### 🟢 LOW-015: update --key on an untracked file silently overwrites the issue another file tracks

**Domains:** [DevTools] · **Move:** M4
**Location:** `plugins/sdlc/skills/plan/bin/gh-issues.js:505`
**Introduced by:** LOW-016
**Siblings:** `plugins/sdlc/skills/plan/bin/gh-issues.js:20`, `plugins/sdlc/skills/plan/bin/test/gh-issues.test.js:570`

The fix refuses --key only when the file itself is tracked under a different number. A typo in the other
direction still goes through. Example: 01-Story-Search-By-Title.md is tracked as #42 and
02-Story-Place-A-Hold.md is untracked. `update --docs-path <epic> --file 02-Story-Place-A-Hold.md --key 42`
runs `issue edit 42 --title "Place a hold" --body-file -`, prints "✅ Done" and exits 0. Issue #42's title
and body now hold the other story. Reproduced on a temp copy with the suite's sandbox and stub gh.

**Recommendation:**
Also refuse when state.issues maps `key` to a different file
(Object.entries(state.issues).some(([f, n]) => n === key && f !== t.fname)), and name that file in the error.
Add the case beside gh-issues.test.js:570.

#### 🟢 LOW-016: Ticket-history #NNN guard still misses 2-digit history and fires on HTML entities and hex colours

**Domains:** [DevTools] · **Move:** M4
**Location:** `plugins/sdlc/bin/test/run-skill-structure-tests.sh:73`
**Introduced by:** still-present
**Siblings:** `plugins/sdlc/bin/test/run-skill-structure-tests.sh:25`, `plugins/sdlc/bin/test/run-pe-agent-tests.sh:49`, `plugins/sdlc/bin/test/run-pe-agent-tests.sh:55`

The guard uses `#[0-9]{3,}`, as round 1 recommended, so round 1's own repro still passes: with
"Since #20 merged this changed (regression from #17)" seeded into deliver/SKILL.md, check_ticket_history
stays silent. This repo's PR numbers are two-digit. The same probe shows false positives: the guard fires
on `&#8212;` (as #8212) and on the hex colour `#5319e7` (as #5319). The history skills currently contain
only #42 (11 times) and #57 (once, verification-gate.md:154), so a two-digit floor is affordable.

**Recommendation:**
Match `(^|[^&[:alnum:]])#[0-9]{2,}` and allowlist #42, #57, #123 and #1234 as examples. Keep the pe-agent
sibling in step, or note why it differs. Add a "#20 fires" case and an "&#8212; is silent" case.

#### 🟢 LOW-017: PR commit check still flags git revert's default subject

**Domains:** [DevTools] · **Move:** M3
**Location:** `plugins/sdlc/bin/git-conventions.js:65`
**Introduced by:** still-present
**Siblings:** `plugins/sdlc/skills/pull-request/SKILL.md:249`, `plugins/sdlc/bin/test/fixtures/git-conventions/commits-valid.txt:1`

Round 1's LOW-014 named both merge and revert subjects; --no-merges fixed only the merges. git revert's
default subject, `Revert "feat: add x"`, still comes back as an offender ("missing `<type>: ` prefix").
pull-request therefore warns and asks on every run for any branch that reverted a commit.

**Recommendation:**
Accept `^Revert ".+"$` in checkCommits, or skip such subjects the way merges are skipped, and add one to
commits-valid.txt.

#### 🟢 LOW-018: base contract is restated wrongly: branch on stdin, and deliver's PR-base claim

**Domains:** [Governance, DevTools] · **Move:** M1
**Location:** `plugins/sdlc/bin/git-conventions.js:21`
**Introduced by:** MEDIUM-001
**Siblings:** `plugins/sdlc/bin/git-conventions.js:3`, `plugins/sdlc/bin/git-conventions.js:40`, `plugins/sdlc/skills/deliver/SKILL.md:158`, `plugins/sdlc/skills/deliver/SKILL.md:170`, `plugins/sdlc/skills/deliver/SKILL.md:236`, `plugins/sdlc/skills/implement/references/existing-branch.md:37`, `plugins/sdlc/skills/pull-request/SKILL.md:156`, `plugins/sdlc/skills/review/SKILL.md:140`, `plugins/sdlc/skills/review/SKILL.md:496`

The header says branch names reach the script on stdin through a quoted heredoc, and review SKILL.md:496
repeats this. In fact `base` takes the branch only as `--branch <b>`, and both callers pass it as a shell
argument: review SKILL.md:140 (after its safe_branch check) and existing-branch.md:37. The summary at
line 3 does not mention base. deliver SKILL.md:170's comment promises "PR base > …", but resolve_base
never passes --pr, so deliver never consults the PR's base. Normal use does not break; the stated
contract is wrong.

**Recommendation:**
In the header, name `base --branch` as the one branch input taken as an argument, refused by safeRef
unless the name is plain. Make review SKILL.md:496 match. In deliver, drop "PR base >" from the comment,
or pass --pr when a PR exists. Add base to line 3.

#### 🟢 LOW-019: safeRef's leading-character and .lock rules have no test, and the header states a narrower rule

**Domains:** [DevTools] · **Move:** M6
**Location:** `plugins/sdlc/bin/git-conventions.js:193`
**Introduced by:** MEDIUM-001
**Siblings:** `plugins/sdlc/bin/git-conventions.js:46`, `plugins/sdlc/bin/test/run-git-conventions-tests.sh:387`

On a temp copy, removing the leading-character rule (so `-x` is accepted) leaves all 129 checks green;
removing the `.lock` rule does the same. The header at line 46 names only `..`, `//` and a leading `-`.
The code also refuses a leading `.` or `_`, `/.`, `.lock`, a trailing `/` or `.`, and names over
255 characters.

**Recommendation:**
Add `--branch -x` and `--branch feat/1-x.lock` cases. Make line 46 say the name must start with a letter
or digit, and list the other rules.

#### 🟢 LOW-020: git-conventions suite header omits its base section and SDLC_TEST_TMP

**Domains:** [DevTools] · **Move:** M1
**Location:** `plugins/sdlc/bin/test/run-git-conventions-tests.sh:2`
**Introduced by:** MEDIUM-001
**Siblings:** `plugins/sdlc/bin/test/run-git-conventions-tests.sh:307`, `plugins/sdlc/bin/test/run-pr-checks-tests.sh:5`, `plugins/sdlc/bin/test/run-skill-structure-tests.sh:7`

The suite now reads SDLC_TEST_TMP (line 307) and tests `base` against throwaway git repos, but its header
mentions neither. Both sibling suites document SDLC_TEST_TMP in their headers.

**Recommendation:**
Add base to the header's summary, and copy the SDLC_TEST_TMP line the siblings carry.

#### 🟢 LOW-021: UNVERIFIED — Copilot coverage wording after GitHub's 2026-11-06 overview redesign

**Domains:** [DevTools] · **Move:** M7
**Location:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:53`
**Introduced by:** MEDIUM-019
**Siblings:** `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:54`, `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:49`, `plugins/sdlc/skills/copilot-review/SKILL.md:99`, `plugins/sdlc/skills/copilot-review/SKILL.md:117`, `plugins/sdlc/skills/pull-request/references/copilot-review.md:22`

GitHub's 2026-11-06 changelog redesigned the Copilot review overview. Skipped and excluded files now share
one "Files not reviewed" section, which NOT_REVIEWED matches. Empty sections are omitted. The changelog
does not say whether the "Copilot reviewed N out of M changed files" line survived. If it did not, every
fully reviewed PR parses as partial: null, prints the "does not say which files it reviewed" warning, and
reports coverage "unknown". That fails safe, but the warning becomes noise on every run. The same
changelog says the API now has explicit fields that attribute reviews to Copilot; these may be more
reliable than the login heuristic at line 49 (prior LOW-013).

**Recommendation:**
On the first live review after the quota reset, save the real review body and author JSON as fixtures.
Confirm COVERAGE, NOT_REVIEWED and the identity check against them. If the N-of-M line is gone, decide
whether a missing "Files not reviewed" section is enough evidence of full coverage.

#### 🟢 LOW-022: Gate 2 accepts CI `none` right after a push, before the head's checks register

**Domains:** [CI] · **Move:** M2
**Location:** `plugins/sdlc/skills/review/references/ci-gate.md:34`
**Introduced by:** missed
**Siblings:** `plugins/sdlc/skills/review/bin/review-file.js:87`, `plugins/sdlc/skills/review/README.md:29`, `plugins/sdlc/skills/review/README.md:31`

`none` clears the CI gate, so MERGEABLE then follows the reviewers' GitHub reviews alone. GitHub reports no checks on a head until its workflows register, which takes seconds after a push (seen on #23, where `gh pr checks --watch` exited with "no checks reported" before any check existed). A Gate 2 round whose CI read lands in that window approves and reports MERGEABLE before CI has run. The review itself usually takes minutes, and branch protection still enforces required checks, so the window is small.

**Recommendation:**
When `pr-checks.js` returns `none` and the repo has a workflow with a `pull_request` trigger under `.github/workflows/`, wait about 30 seconds and read the checks once more before accepting `none`; say so in the ci-gate table row and the README.

#### ℹ️ INFO-001: Convergence signal: severity falling, last-mile findings in themes round 1 already raised

**Domains:** [DevTools] · **Move:** none
**Location:** `plugins/sdlc/skills/review/bin/review-file.js:1`
**Introduced by:** new
**Siblings:** none

In round 1 this shard had 1 HIGH and 7 LOW; this round has 0 gating and 3 LOW. All three LOW themes repeat round-1 themes: a routing glob (LOW-008), guards that survive mutation (LOW-019/020/021), and test hermeticity (LOW-024).
Verified fixed at 217a9b6: HIGH-008 (Verdict row; gate2 now reads GitHub reviews), HIGH-001's review-file.js sibling (same_code), MEDIUM-004 (parse gate1), MEDIUM-013 (rebuttals removed from bin), MEDIUM-015 (override writer), LOW-009, LOW-019, LOW-020, LOW-021, LOW-022, LOW-023 and LOW-024. LOW-008 is fixed apart from nested instruction directories (LOW-001).

**Recommendation:**
Apply the three LOW fixes in the planned follow-up PR or ignore them. None of them justifies another round for this shard.

#### ℹ️ INFO-002: Convergence signal: severity falling and a closed set in shard B

**Domains:** [DevTools] · **Move:** none
**Location:** `docs/code-reviews/feat-sdlc-code-review.md:47`
**Introduced by:** new
**Siblings:** none

Severity is falling: round 1 had 1 HIGH and 4 MEDIUM in this shard; round 2 has no HIGH or MEDIUM and 7 LOW.
The themes form a closed set: 4 of the 7 recur from round 1 (update --key, the ticket-history guard,
revert subjects, Copilot wording), each now a LOW edge refinement.
Verified fixed at HEAD by suite and mutation: HIGH-007, MEDIUM-001 (script side), MEDIUM-017, MEDIUM-018,
MEDIUM-019, LOW-012, LOW-015, LOW-017 and LOW-018. LOW-013 is done per its recommendation but still
unverified on a live review. MEDIUM-020, LOW-014 and LOW-016 are partly fixed (LOW-001 to LOW-003 below).

**Recommendation:**
Nothing in this shard blocks. Treat the LOWs as awareness. Another round is unlikely to raise severity
without a scope change.

### Action Items

#### Must Fix (blocks merge)

- [ ] HIGH-001: fix `plugins/sdlc/skills/implement/references/existing-branch.md:32` + 12 siblings

#### Should Fix

- [ ] MEDIUM-001: fix `plugins/sdlc/skills/review/references/round-state.md:36` + 6 siblings
- [ ] MEDIUM-002: fix `plugins/sdlc/skills/deliver/SKILL.md:241` + 5 siblings

#### Consider

- [ ] LOW-001: fix `plugins/sdlc/skills/review/references/publish.md:91` + 1 siblings
- [ ] LOW-002: fix `plugins/sdlc/agents/pe-sql-server.md:38` + 2 siblings
- [ ] LOW-003: fix `plugins/sdlc/skills/review/references/round-state.md:33` + 5 siblings
- [ ] LOW-004: fix `plugins/sdlc/skills/review/references/publish.md:122` + 3 siblings
- [ ] LOW-005: fix `plugins/sdlc/skills/review/references/review-store.md:9` + 3 siblings
- [ ] LOW-006: fix `plugins/sdlc/skills/review/references/round-state.md:46` + 0 siblings
- [ ] LOW-007: fix `plugins/sdlc/skills/deliver/SKILL.md:102` + 3 siblings
- [ ] LOW-008: fix `plugins/sdlc/skills/deliver/SKILL.md:465` + 2 siblings
- [ ] LOW-009: fix `plugins/sdlc/references/version-collision-guard.md:26` + 2 siblings
- [ ] LOW-010: fix `plugins/sdlc/skills/deliver/references/override.md:24` + 1 siblings
- [ ] LOW-011: fix `plugins/sdlc/skills/implement/references/existing-branch.md:33` + 1 siblings
- [ ] LOW-012: fix `plugins/sdlc/skills/review/bin/scope.js:99` + 6 siblings
- [ ] LOW-013: fix `plugins/sdlc/skills/review/bin/review-file.js:439` + 5 siblings
- [ ] LOW-014: fix `plugins/sdlc/skills/review/bin/test/run-review-file-tests.sh:27` + 4 siblings
- [ ] LOW-015: fix `plugins/sdlc/skills/plan/bin/gh-issues.js:505` + 2 siblings
- [ ] LOW-016: fix `plugins/sdlc/bin/test/run-skill-structure-tests.sh:73` + 3 siblings
- [ ] LOW-017: fix `plugins/sdlc/bin/git-conventions.js:65` + 2 siblings
- [ ] LOW-018: fix `plugins/sdlc/bin/git-conventions.js:21` + 9 siblings
- [ ] LOW-019: fix `plugins/sdlc/bin/git-conventions.js:193` + 2 siblings
- [ ] LOW-020: fix `plugins/sdlc/bin/test/run-git-conventions-tests.sh:2` + 3 siblings
- [ ] LOW-021: fix `plugins/sdlc/skills/copilot-review/bin/copilot-review.js:53` + 5 siblings
- [ ] LOW-022: fix `plugins/sdlc/skills/review/references/ci-gate.md:34` + 3 siblings
- [ ] INFO-001: fix `plugins/sdlc/skills/review/bin/review-file.js:1` + 0 siblings
- [ ] INFO-002: fix `docs/code-reviews/feat-sdlc-code-review.md:47` + 0 siblings

### Merge Eligibility

**Locked to SHA:** `217a9b659ecb292dcdabf7b8bf3872075b04f5ed`
**Status:** 🚫 Not mergeable — 1 HIGH and 2 MEDIUM findings open. Any commit after this SHA requires re-review.

---

## Review Round 3

**Verdict:** ⚠️ CHANGES REQUESTED

| | |
| - | - |
| **Reviewer** | @Cali LaFollett |
| **PR** | [#24](https://github.com/lafollett-labs/lafollett-labs-claude-plugins/pull/24) |
| **Reviewed SHA** | `465b4ccaebdae0ff3ef9285ed19044a4809449fa` |
| **Date** | 2026-11-27 |
| **Fix cascade** | 12 / 18 in-scope findings introduced by a prior fix |
| **Ripple receipts** | 25 spot-checked |

### Summary

Every round-2 finding the PEs re-checked is fixed at this SHA, including the HIGH: implement now drops unsafe branch names before any git command, and the injection name is refused in a temp shell. One gating gap remains, in the same family as round 2's MEDIUM-002: deliver's no-commit stop runs only for resume and start-over, so a fresh run started on another ticket's branch reviews that branch when implement stops before leaving it. The LOWs refine round-2 fixes: two shell globs abort under zsh when nothing matches, the 30-second CI wait names no mechanism the Bash tool allows, Staged rounds still write the branch ledger, git's Reapply subject, safeRef rules without tests, and lost line numbers in the issue-history guard. All four PEs report severity falling over a closed set of themes. Nothing was merged or dismissed.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-Governance (review skill + agents) | none | doc-only; pe-agent 143/0, skill-structure 30/0, review-file 137/0, convergence 197/0 at HEAD; zsh NOMATCH and the blocked foreground sleep reproduced |
| PE-Governance (other skills + shared refs) | none | doc-only; skill-structure 30/0; safe-ref filter run on 5 names in a temp shell; override pathspec commit run in a temp repo |
| PE-DevTools (review scripts) | lint-only | 6 suites from / → 618 checks, 0 failed; shellcheck clean; 27 mutations, 23 caught (3 equivalent) |
| PE-DevTools (other scripts) | lint-only | 11 suites from / pass; shellcheck clean on 13 files; check-pr.sh clean; 29 mutations, 21 caught |
| Primary | n/a | `bash scripts/ci/run-shell-tests.sh` → 25 suites, 0 failed; CI run 45973176277 green at 465b4cc |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-Governance (review + agents) | 14 receipts, 1 unreceipted binding, glob pattern grepped | partial rounds on a temp ledger, PR-keyed Gate 2 doc, skip note, prior_same | 9 input classes | workflow grep under zsh and bash on 4 temp repos | 6 failure paths incl. no .sqlproj under zsh | n/a — no test changed in this shard | zsh NOMATCH, Bash tool sleep refusal, --skip and --local --pr headers |
| PE-Governance (other skills) | 18 receipts, 1 kept reason does not hold | deliver → implement → deliver over 4 starts × 7 stops | gate1 none, plugin sources, ticket_branches lists, resolve_base | safe-ref filter on 5 names, no-commit check, headRefOid check | 5 failure paths | n/a — no test in this shard | marketplace reference, pathspec commit on a new file, lstrip=3 |
| PE-DevTools (review scripts) | 3 contracts → 7 call sites, 6 restatements | partial rounds in 6 orders | --skip and --local --pr values, scope modes | 5 guards both ways (Staged passes as a branch round) | bad --skip, record fail-closed | 27 mutations, 1 real survivor | n/a beyond headers — no external fact in the fix diff |
| PE-DevTools (other scripts) | 6 receipts, 2 disagree | update --key ordering, suite temp paths | revert subjects, issue_refs tokens, --key owners | 4 guards both ways | --key refusal, base refusal, unreadable file | 29 mutations, 8 survived | git revert of a revert, check-ref-format, safeRef header vs code |
| Primary | 2 README restatements vs ci-gate and review-store | n/a — no state change in this shard | n/a — no parser or loop | n/a — no guard in this shard | n/a — no calls | n/a — no test | n/a — no new external claim |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 1 | 0 |
| 🟢 LOW | 12 | 0 |
| ℹ️ INFO | 5 | 0 |

### In Scope Findings

#### 🟡 MEDIUM-001: A fresh deliver run started on another ticket's branch still reviews that branch when implement stops before leaving it

**Domains:** [Governance] · **Move:** M1
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:242`
**Introduced by:** MEDIUM-002
**Siblings:** `plugins/sdlc/skills/deliver/SKILL.md:247`, `plugins/sdlc/skills/deliver/references/resume-menus.md:15`, `plugins/sdlc/skills/deliver/SKILL.md:156`

The MEDIUM-002 fix runs the no-commit stop only when session.implement_mode is set. The receipt
kept line 247 because "commits_ahead == 0 still covers fresh runs". That reason holds only when the
fresh run starts on the base branch.
Trace: the engineer is on feat/41-x with uncommitted edits and runs `/sdlc:deliver #42 --auto`.
  - Phase 0 warns that the branch belongs to #41 and starts fresh (line 156).
  - Phase 1 binds head_before to feat/41-x. implement --auto HALTs at its dirty-tree gate, and the
    engineer picks "Commit first — exit" or "Abort". implement exits with HEAD still on feat/41-x.
  - implement_mode is "", so line 242 is skipped. commits_ahead counts #41's commits (> 0), so
    line 247 is skipped too, and deliver goes to Phase 2 with session.auto still true.
  - sdlc:review --auto names the round from the current branch (review SKILL.md:161 → "41"). It
    auto-picks PR #41 (review SKILL.md:97), then commits and pushes 41-code-review.md onto feat/41-x
    (publish.md:30). It also posts on issue #41 and the PR and sends the Slack verdict.
  - Phase 3 reads 42-code-review.md, finds state none, and prints "sdlc:review recorded no Gate 1 round".
implement's Phase 1 stops lead to the same result: ticket not found, epic, gh unavailable, and a
declined closed issue. All of them come before Phase 2 moves HEAD. This is round-1 MEDIUM-002's
outcome (another ticket's branch reviewed inside this run), reached through the fresh path that fix
routes to. It now ends without a PR only because the LOW-007 guard happens to miss the doc name.

**Recommendation:**
Run the stop check for every mode. HEAD cannot equal head_before after a fresh run that committed.
```
if `git rev-parse HEAD` == head_before:   # implement added no commit, whatever the mode
  finish("✅ Done — sdlc:implement added no commits on {session.branch}{" (start over did not happen)" if start_over}; re-run sdlc:deliver {session.ticket_key} when ready")
```
Keep line 247 for a branch cut with no commit. In resume-menus.md:15, change "either run" to "every run".

#### 🟢 LOW-001: Gate 2 CI re-read never runs under zsh, and its 30-second wait is a sleep the Bash tool refuses

**Domains:** [Governance] · **Move:** M7
**Location:** `plugins/sdlc/skills/review/references/ci-gate.md:13`
**Introduced by:** LOW-022
**Siblings:** `plugins/sdlc/skills/review/references/ci-gate.md:14`, `plugins/sdlc/skills/review/references/ci-gate.md:38`, `plugins/sdlc/skills/review/README.md:31`, `plugins/sdlc/agents/pe-sql-server.md:36`

The new check passes two shell globs, `.../.github/workflows/*.yml` and `.../*.yaml`. The Bash
tool runs the user's shell, which is zsh in this session and by default on macOS. Under zsh's
NOMATCH option an unmatched glob is an error that cancels the command. So in a repo whose
workflows all use one extension (this repo has only ci.yml and release.yml), grep never runs
and the condition exits 1.
Reproduced on temp repos: zsh gives exit=1 for both a .yml-only and a .yaml-only workflow dir;
bash gives exit=0 for both. Gate 2 then accepts `none` on the first read, which is the round-2
behaviour.
Separately, line 14's "wait 30 seconds" names no mechanism. The Claude Code Bash tool refuses a
foreground `sleep 30` ("Blocked: sleep 30 … use Monitor … or run_in_background"; reproduced in
this session), so the agent has to improvise the wait or skip it.
Branch protection still enforces required checks, so the gap is the round-2 LOW window, not a
new hole.

**Recommendation:**
Move the settle step into pr-checks.js, where it is deterministic and does not depend on the
shell. Detect the workflow in Node (fs over .github/workflows/*.yml|*.yaml, test /pull_request/)
and wait with Atomics.wait, as copilot-review.js:259 already does. For example,
`check --pr N --head SHA --settle 30` re-reads once when the state is none and such a workflow
exists; ci-gate.md then calls read_ci once and drops lines 13–14.
If the step stays in the doc, use a command with no glob:
`grep -rqsE --include='*.yml' --include='*.yaml' 'pull_request' "{session.review_root}/.github/workflows"`
(verified: exit 0 under both zsh and bash for .yml-only and .yaml-only dirs; exit 1 for a
push-only dir or no dir). Also name how to wait, since a bare `sleep 30` is refused.

#### 🟢 LOW-002: Without a .sqlproj, the `*.sqlproj` glob aborts the whole Commands block under zsh: no parse, no lint, no exit= line

**Domains:** [Governance] · **Move:** M5
**Location:** `plugins/sdlc/agents/pe-sql-server.md:36`
**Introduced by:** LOW-002
**Siblings:** `plugins/sdlc/agents/pe-sql-server.md:37`, `plugins/sdlc/agents/pe-sql-server.md:55`, `plugins/sdlc/skills/review/references/ci-gate.md:13`

The guard `[ -f "$p" ] || { echo "no .sqlproj — no model build ran"; break; }` handles bash,
where an unmatched glob stays a literal word. Under zsh, the Bash tool's shell here,
`for p in <dir>/*.sqlproj` with no match errors before the loop starts, and the rest of the
block is cancelled.
Reproduced by running the block as written, in one Bash tool call, on a db root with one .sql
file and no .sqlproj. The only output was `(eval):3: no matches found: …/*.sqlproj`. The
"no .sqlproj" line, the "sqlfluff not installed" line, the parse loop and the lint never ran.
Under bash the same block prints all three lines and `exit=127`.
Line 55 calls a missing .sqlproj expected for a state-based repo, the layout this agent
describes first. It tells the PE to look for `exit=127` or "not installed" to know a check did
not run, and neither appears. A PE can therefore still record "parse clean" when no parse ran,
which is the LOW-002 outcome. The pre-fix line used the same glob; the new guard does not
cover zsh.

**Recommendation:**
Find project files without a shell glob, so zsh and bash behave the same (verified under both,
with and without a .sqlproj):
```bash
find <worktree>/<db_subdir> -maxdepth 1 -name '*.sqlproj' | grep -q . || echo "no .sqlproj — no model build ran"
find <worktree>/<db_subdir> -maxdepth 1 -name '*.sqlproj' | while IFS= read -r p; do
  echo "== $p"; dotnet build "$p" /p:NetCoreBuild=true < /dev/null; echo "exit=$?"
done
```
(`< /dev/null` keeps dotnet from reading the loop's stdin.)

#### 🟢 LOW-003: Override option is withheld from partial-scope rounds only by a trailing comment

**Domains:** [Governance] · **Move:** M4
**Location:** `plugins/sdlc/skills/review/SKILL.md:440`
**Introduced by:** LOW-003
**Siblings:** `plugins/sdlc/skills/review/bin/review-file.js:421`, `plugins/sdlc/skills/review/references/round-state.md:129`

The fix appends `# offered only when session.ledger: …` to option (b). The options list itself
still shows (b) unconditionally, and § Input Gate Rendering builds options from "the gate's
enumerated choices". An agent skimming the block can therefore offer all three options on a
Files / Folder / Ad-hoc round that has gating findings.
Choosing (b) fails safely: review-file.js:421 refuses to override a partial round, and
round-state.md:129 returns to remediate. The cost is a dead option and an error message, not a
wrong record.

**Recommendation:**
Make the condition part of the option list:
`options = [(a), (b), (c)] if session.ledger else [(a), (c)]`, or put `if session.ledger` on
the (b) line in the same inline-conditional form the file uses elsewhere.

#### 🟢 LOW-004: The Phase 7 headRefOid check says no PR was opened when a Copilot fix commit stays local

**Domains:** [Governance] · **Move:** M4
**Location:** `plugins/sdlc/skills/deliver/SKILL.md:459`
**Introduced by:** LOW-008
**Siblings:** none

copilot-review commits each Copilot fix and then pushes once. When that push is rejected, it keeps
the commits local (copilot-review/SKILL.md:136). By then the PR is open, and pull-request still
labels and announces it and prints "✅ Done — PR opened". deliver then sees headRefOid != HEAD and
ends with "stopped before the PR: sdlc:pull-request exited without opening or updating one". That
contradicts the sub-skill, skips End, and drops the PR number from deliver's summary. No wrong
action follows; only the report is wrong.

**Recommendation:**
Split the condition so that LOW-008's protection stays and the message matches the state:
```
if ec != 0 or v.state != "OPEN":
  finish("✅ Done — stopped before the PR: sdlc:pull-request exited without opening one (see its output above)")
if v.headRefOid != `git rev-parse HEAD`:
  finish("⚠️ PR #{v.number} {v.url} is open but HEAD is not on it — push {session.branch}, then re-run sdlc:pull-request")
```

#### 🟢 LOW-005: The fix diff adds lines that explain why the pseudocode is safe and do not change what the model does

**Domains:** [Governance] · **Move:** none
**Location:** `plugins/sdlc/skills/implement/references/existing-branch.md:5`
**Introduced by:** HIGH-001
**Siblings:** `plugins/sdlc/skills/implement/SKILL.md:267`, `plugins/sdlc/skills/implement/references/spike.md:20`, `plugins/sdlc/skills/deliver/references/override.md:25`

Four added lines justify the code instead of directing the agent:
  - existing-branch.md:5-6 "...so it is safe inside the single quotes below"
  - implement SKILL.md:267 "# git allows $( ), backticks, quotes and ; in names"
  - spike.md:20 "# session.branch_name is safe-ref checked..."
  - override.md:25 "# it may be untracked..."
The house style's CUT list covers "this works because…" lines. These files load on every invocation.
This is token weight only: no lines need to change behaviour.

**Recommendation:**
Drop them in the planned behaviour-preserving diet PR.

#### 🟢 LOW-006: Staged Diff rounds still write the branch ledger, so two staged rounds lock Gate 1 at a HEAD that lacks the reviewed code

**Domains:** [DevTools] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/bin/scope.js:181`
**Introduced by:** missed
**Siblings:** `plugins/sdlc/skills/review/bin/scope.js:17`, `plugins/sdlc/skills/review/bin/test/run-scope-tests.sh:190`, `plugins/sdlc/skills/review/SKILL.md:440`, `plugins/sdlc/skills/review/SKILL.md:488`, `plugins/sdlc/skills/review/references/round-state.md:31`, `plugins/sdlc/skills/review/references/round-state.md:50`, `plugins/sdlc/skills/review/README.md:11`

The LOW-003 fix keeps Files / Folder / Ad-hoc rounds out of the branch's Gate 1 record. The staged mode is the same
pattern and the fix left it in: scope.js returns ledger: true for it, so convergence.js records it as a branch round.
A staged round reviews only the index-vs-HEAD diff. Committed branch code is pre-existing and goes out of scope, and
Reviewed SHA is bound to `git rev-parse HEAD` (round-state.md:29). Since the round-1 HIGH-003 fix, the review-doc
commit takes only the review paths, so the staged code is never in the SHA the lock records.
Probe on a mktemp ledger: round 1 (branch) records a MEDIUM; rounds 2 and 3 (staged, which cannot see that line)
record []. Round 2 marks the MEDIUM RESOLVED and round 3 returns LOCKED.
In normal use, sdlc:review then reports Gate 1 LOCKED. As soon as the engineer commits the staged change,
pull-request (SKILL.md:295) and the next review's post-lock check both report the lock as stale. If the staged change
is instead unstaged, the branch carries a LOCKED Gate 1 at a SHA whose MEDIUM was never re-reviewed. When a branch
round later finds the MEDIUM again, its reopen_count goes up, which moves it toward the reopen-guard.
README.md:11 lists staged changes with files and folders as a "focused review". scope.js:17 and
run-scope-tests.sh:190 state the opposite, deliberately.

**Recommendation:**
Treat staged like files: in scope.js:181 return `ledger: false` for 'staged'. Change run-scope-tests.sh:190 to assert
`o.ledger === false`, and add Staged to the lists at scope.js:17, SKILL.md:440/488 and round-state.md:31/50.
SKILL.md:386 then renders the round as "OPEN — not a branch review" and every LOW-003 exclusion applies.
If staged locks are intended, say in scope.js:17 and SKILL.md:488 that a staged lock records HEAD, not the index.

#### 🟢 LOW-007: roundNote's new !prior guard has no test: a branch round after only partial rounds

**Domains:** [DevTools] · **Move:** M6
**Location:** `plugins/sdlc/skills/review/bin/review-file.js:363`
**Introduced by:** LOW-003
**Siblings:** none

appendRound now takes prior from the non-partial rounds (review-file.js:371). When every earlier round is a Files /
Folder / Ad-hoc round, which happens when a branch's first review is a Specific Files review, prior is undefined and
only the `!prior ||` guard keeps roundNote from dereferencing it.
At HEAD this works: partial round 1 followed by branch round 2 exits 0, and parse returns
gate1 {open, 2} and partial_rounds [1]. On a copy with `!prior ||` removed, all 137 suite checks still pass, but the
same two renders fail with exit 2 ("Cannot read properties of undefined (reading 'gate_status')"). That would tear
down the first branch round after any partial-only history.

**Recommendation:**
Add one case beside run-review-file-tests.sh:391. Render `clean 8a8a8a8 "$PARTIAL"` into a new file, then
`clean 8a8a8a8` into the same file. Assert render exits 0, the heading is a bare `## Review Round 2`, and
parse gives `o.gate1.state === "open" && o.gate1.round === 2 && JSON.stringify(o.partial_rounds) === "[1]"`.

#### 🟢 LOW-008: Two restatements lag the partial-round fix: merge-conflict stage status has no --skip, and render's header note claim

**Domains:** [DevTools] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/references/round-state.md:59`
**Introduced by:** LOW-003
**Siblings:** `plugins/sdlc/skills/review/bin/review-file.js:16`, `plugins/sdlc/skills/review/references/round-state.md:51`, `plugins/sdlc/skills/review/SKILL.md:383`

(1) The ledger merge-conflict resolver runs `convergence.js status --ledger "{tmp_{stage}}"` without --skip, and its
next branch compares status_2.locked with status_3.locked. Probe: a ledger with rounds 1 and 3 (LOCKED), where round 2
was a partial round, gives locked:true with --skip 2 and locked:false without it.
With equal round counts, a locked stage 3 and a dirty stage 2 both read unlocked, so the resolver keeps 3 and the lock
survives. The rule intends to keep the unlocked side (fail closed). This needs a ledger conflict to reach.
The restore call at round-state.md:70 reads only the exit code, so it is unaffected.
(2) The header at review-file.js:16-17 still says "A Gate 1 round that follows a clean, still-open Gate 1 round is
headed as a confirmation ... or an invalidation". A Files / Folder / Ad-hoc round is a Gate 1 round in the skill
(SKILL.md:386), and roundNote now gives it no note and never takes the note from it. Line 24 of the same header
already says "Gate 1 branch round".

**Recommendation:**
(1) At round-state.md:59, append ` --skip "{session.skip_rounds}"`, as lines 51 and SKILL.md:383 do.
(2) At review-file.js:16-17, write "A branch Gate 1 round that follows a clean, still-open branch Gate 1 round
(Files / Folder / Ad-hoc rounds are skipped and never headed) is headed as ...".

#### 🟢 LOW-009: Commit check still flags git's revert-of-a-revert subject, Reapply "<subject>"

**Domains:** [DevTools] · **Move:** M7
**Location:** `plugins/sdlc/bin/git-conventions.js:71`
**Introduced by:** LOW-017
**Siblings:** `plugins/sdlc/bin/git-conventions.js:31`, `plugins/sdlc/bin/git-conventions.js:70`, `plugins/sdlc/bin/test/fixtures/git-conventions/commits-valid.txt:6`

REVERT_RE accepts only `Revert "<subject>"`, and the comment calls this git's default revert subject. Current git
names the revert of a revert `Reapply "<subject>"` instead of `Revert "Revert "…""`. Reproduced in a temp repo
on git 2.54 (commit, revert, revert again):
`git log --no-merges --format=%s | git-conventions.js commits` returns ok:false, with offender
`Reapply "feat: add f"` and the error "missing `<type>: ` prefix". pull-request then warns and asks about
that commit on every run, which is the noise LOW-017 removed for plain reverts. Rare: it needs a revert that
is later reverted on the same branch.

**Recommendation:**
Accept both of git's generated subjects:
  const REVERT_RE = /^(Revert|Reapply) ".+"$/;   // git revert's default subjects
Add `Reapply "feat: add title search (#42)"` to commits-valid.txt, bump its count check to 7, and update
the header line 31 wording.

#### 🟢 LOW-010: issue_refs drops the line number from ticket-history failures (and still fires on an all-digit hex colour)

**Domains:** [DevTools] · **Move:** none
**Location:** `plugins/sdlc/bin/test/run-skill-structure-tests.sh:35`
**Introduced by:** LOW-016
**Siblings:** `plugins/sdlc/bin/test/run-skill-structure-tests.sh:33`, `plugins/sdlc/bin/test/run-skill-structure-tests.sh:77`, `plugins/sdlc/bin/test/run-pe-agent-tests.sh:46`, `plugins/sdlc/bin/test/run-pe-agent-tests.sh:48`, `plugins/sdlc/bin/test/run-pe-agent-tests.sh:53`, `plugins/sdlc/bin/test/run-pe-agent-tests.sh:59`

LOW-016's fix replaced `grep -noE '#[0-9]{3,}'` with a `tr -c '[:alnum:]#&' '\n' | grep` pipeline. This
loses each match's position. Reproduced by seeding "Since #20 merged." and "Since #517 merged." into a temp
copy:
  - The old guard printed `skills/deliver/SKILL.md:4:#517`.
  - The new one prints `skills/deliver/SKILL.md::#20` and `skills/deliver/SKILL.md::#517`, with no line.
In run-pe-agent-tests.sh, ticket_refs now mixes formats in one failure. The grep half prints
`2:ABC-1790`. The issue_refs half prints the copy's absolute temp path, `/…/mut.X/…/pe-go.md:#20`.
So the operator must search the file by hand to find a flagged reference.
Smaller, same helper: the comment says a hex colour "is not one". An all-digit colour such as #333333 still
fires (`:#333333`). No sdlc doc has one today, and a false positive here fails the test, so nothing is
missed.

**Recommendation:**
Keep grep's line numbers and apply the same boundaries. Both suites carry this helper:
  issue_refs() { grep -noE '(^|[^[:alnum:]&#])#[0-9]{2,}([^[:alnum:]]|$)' "$1" | sed -E 's/:[^#]*#/:#/; s/[^0-9]$//'; }
(or awk with match() for each hit). The output becomes "<line>:#<n>", which fits grep's format and the
`:#(…)$` allowlists. Then change the comment to "a hex colour with a letter (#5319e7)".

#### 🟢 LOW-011: Five of safeRef's eight rules have no test, including the charset rule that keeps shell metacharacters out

**Domains:** [DevTools] · **Move:** M6
**Location:** `plugins/sdlc/bin/git-conventions.js:201`
**Introduced by:** missed
**Siblings:** `plugins/sdlc/bin/git-conventions.js:48`, `plugins/sdlc/bin/git-conventions.js:199`, `plugins/sdlc/bin/test/run-git-conventions-tests.sh:389`, `plugins/sdlc/bin/test/run-git-conventions-tests.sh:391`, `plugins/sdlc/bin/test/run-git-conventions-tests.sh:393`

The ripple receipt says "safeRef rules listed in full and tested". The header now lists all eight rules, but
only three have tests: ".." (../main, main..evil), the leading character (-x) and ".lock". Each of these
mutants passes all 132 checks on a temp copy:
  - `//` dropped
  - `/.` dropped
  - the trailing `/` or `.` rule dropped
  - the 255-character cap dropped
  - the charset widened from `[A-Za-z0-9._/-]*` to `[^\s]*`
The charset rule is the one that keeps `$( )`, quotes and `;` out of a PR baseRefName or sdlc-base config
value. Callers interpolate that value into shell (review's `git fetch origin "{target_branch}"`). A
regression would reopen the round-1 HIGH-004 class with the suite still green. The code is correct
today, so this is a test gap only.

**Recommendation:**
Add one refusal case for each untested rule, beside the existing ones at run-git-conventions-tests.sh:389:
  base_in "$R" --branch 'feat/x;id'   → 2, /"feat\/x;id" is not a plain branch name/
  base_in "$R" --branch 'a//b'        → 2
  base_in "$R" --branch 'feat/.x'     → 2
  base_in "$R" --branch 'feat/x.'     → 2
  base_in "$R" --branch "$(printf 'a%.0s' {1..256})"   → 2
Add one output-side case too: gh_routes 0 '{"baseRefName":"main$(id)"}' → /unsafe base ref/.

#### 🟢 LOW-012: Usage message still ends base's synopsis with '(absent flag → stdin)'; base reads no stdin

**Domains:** [DevTools] · **Move:** M1
**Location:** `plugins/sdlc/bin/git-conventions.js:266`
**Introduced by:** LOW-018
**Siblings:** `plugins/sdlc/bin/git-conventions.js:21`, `plugins/sdlc/bin/git-conventions.js:22`

LOW-018's fix corrected the header (lines 21-23: "`base` reads no stdin: its --branch is an argument"). The
usage string printed on every usage error still ends with `| base [--branch <b>] [--pr <N>] (absent flag →
stdin)`, so the stdin note reads as part of base's synopsis. A caller that follows it and pipes a branch to
base gets the current branch's base instead, with exit 0 and no error. Only seen after a usage error, and
the header is correct.

**Recommendation:**
Attach the note to the subcommands that read stdin, and say base takes only arguments:
  ' | base [--branch <b>] [--pr <N>] (no stdin)' and '(absent --name/--text → stdin)' on branch, key and retype.

#### ℹ️ INFO-001: Phase 2's list of round-state bindings omits session.skip_rounds, which Phase 6 passes to convergence.js record

**Domains:** [Governance] · **Move:** M1
**Location:** `plugins/sdlc/skills/review/SKILL.md:312`
**Introduced by:** LOW-003
**Siblings:** `plugins/sdlc/skills/review/references/round-state.md:3`, `plugins/sdlc/skills/review/references/round-state.md:31`, `plugins/sdlc/skills/review/SKILL.md:383`

SKILL.md:312 lists the values round-state.md binds (review_file through gate1_skip_note). The fix
added session.skip_rounds (round-state.md:31), and SKILL.md:383 reads it, but the list was not
updated. round-state.md runs in order and always binds the value, so nothing breaks at runtime.
The list is now an incomplete contract for anyone tracing where line 383's input comes from.

**Recommendation:**
Add `session.skip_rounds` to the binding list at SKILL.md:312.

#### ℹ️ INFO-002: Convergence signal: round-2 governance findings for the review skill and agents verified at 465b4cc

**Domains:** [Governance] · **Move:** none
**Location:** `docs/code-reviews/feat-sdlc-code-review.md:936`
**Introduced by:** new
**Siblings:** none

Verified fixed at HEAD:
- MEDIUM-001: PRIOR REVIEW / PRIOR LEDGER exempted at dispatch-playbook.md:183,
  pe-protocol.md:29 and dispatch-and-collect.md:205.
- LOW-001: prior_same bound before both guards (publish.md:62).
- LOW-003: gate1Of, partial_rounds, override refusal and --skip in place. convergence.js was run
  with --skip "", "2" and "2,4" on a temp ledger: no false gap, and a lock that survives a Files
  round.
- LOW-004: publish.md:123.
- LOW-005: round-state.md:37, review-store.md:9, README.md:62.
- LOW-006: round-state.md:50.
- LOW-012's doc restatements: pe-governance.md:3 and :24, pe-general-purpose.md:28,
  SKILL.md:217.
- LOW-018's review restatement: SKILL.md:496 now matches git-conventions.js:21-23.
LOW-002 and LOW-022 work under bash but not under zsh (LOW-001 and LOW-002 above). Both are
LOW edge refinements in round-2 themes. This shard has no MEDIUM or higher finding.

**Recommendation:**
Fix LOW-001 and LOW-002 here or in the planned follow-up PR. Nothing in this shard needs
another round.

#### ℹ️ INFO-003: Convergence signal: round-2 findings in this shard verified fixed at 465b4cc

**Domains:** [Governance] · **Move:** none
**Location:** `docs/code-reviews/feat-sdlc-code-review.md:887`
**Introduced by:** new
**Siblings:** none

Verified fixed:
  - HIGH-001: the safe-ref filter now runs before any shell use. The injection names are dropped by
    a regex run, and existing-branch and spike now see only filtered names.
  - MEDIUM-002: fixed for resume and start-over. The fresh-run sibling is MEDIUM-001 above.
  - LOW-007: Phase 3 none guard.
  - LOW-008: headRefOid check. Its over-strict edge is LOW-001.
  - LOW-009: plugin_json matches the marketplace reference.
  - LOW-010: override pathspec commit, proven in a temp repo.
  - LOW-011: checkout failure now STOPs.
  - LOW-018 (deliver part): resolve_base passes --pr.
  - LOW-015 (doc row): matches gh-issues.js:506-511.
Severity in this shard went from 1 HIGH + 1 MEDIUM in round 2 to 1 MEDIUM now. MEDIUM-001 is a
one-line change.

**Recommendation:**
Fix MEDIUM-001 by removing the `session.implement_mode and` guard. Treat the LOWs as awareness.

#### ℹ️ INFO-004: Convergence signal: severity flat at 3 LOW, closed set, nothing in this shard blocks

**Domains:** [DevTools] · **Move:** none
**Location:** `plugins/sdlc/skills/review/bin/review-file.js:1`
**Introduced by:** new
**Siblings:** none

Round 2 had 3 LOW in this shard (LOW-012, LOW-013, LOW-014) and round 3 also has 3 LOW, with no MEDIUM or above.
All three are themes earlier rounds already raised: a partial-scope round counted as a branch round (LOW-003),
a guard with no test (LOW-013), and a restatement that lags its fix (LOW-012). Every round-2 finding for this shard
is verified fixed at 465b4cc by suite and mutation (see prior_findings_verified).
One unverified residual on LOW-014: under Git Bash, MSYS converts POSIX-looking env values, so os.homedir() likely
returns a C:\ path with backslashes. The string-equality and endsWith checks at
run-review-file-tests.sh:470-475 would then still fail on Windows, although nothing is written into the real profile
any more. There is no Windows host to check this on, and CI runs on ubuntu only.

**Recommendation:**
Do not run another round for this shard. Put LOW-001 to LOW-003 in the planned follow-up PR, or accept them.
If Windows contributors matter, compare the --local paths after normalising them
(node -e 'console.log(require("path").resolve(process.argv[1]))'), or use the cygpath helper the build-plan suite already has.

#### ℹ️ INFO-005: Convergence signal: severity falling, closed set (4/4 themes recur), round cap reached for shard B

**Domains:** [DevTools] · **Move:** none
**Location:** `docs/code-reviews/feat-sdlc-code-review.md:887`
**Introduced by:** new
**Siblings:** none

Round 2 had 7 LOW in this shard (LOW-015 to LOW-021) and no HIGH or MEDIUM. Round 3 has 4 LOW and none
gating. Every round-3 theme repeats a round-2 theme: revert subjects (LOW-017), the ticket-history guard
(LOW-016), safeRef tests (LOW-019) and the base contract wording (LOW-018). Each is a last-mile refinement
of a fix that worked.
Fixed at 465b4cc, checked by suite and mutation:
  - LOW-015: an owner refusal before any gh call, naming the owning file.
  - LOW-016: 2+ digit floor, entity and hex-colour exemptions, #42/#57 allowlist, kept in step across both suites.
  - LOW-017: Revert "<subject>" accepted.
  - LOW-018, script side: the header names base --branch as an argument.
  - LOW-019: -x and .lock cases, header lists every rule.
  - LOW-020: suite header names base and SDLC_TEST_TMP.
LOW-021 (UNVERIFIED Copilot overview wording) is unchanged. It still needs a live review body and cannot
be settled from code.

**Recommendation:**
Nothing in this shard blocks merge. Treat LOW-001 to LOW-004 as awareness items for the planned follow-up
PR. Another round on this shard is unlikely to change severity without a scope change.

### Action Items

#### Must Fix (blocks merge)


#### Should Fix

- [ ] MEDIUM-001: fix `plugins/sdlc/skills/deliver/SKILL.md:242` + 3 siblings

#### Consider

- [ ] LOW-001: fix `plugins/sdlc/skills/review/references/ci-gate.md:13` + 4 siblings
- [ ] LOW-002: fix `plugins/sdlc/agents/pe-sql-server.md:36` + 3 siblings
- [ ] LOW-003: fix `plugins/sdlc/skills/review/SKILL.md:440` + 2 siblings
- [ ] LOW-004: fix `plugins/sdlc/skills/deliver/SKILL.md:459` + 0 siblings
- [ ] LOW-005: fix `plugins/sdlc/skills/implement/references/existing-branch.md:5` + 3 siblings
- [ ] LOW-006: fix `plugins/sdlc/skills/review/bin/scope.js:181` + 7 siblings
- [ ] LOW-007: fix `plugins/sdlc/skills/review/bin/review-file.js:363` + 0 siblings
- [ ] LOW-008: fix `plugins/sdlc/skills/review/references/round-state.md:59` + 3 siblings
- [ ] LOW-009: fix `plugins/sdlc/bin/git-conventions.js:71` + 3 siblings
- [ ] LOW-010: fix `plugins/sdlc/bin/test/run-skill-structure-tests.sh:35` + 6 siblings
- [ ] LOW-011: fix `plugins/sdlc/bin/git-conventions.js:201` + 5 siblings
- [ ] LOW-012: fix `plugins/sdlc/bin/git-conventions.js:266` + 2 siblings
- [ ] INFO-001: fix `plugins/sdlc/skills/review/SKILL.md:312` + 3 siblings
- [ ] INFO-002: fix `docs/code-reviews/feat-sdlc-code-review.md:936` + 0 siblings
- [ ] INFO-003: fix `docs/code-reviews/feat-sdlc-code-review.md:887` + 0 siblings
- [ ] INFO-004: fix `plugins/sdlc/skills/review/bin/review-file.js:1` + 0 siblings
- [ ] INFO-005: fix `docs/code-reviews/feat-sdlc-code-review.md:887` + 0 siblings

### Merge Eligibility

**Locked to SHA:** `465b4ccaebdae0ff3ef9285ed19044a4809449fa`
**Status:** ⚠️ Not mergeable — 0 HIGH and 1 MEDIUM findings open. Any commit after this SHA requires re-review.

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
