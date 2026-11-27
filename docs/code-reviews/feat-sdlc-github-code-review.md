# Code Review: feat-sdlc-github

**Verdict:** 🚫 BLOCKED

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

🤖 Generated with [Claude Code](https://claude.com/claude-code)
