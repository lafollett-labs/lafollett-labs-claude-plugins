# Code Review: feat-github-actions-release

**Verdict:** ✅ APPROVED (round 6)

| | |
| - | - |
| **Branch** | `feat/github-actions-release` |
| **PR** | [#21](https://github.com/lafollett-labs/lafollett-labs-claude-plugins/pull/21) |
| **Author** | @clafollett |
| **Reviewer** | Claude Code (`/code-reviewer` 2.14.1) for Cali LaFollett |
| **Review Round** | 1 |
| **Reviewed SHA** | `e073e6aea8d46a955716b61d3fcc4adad78d7160` |
| **Title** | ci: stamp versions on release, scan secrets, lint shell |
| **Files Changed** | 105 (81 synthetic test fixtures) |
| **Lines Changed** | +3280 / -37 |
| **Date** | 2026-11-26 |

---

## Summary

The PR moves version stamping into a release workflow: a bot release PR stamps the plugins, merges, and tags. It also adds gitleaks, shellcheck, the scripts/ci and plugin suites, a conventional-title check, and optional local hooks. The engine and orchestrator are well tested. CI was green on all 5 jobs at the reviewed SHA.

Four MEDIUM findings block:
- Only `manifests • skills` is required, so the new gates are advisory.
- A re-run after a failed dispatch never re-dispatches CI.
- The local pre-commit hook blocks every commit once HEAD's message hits the private denylist.
- The hook honours `gitleaks:allow` and `.gitleaksignore`, which CI refuses.

The remaining LOW and INFO findings are wording in CLAUDE.md, warnings in the orchestrator, the allow-list validator's coverage, and two tests that cannot fail.

Routing:
- `.github/workflows/**`, `scripts/ci/**` and `.gitleaks.toml` → pe-aws-infra, as production CI primitives.
- `scripts/hooks/**` → pe-devtools, single-operator.
- `CLAUDE.md` → pe-governance.
- Human docs → Primary.

---

## Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-AWS-Infra | none | none — TEST BUDGET none (no Stack Map test command); suites and a mutation probe run under M6 |
| PE-Governance | none | none |
| PE-DevTools | lint-only | default shellcheck clean on both hooks; both mode 100755 |
| Primary | — | CI on PR #21 at `e073e6a`: conventional title, gitleaks, manifests • skills, shellcheck, test suites all green |

---

## Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-AWS-Infra | 6 contracts → producers/consumers (metadata.version 5 readers, release subject 2→4, Base trailer, fragment rule, level table, required check); 0 stale hand-bump restatements | release state machine seed→reconcile→stamp→push→PR→dispatch→merge→wait; activation run, re-run, main moving, missed merge, closed PR, branch delete, concurrency | plan over 6 log shapes; tunables; 3 CHANGELOG shapes; fragment shapes; shellcheck discovery | check-pr rename + version edit; allow-list validator × 3 TOML spellings on real gitleaks 8.30.1 (2 bypass); permissions; branch protection + 2 rulesets read; pr-title guard; fork token | ~30 die/`\|\|` paths in run-release.sh; check-pr unreadable/absent file; missing binary; gh failure in wait | 5 suites; 1 mutation (release filter removed → same output); 1 hand-traced test that cannot fail | GITHUB_TOKEN trigger rules; 4 repo settings via gh api; no tags/releases/tag rulesets; unattributed-changes key is Copilot-only; gitleaks allow-list semantics; 1 UNVERIFIED |
| PE-Governance | 6 changed rules + hooks line → 13 restatements (CONTRIBUTING ×5, README ×4, changelog.d ×2, CHANGELOG ×1, pe-governance ×1); 0 stale in plugins/** | release lifecycle; CHANGELOG writer; debut over two PRs; 0 in-flight PRs on the old rule | 8 PR shapes through the rule (non-plugin, marketplace-only, new, removed, multi-plugin, 1 vs many commits, intermediate `!`, `/` in branch) | 4 guards vs the CLAUDE.md claims (version loop not plugin-gated, fragment gate, CHANGELOG unguarded, title check not required) | rules give feedback only from CI; hooks check neither rule | 4 tests behind the claims, each fails with its guard removed | ruleset squash-only; squash title/message settings; table vs commitLevel; marketplace line vs plan; hooks vs their bodies; separators |
| PE-DevTools | 4 contracts → 8 restatements; secret-scan.sh sibling diffed (2 guards missing) | index, HEAD message, COMMIT_EDITMSG, config through amend, `--no-verify` history, editor/-m/-v | 7 inputs in a temp repo (no gitleaks, pre-v8.19 stub, `~` path, missing scanner, message flows, initial commit) | gitleaks hook vs inline allow and `.gitleaksignore`; scanner over-match on HEAD message and on `#` comments / -v diff | gitleaks exit 1 / 126 / 1 all read as "secret"; unset config path correct | n/a — no test added or changed; the hooks have no suite | 7 claims (flags vs `gitleaks git --help`, config precedence, v8.19.0 `git` subcommand, 3 header/message claims, scanner output shape) |
| Primary | 3 changed rules → README ×4, CONTRIBUTING ×5, changelog.d/README ×2, CHANGELOG header ×1 vs version-stamp.js and check-pr.sh (1 drift) | hand-written `[1.34.1]` heading → seed tag v1.34.1 → first automated entry prepended above it (ran changelog-release on a copy) | changelog.d/README example fragment through changelog-release: 2 kinds rendered, debut tagged `(new)` | n/a — no guard in the human docs | n/a — human docs make no call | n/a — no test in the human docs | README.md:107 vs plugin-janitor docs (1 false); CONTRIBUTING levels vs commitLevel; CHANGELOG header vs changelog-release output |

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 4 | 0 |
| 🟢 LOW | 18 | 0 |
| ℹ️ INFO | 4 | 2 |

---

## In Scope Findings

### 🟡 MEDIUM-001: The new gates are advisory: only `manifests • skills` is required, and the release PR auto-merges on it alone

**Domains:** [CI, Security] · **Move:** M4
**Location:** `.github/workflows/ci.yml:202`
**Siblings:** `.github/workflows/ci.yml:177`, `.github/workflows/ci.yml:221`, `.github/workflows/pr-title.yml:13`, `CLAUDE.md:33`, `CONTRIBUTING.md:14`, `CONTRIBUTING.md:18`

Branch protection requires only `manifests • skills`, and neither ruleset adds a status check. As a result:
- The bot release PR (`run-release.sh:239`, `--auto --squash`) merges once that check passes, even with `gitleaks` or `test suites` red or still running.
- A human PR that breaks `run-release.sh` can merge with `test suites` red. `release.yml` runs only the unit suite before it writes with contents, pull-requests and actions write.
- Nothing enforces the conventional-title rule.

Requiring `conventional title` naively would deadlock: the release PR is opened with GITHUB_TOKEN, so `pr-title.yml` never runs on it.

**Recommendation:** Enforce every gate through the existing required check, or add the contexts to branch protection (a setting change). Move the title check into `ci.yml` as a PR-only job so the release PR's dispatch run skips it.

---

### 🟡 MEDIUM-002: A re-run after a failure between push and dispatch never dispatches CI, so the release PR stalls while the run reports green

**Domains:** [CI] · **Move:** M2
**Location:** `scripts/ci/release/run-release.sh:234`
**Siblings:** `scripts/ci/release/run-release.sh:207`, `scripts/ci/release/test/run-release-integration-tests.sh:175`, `.github/workflows/release.yml:8`

CI is dispatched only when this run pushed. If run 1 pushes the stamp and then dies at `open_pr` or `gh workflow run`, a re-run on the same main finds the identical stamp and sets `pushed=no`. It opens or edits the PR but never dispatches. The required check never reports on the head, auto-merge waits forever, and the run exits 0 after the wait. The integration case "rerun: no dispatch" asserts this behaviour.

**Recommendation:** Dispatch on every run that reaches the PR step, and flip the integration case to assert one dispatch per run.

---

### 🟡 MEDIUM-003: pre-commit calls the scanner's no-argument mode, which also scans HEAD's message, so one hit there blocks every commit, `--amend` included

**Domains:** [DevTools] · **Move:** M2
**Location:** `scripts/hooks/pre-commit:15`
**Siblings:** `scripts/hooks/pre-commit:2`, `scripts/hooks/commit-msg:8`

With no arguments, the configured scanner checks the staged diff and also `git log -1`. Suppose HEAD's message carries a denylisted term, from a `--no-verify` commit, a commit made before the hooks were enabled, or a pulled commit. Then every later commit fails, including the `--amend -m` that would fix the message: pre-commit runs before the new message exists. The only way out is `--no-verify`, which also disables gitleaks. The hook's message also blames "the staged diff". commit-msg already scans every new message.

**Recommendation:** Pass pre-commit's scanner only the staged diff's added lines, as a file, and leave the message to commit-msg.

---

### 🟡 MEDIUM-004: The local gitleaks hook accepts inline `gitleaks:allow` and `.gitleaksignore`, which CI rejects, so a commit passes locally and fails after it is public

**Domains:** [DevTools, Security] · **Move:** M1
**Location:** `scripts/hooks/pre-commit:9`
**Siblings:** `scripts/hooks/pre-commit:10`, `scripts/ci/security/secret-scan.sh:9`, `scripts/ci/security/secret-scan.sh:52`, `scripts/ci/security/secret-scan.sh:57`, `scripts/ci/security/secret-scan.sh:61`, `.gitleaks.toml:8`

`secret-scan.sh` passes `--ignore-gitleaks-allow` and refuses any `.gitleaksignore`. The hook does neither. Verified in a temp repo: a staged PAT-shaped value with an inline allow comment committed cleanly. A root `.gitleaksignore` also silenced the hook.

**Recommendation:** Add `--ignore-gitleaks-allow` to the hook and its rerun hint, and refuse a `.gitleaksignore` before scanning, as `secret-scan.sh:52-53` does.

---

### 🟢 LOW findings

| ID | Move | Location | Finding | Siblings |
| - | - | - | - | - |
| LOW-001 | M5 | `scripts/hooks/pre-commit:9` | Every gitleaks failure is reported as "found a secret", with output discarded: exit 1 for an unknown subcommand, 126 for a bad flag, 1 for a bad config. Downgraded from MEDIUM: the hinted rerun shows the real error in one command | `scripts/hooks/pre-commit:10`, `scripts/hooks/pre-commit:15`, `scripts/hooks/commit-msg:8` |
| LOW-002 | M3 | `scripts/hooks/pre-commit:8` | With no gitleaks on PATH (common for GUI git clients), the scan is skipped silently and the hook exits 0 | `scripts/hooks/pre-commit:2`, `CONTRIBUTING.md:21` |
| LOW-003 | M3 | `scripts/hooks/pre-commit:12` | `labs.denylistScan` is read without `--type=path`, so `~/…` and a missing file both report "not executable" | `scripts/hooks/commit-msg:5`, `scripts/hooks/commit-msg:7` |
| LOW-004 | M4 | `scripts/hooks/commit-msg:8` | commit-msg scans the raw message file, including git's `#` comments and the `-v` diff, so a commit that removes a term can be blocked | `scripts/hooks/commit-msg:2` |
| LOW-005 | M5 | `scripts/ci/release/run-release.sh:242` | An auto-merge enable failure and the wait timeout are plain log lines, so a stalled release looks green; `release.yml` does not list `allow_auto_merge` as a need | `scripts/ci/release/run-release.sh:260`, `.github/workflows/release.yml:7` |
| LOW-006 | M7 | `scripts/ci/release/run-release.sh:79` | UNVERIFIED: GITHUB_TOKEN tag pushes onto a commit whose workflows differ from main's may be refused. The seed tag at main^1 predates this PR's workflows. Creating tags through the REST refs API avoids it | `scripts/ci/release/run-release.sh:119`, `scripts/ci/release/run-release.sh:217` |
| LOW-007 | M4 | `scripts/ci/release/run-release.sh:107` | A human PR squash-titled `chore(release): vX` wedges reconcile permanently; plan() also drops its plugin changes | `scripts/ci/release/version-stamp.js:67`, `scripts/ci/release/version-stamp.js:140`, `.github/workflows/pr-title.yml:30` |
| LOW-008 | M4 | `scripts/ci/security/secret-scan.sh:27` | The allow-list validator misses a TOML dotted key (`allowlist.paths = […]`) and accepts `regexes = ['''.*''']`; both clear secrets on real gitleaks 8.30.1 | `.gitleaks.toml:3`, `.gitleaks.toml:8`, `scripts/ci/security/secret-scan.sh:8`, `scripts/ci/security/secret-scan.sh:24`, `scripts/ci/security/test/run-secret-scan-tests.sh:190` |
| LOW-009 | M4 | `.github/workflows/ci.yml:114` | UNVERIFIED: a write-access user can dispatch ci.yml on a PR branch and get `manifests • skills` green without check-pr | `.github/workflows/ci.yml:7` |
| LOW-010 | M6 | `scripts/ci/release/test/run-release-unit-tests.sh:122` | "release commits in range are ignored" passes with the filter removed | none |
| LOW-011 | M6 | `scripts/ci/release/test/run-release-integration-tests.sh:248` | Test 12 ("a non-numeric wait exits 1") cannot fail: test 11's spoofed release commit exits 1 anyway | none |
| LOW-012 | M3 | `CLAUDE.md:30` | The conventional-title and version-ban lines sit under `on ANY edit under plugins/`, but both apply to every PR | `CONTRIBUTING.md:9`, `CONTRIBUTING.md:14`, `.github/workflows/pr-title.yml:5`, `scripts/ci/check-pr.sh:35`, `scripts/ci/release/version-stamp.js:147` |
| LOW-013 | M1 | `CLAUDE.md:45` | "everything else is `fix` or `chore`" contradicts the table's `docs`/`refactor`/`test` row | `CLAUDE.md:41`, `CONTRIBUTING.md:7`, `CONTRIBUTING.md:12`, `CONTRIBUTING.md:17`, `README.md:106` |
| LOW-014 | M7 | `CLAUDE.md:42` | The BREAKING CHANGE row does not say the footer must sit in a commit message; a PR-description footer never reaches the engine (squash message = COMMIT_MESSAGES) | `scripts/ci/release/version-stamp.js:73`, `.github/workflows/pr-title.yml:41`, `CONTRIBUTING.md:17`, `README.md:106` |
| LOW-015 | M2 | `CLAUDE.md:25` | The rule never says not to edit CHANGELOG.md; a hand-added `[Unreleased]` gets stranded below every future release | `CHANGELOG.md:3`, `changelog.d/README.md:14`, `CONTRIBUTING.md:18`, `scripts/ci/release/version-stamp.js:273` |
| LOW-016 | M1 | `CLAUDE.md:27` | "a branch never edits one" is absolute, yet a new plugin's branch authors its version | `CLAUDE.md:31`, `CONTRIBUTING.md:16`, `changelog.d/README.md:17`, `README.md:104`, `README.md:109` |
| LOW-017 | M1 | `CLAUDE.md:47` | The hooks line sits under the versions HARD RULE as an order; the hooks are optional and check neither rule | `CONTRIBUTING.md:21`, `README.md:81`, `scripts/hooks/pre-commit:1` |
| LOW-018 | M7 | `README.md:107` | "(which is what `/plugin marketplace update` compares)" contradicts plugin-janitor's account that each plugin's own version is compared | none |

### ℹ️ INFO findings

| ID | Move | Location | Finding | Siblings |
| - | - | - | - | - |
| INFO-001 | M7 | `scripts/ci/test/run-validate-manifests-tests.sh:3` | The header claims CI runs this under Alpine busybox sh; CI runs it with bash on ubuntu-latest | none |
| INFO-002 | M7 | `CLAUDE.md:44` | The marketplace-level sentence describes the engine but gives no instruction; a removal needs `type!:` | `scripts/ci/release/version-stamp.js:123`, `scripts/ci/release/version-stamp.js:147`, `scripts/ci/release/version-stamp.js:167` |
| INFO-003 | M5 | `CLAUDE.md:31` | No local check is named; `bash scripts/ci/check-pr.sh origin/main HEAD` runs locally | `scripts/ci/check-pr.sh:2` |
| INFO-004 | M3 | `CLAUDE.md:38` | The squash level applies to every plugin the PR touches; the rule does not say so | `scripts/ci/release/version-stamp.js:150`, `CONTRIBUTING.md:8` |

---

## Out of Scope

| Severity | Issue | Location |
| - | - | - |
| ℹ️ INFO | The private scanner (outside the repo) prints `<line>:<text>` instead of `file:line` when given one file; passing `/dev/null` as a second argument forces the filename prefix | `scripts/hooks/commit-msg:8` |
| ℹ️ INFO | The Structure tree lists 5 plugins; the repo ships 7 (plugin-janitor and watchwith are missing) | `CLAUDE.md:13` |

---

## Action Items

### Must Fix (blocks merge)

None.

### Required

- [ ] MEDIUM-001: fix `.github/workflows/ci.yml:202` + 6 siblings
- [ ] MEDIUM-002: fix `scripts/ci/release/run-release.sh:234` + 3 siblings
- [ ] MEDIUM-003: fix `scripts/hooks/pre-commit:15` + 2 siblings
- [ ] MEDIUM-004: fix `scripts/hooks/pre-commit:9` + 6 siblings

### Optional

- [ ] LOW-001 … LOW-018 and INFO-001 … INFO-004: each at its location + the siblings listed above

---

## Files Reviewed

| File | Findings |
| - | - |
| `.github/workflows/ci.yml` | 2 |
| `.github/workflows/pr-title.yml` | 0 (siblings only) |
| `.github/workflows/release.yml` | 0 (siblings only) |
| `.gitleaks.toml` | 0 |
| `CHANGELOG.md` | 0 |
| `CLAUDE.md` | 9 |
| `CONTRIBUTING.md` | 0 (siblings only) |
| `README.md` | 1 |
| `changelog.d/README.md` | 0 |
| `docs/notes/agentic-engineering-humanlayer.md` | 0 |
| `scripts/ci/check-pr.sh` | 0 |
| `scripts/ci/release/run-release.sh` | 4 |
| `scripts/ci/release/version-stamp.js` | 0 (siblings only) |
| `scripts/ci/release/test/run-release-unit-tests.sh` | 1 |
| `scripts/ci/release/test/run-release-integration-tests.sh` | 1 |
| `scripts/ci/run-shell-tests.sh` | 0 |
| `scripts/ci/security/install-gitleaks.sh` | 0 |
| `scripts/ci/security/secret-scan.sh` | 1 |
| `scripts/ci/security/test/run-secret-scan-tests.sh` | 0 |
| `scripts/ci/test/run-check-pr-tests.sh` | 0 |
| `scripts/ci/test/run-validate-manifests-tests.sh` | 1 |
| `scripts/ci/validate-manifests.js` | 0 |
| `scripts/hooks/pre-commit` | 5 |
| `scripts/hooks/commit-msg` | 1 |
| 81 synthetic fixtures under `scripts/ci/**/fixtures/` | 0 |

---

## Merge Eligibility

**Locked to SHA:** `171a7872dd889a50b625b58465f3329bce3cbfc2` (round 6)
**Status:** ✅ Mergeable IF the branch head is `171a7872dd889a50b625b58465f3329bce3cbfc2` plus only this review doc. Any other commit after it invalidates this round and requires re-review (`/code-reviewer` again before merge).

---

## Review Round 2

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | Claude Code (`/code-reviewer` 2.14.1) for Cali LaFollett |
| **Reviewed SHA** | `7840f9dad5dfcf388cf3dc09bff919f8ad9ec882` |
| **Date** | 2026-11-26 |
| **Fix cascade** | 15 / 20 in-scope findings introduced by a prior fix |
| **Ripple receipts** | 8 spot-checked |

### Summary

All 4 MEDIUM findings from round 1 are closed:
- `manifests • skills` now waits on every other job.
- Every release run dispatches CI.
- pre-commit gives the scanner only the staged paths and added lines.
- The hook uses CI's gitleaks flags.

Each fix was checked against the pre-fix code: the new cases fail there (hooks 15, orchestrator 6, validator 7, engine 1).

Round 2 found no CRITICAL, HIGH or MEDIUM. 15 of the 20 LOW and INFO findings are edge cases of round-1 fixes, so the set is converging. Notable ones:
- The title gate can be skipped by a hand dispatch.
- The validator still accepts some match-anything spellings and `[extend] path`.
- The gate step itself has no test.
- commit-msg skips `#` lines that `-m` keeps.

CI was green on all 5 jobs at the reviewed SHA (run 45907086907).

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-AWS-Infra | none | none — TEST BUDGET none; scratch configs on real gitleaks 8.30.1, a ci.yml mutation and actionlint ran under M4/M6 |
| PE-Governance | none | none |
| PE-DevTools | lint-only | run-hooks-tests.sh 21/21; 15 mutants, 13 killed |
| Primary | — | CI run 45907086907 at `7840f9d`: all 5 jobs green; the gate step listed every need as ok; 6 suites, hooks 21/21 on Ubuntu |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-AWS-Infra | 6 of 8 receipts spot-checked against their restatements, 0 disagree; 1 unreceipted rule; 2 fix siblings (LOW-001, LOW-005) | dispatch fail → rerun; main moving under an open release PR; API tag then local tag failing; look-alike vs a trailer-less real release; edited cancelling a run | gate step × 7 NEEDS shapes; check-pr `if:` × 5 sources; trailer regex vs sed; title gate 1 vs many commits | 12 scratch configs on real gitleaks (5 got through); title gate vs dispatch; required-check app pin; env-only expression inputs | create_tag, dispatch, auto-merge, wait timeout, gate jq, title engine | 2 unit + 3 integration + 10 shape cases fail when their fix is reverted; gate-step deletion survives the wiring tests (LOW-004) | skipped-required semantics; `cancelled()`; refs API with GITHUB_TOKEN; GH_REPO; repo settings; CI time vs wait; 1 UNVERIFIED |
| PE-Governance | 9 prior findings + 1 out-of-scope all resolved; 1 receipt (8 restatements agree); 7 unreceipted rules grepped (1 drift) | bootstrap order of the CHANGELOG move; squash-subject source as the commit count changes | 10 PR shapes through the rule (1 gap) | 3 "CI fails" claims vs their guards (check-pr false clean without node) | pre-push line exit paths; unset `labs.denylistScan` | n/a — no test in the CLAUDE.md diff | 7 claims (COMMIT_OR_PR_TITLE, footer shape on 2 real squashes, marketplace major, per-plugin level, hooks, tree count, separators) |
| PE-DevTools | 6 prior findings closed (each by suite + killed mutant); hook receipt spot-checked (1 overclaim); 3 unreceipted fix rules agree; pre-commit vs secret-scan.sh (1 guard missing) | temp files through hit/clean/early exit/Ctrl-C; amend; `commit -a` / `commit <path>`; `--no-verify` HEAD; unborn; concurrent commits | -m / -F / editor / -v; `core.commentChar`; renamed, deleted, non-ASCII paths; `~/` and `~user/`; no gitleaks; empty commit | 6 guards: `.gitleaksignore`, `--ignore-gitleaks-allow`, working-tree allow-list, awk header skip, `--diff-filter=d`, scissors + strip | gitleaks exits 0/3/126/1; git config 1 vs 128; scanner non-zero; mktemp | 21 checks; 15 mutants, 2 survive (LOW-012, LOW-013) | 9 claims (exit codes, hint, cleanup default, `~user`, BSD sed, CI parity, `/dev/null` comment, v8.19, header) |
| Primary | 8 receipted rules vs CONTRIBUTING, README, changelog.d/README, CHANGELOG header: all agree | n/a — human docs hold no state | the local check command in a fork clone (INFO-006) | n/a — no guard in the human docs | n/a — human docs make no call | n/a — no test in the human docs | CONTRIBUTING "CI fails … non-conventional title" vs the title job + gate; README tree vs workflows |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 14 | 0 |
| ℹ️ INFO | 6 | 0 |

### In Scope Findings

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| LOW-001 | M4 | `.github/workflows/ci.yml:200` | MEDIUM-001 | A hand `workflow_dispatch` on a PR branch makes the required check green with the title gate skipped | `.github/workflows/ci.yml:10`, `.github/workflows/ci.yml:189`, `.github/workflows/ci.yml:212`, `CONTRIBUTING.md:20` |
| LOW-002 | M4 | `scripts/ci/security/secret-scan.sh:51` | still-present | The validator still accepts match-anything regexes (`^\S*`, `^[\s\S]*`, `^(?:.)*`) and any stopword (e.g. `ghp_`), each clearing every secret in the named file | `scripts/ci/security/secret-scan.sh:47`, `scripts/ci/security/secret-scan.sh:24`, `.gitleaks.toml:3`, `.gitleaks.toml:7`, `scripts/ci/security/test/run-secret-scan-tests.sh:198`, `scripts/ci/security/test/run-secret-scan-tests.sh:199` |
| LOW-003 | M4 | `scripts/ci/security/secret-scan.sh:42` | missed | `[extend] path` loads a second config the validator never reads; a legacy directory allow-list there clears secrets | `.gitleaks.toml:13`, `.gitleaks.toml:9`, `scripts/ci/security/secret-scan.sh:8` |
| LOW-004 | M6 | `scripts/ci/security/test/run-secret-scan-tests.sh:209` | MEDIUM-001 | The wiring tests pass with the "Every other gate passed" step deleted; no test runs the gate logic | `.github/workflows/ci.yml:188`, `.github/workflows/ci.yml:33`, `.github/workflows/ci.yml:196` |
| LOW-005 | M7 | `scripts/ci/release/run-release.sh:228` | LOW-006 | UNVERIFIED: the release/next force-push is still a GITHUB_TOKEN git push and may be refused after main gains a workflow change; no recovery is stated | `scripts/ci/release/run-release.sh:70`, `scripts/ci/release/run-release.sh:217` |
| LOW-006 | M7 | `CLAUDE.md:48` | LOW-014 | A single-commit PR squashes under its commit subject, so `type!:` only in the title never reaches the engine; title and commit may disagree | `CLAUDE.md:32`, `CLAUDE.md:41`, `CLAUDE.md:44`, `.github/workflows/ci.yml:210`, `.github/workflows/ci.yml:241`, `.github/workflows/ci.yml:244`, `CONTRIBUTING.md:14`, `CONTRIBUTING.md:18`, `README.md:105` |
| LOW-007 | M5 | `scripts/ci/check-pr.sh:32` | missed | Without node on PATH, check-pr reads both versions as `<unreadable>` and reports clean | `CLAUDE.md:33`, `CONTRIBUTING.md:21`, `scripts/ci/check-pr.sh:12` |
| LOW-008 | M3 | `scripts/hooks/commit-msg:10` | LOW-004 | commit-msg strips `#` lines that `-m` / `-F` commits keep, so a term on such a line commits unscanned; the scissors pattern ignores `core.commentChar` | `scripts/hooks/commit-msg:2`, `scripts/hooks/commit-msg:3`, `scripts/ci/test/run-hooks-tests.sh:125` |
| LOW-009 | M1 | `scripts/hooks/pre-commit:4` | MEDIUM-004 | The header says the gitleaks scan matches CI's, but the hook skips CI's allow-list shape check and reads the working-tree config | `scripts/hooks/pre-commit:17`, `scripts/ci/security/secret-scan.sh:8`, `scripts/ci/security/secret-scan.sh:28`, `.gitleaks.toml:9` |
| LOW-010 | M3 | `scripts/hooks/pre-commit:34` | MEDIUM-003 | Staged paths reach the scanner octal-quoted (`core.quotePath`), so a non-ASCII term in a filename is missed | none |
| LOW-011 | M5 | `scripts/hooks/pre-commit:39` | MEDIUM-003 | A denylist hit gives no usable location: the scanner's file:line names a deleted temp file | `scripts/hooks/pre-commit:38`, `scripts/hooks/pre-commit:40`, `scripts/hooks/commit-msg:11`, `scripts/hooks/commit-msg:12` |
| LOW-012 | M6 | `scripts/ci/test/run-hooks-tests.sh:107` | LOW-003 | No test reaches commit-msg's `~` resolution or its missing-scanner message (pre-commit exits first) | `scripts/ci/test/run-hooks-tests.sh:109`, `scripts/hooks/commit-msg:5`, `scripts/hooks/commit-msg:7` |
| LOW-013 | M6 | `scripts/ci/test/run-hooks-tests.sh:89` | LOW-001 | The gitleaks-failure stub exits 126; real config errors exit 1, so a mutant that again reads 1 as "secret" survives | `scripts/ci/test/run-hooks-tests.sh:92`, `scripts/hooks/pre-commit:17`, `scripts/hooks/pre-commit:21` |
| LOW-014 | M1 | `scripts/ci/test/run-hooks-tests.sh:1` | new | The new suite is committed 100644; every sibling suite is 100755 | none |

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| INFO-001 | M2 | `scripts/ci/release/run-release.sh:114` | LOW-007 | A real release squash whose message was edited to drop the `Base:` trailer is skipped, and the next stamp bumps its plugins again | `scripts/ci/release/version-stamp.js:93`, `scripts/ci/release/version-stamp.js:147`, `scripts/ci/release/version-stamp.js:270` |
| INFO-002 | M7 | `CLAUDE.md:27` | LOW-017 | The hooks line implies `core.hooksPath` alone runs the denylist scan; it also needs `labs.denylistScan` | `scripts/hooks/pre-commit:7`, `scripts/hooks/pre-commit:29`, `scripts/hooks/commit-msg:6`, `CONTRIBUTING.md:23` |
| INFO-003 | none | `scripts/hooks/pre-commit:1` | new | Convergence signal: severity falling, round-2 hook findings are edge cases of round-1 fixes | none |
| INFO-004 | M5 | `scripts/hooks/pre-commit:29` | LOW-003 | A `~user/` typo makes `git config --type=path` exit 128, which `\|\| true` reads as unset, so the scan turns off | `scripts/hooks/commit-msg:5` |
| INFO-005 | M7 | `scripts/hooks/pre-commit:22` | LOW-001 | "it needs v8.19+" blames the version for a broken config too | none |
| INFO-006 | M3 | `CLAUDE.md:33` | INFO-003 | In a fork, `origin/main` is the fork's main; a stale fork makes `check-pr.sh origin/main HEAD` blame upstream release bumps on the branch | `CONTRIBUTING.md:21` |

### Action Items

#### Must Fix (blocks merge)

None.

#### Should Fix

None.

#### Consider

- [ ] LOW-001 … LOW-014 and INFO-001 … INFO-006: each at its location + the siblings listed above

---

## Review Round 3

> 🚫 PRIOR ROUND INVALIDATED — re-reviewing post-approval changes

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | Claude Code (`/code-reviewer` 2.14.1) for Cali LaFollett |
| **Reviewed SHA** | `e3dc826e76eb67948271c7bada426ee5555c8084` |
| **Date** | 2026-11-26 |
| **Fix cascade** | 9 / 12 in-scope findings introduced by a prior fix |
| **Ripple receipts** | 8 spot-checked |

### Summary

Round 2 was approved at `7840f9d`, and its LOW and INFO findings were then fixed. Of round 2's 20 findings:
- 17 are closed.
- LOW-003 is closed only for the literal `[extend]` spelling (now LOW-001).
- INFO-001 is still present (now INFO-003).
- INFO-003 was a convergence note.

What the fixes did:
- The required check's gate step and the title gate moved into tested scripts (`scripts/ci/gate-needs.sh`, `scripts/ci/check-title.sh`).
- The allow-list validator now takes one regex of 8+ literal characters, refuses stopwords, and allows only `useDefault = true` under `[extend]`.
- The hook edge cases are closed.
- Each new case fails against the pre-fix code or a mutant of the fix.

Round 3 found no CRITICAL, HIGH or MEDIUM. 9 of the 12 LOW and INFO findings are edge cases of round-2 fixes. Notable ones:
- The validator recognizes `[extend]` in only one spelling; inline, spaced or quoted forms still load a second config (LOW-001).
- A `[[rules]]` entry that reuses a default rule's id switches that rule off (LOW-002).
  Both take a reviewed `.gitleaks.toml` edit.
- commit-msg strips comment lines that a non-default `commit.cleanup` keeps (LOW-003).

CI was green on all 5 jobs at the reviewed SHA (run 45911712401). This is the last round under the 3-round cap.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-AWS-Infra | none | none — TEST BUDGET none. Read CI run 45911712401: gate-needs 14/14, check-title 17/17, secret-scan 52/52, check-pr 16/16, hooks 27/27. Under M4/M6: 16 scratch configs on real gitleaks 8.30.1, 7 gate-needs / check-title mutants (all killed), actionlint clean |
| PE-Governance | none | none |
| PE-DevTools | lint-only | run-hooks-tests.sh 27/27 locally and on Ubuntu CI; 12 mutants: 8 killed, 2 equivalent, 2 survive (LOW-005); shellcheck clean; all 3 files 100755 |
| Primary | — | CI run 45911712401 at `e3dc826`: all 5 jobs green, 8 suites, every need ok in the gate step, and the title job printed the release level |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-AWS-Infra | 6 of 8 receipts spot-checked, 0 disagree; the new `[extend]` guard vs the spelling-robust allowlist guard (LOW-001); disabledRules vs a same-id rule override (LOW-002); 7 round-2 findings checked | gate and title logic moved into PR-checkout scripts (same trust as inline ci.yml); check-title temp body + EXIT trap; push refusal → red run; reconcile on a trailer-less squash (INFO-003) | gate-needs × 6 event/ref pairs + array and result-less NEEDS; check-title × hyphen footer, footer after a trailer, empty REPO, release subject as a lone commit | 16 configs on real gitleaks: 5 `[extend]` spellings and 2 rule overrides got through (LOW-001, LOW-002); a wildcard path + prefix regex accepted (INFO-001); a stopword under AND only narrows | gate-needs: no jq, non-object, wrong count, unknown result; check-title: no node, git log, level failure; push refusal; check-pr without node | 7 mutants all killed; wiring tests catch a deleted gate step and EXPECT drift; the stopword case survives deleting its own refusal (INFO-002) | squash settings via gh api; gitleaks AND semantics; extend.path vs useDefault; "one exact value in one file" (INFO-001); push recovery still unverified on GitHub; actionlint |
| PE-Governance | 4 receipts spot-checked, all restatements agree; CONTRIBUTING.md:18 keep holds; LOW-006, INFO-002, INFO-006 closed | squash-message source as the commit count moves 1 ↔ many across force-pushes; a retitle re-runs the gate via `edited` | line 32 × 6 commit shapes; line 33 × 3 clone layouts; line 27 × unset / set / missing scanner — no gap | 4 one-commit shapes through check-title.sh (fix/chore 0, feat!/feat!+footer 0, feat/feat+footer 1, fix/non-conventional 1) | check-pr without an upstream ref or node → exit 2 with a message; check-title errors name both levels; hook config errors block with a message | n/a — no test in the CLAUDE.md diff | 5 claims: level-mismatch failure, squash under the commit message, conditional denylist scan, `upstream` remote, footer regex vs CLAUDE.md:48; `\| - \|` separators |
| PE-DevTools | 2 receipts spot-checked, all restatements agree; 5 unreceipted fix rules grepped (LOW-003, LOW-004, INFO-004); 9 round-2 findings closed; suite header vs the new term (LOW-006) | temp files on hit, clean and the new 128 exit; `--amend --no-edit` vs `GIT_EDITOR=: --amend`; concurrent commits | 14 message and config shapes on git 2.54: -m with `#` lines, -F, `--cleanup=`, `commit.cleanup=scissors`, commentChar `;` / `auto` / `//`, commentString, inherited `GIT_EDITOR=:`, empty key, `~nosuchuser`, non-ASCII path, subdirectory commit | 5 guards, each on a valid and an invalid input: `GIT_EDITOR=:`, single-char guard, sed escaping, the 0/1/other exit case, quotePath=false | `~user` exit 128 blocks in both hooks; real gitleaks exits 1 on a broken config and the hook says so; the locate hint from root, subdirectory and a path-only hit (LOW-004) | 7 new checks; 12 mutants: 8 killed, 2 equivalent, 2 survive (LOW-005) | 10 claims, 2 false: "the hint locates a hit" (LOW-004), "keyed on one synthetic term" (LOW-006) |
| Primary | 8 receipted rules vs CONTRIBUTING.md, README, changelog.d/README: all agree; CONTRIBUTING.md:18 keep holds | n/a — human docs hold no state | CONTRIBUTING's CI-fails sentence vs 1 / many commits and a non-conventional lone commit (INFO-005) | n/a — no guard in the human docs | n/a — human docs make no call | n/a — no test in the human docs | CONTRIBUTING's CI-fails list vs check-title.sh:32 / :34 and check-pr.sh:17; hooks sentence vs pre-commit:29-48 and commit-msg:7-25 |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 6 | 0 |
| ℹ️ INFO | 6 | 0 |

### In Scope Findings

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| LOW-001 | M4 | `scripts/ci/security/secret-scan.sh:49` | LOW-003 | The `[extend]` guard matches one spelling; an inline table, `[ extend ]`, `["extend"]` or `'extend'.path` still loads a second config, and an inline `disabledRules` gets past the disabledRules check | `scripts/ci/security/secret-scan.sh:43`, `scripts/ci/security/secret-scan.sh:45`, `scripts/ci/security/secret-scan.sh:48`, `scripts/ci/security/secret-scan.sh:52`, `scripts/ci/security/secret-scan.sh:26`, `.gitleaks.toml:11`, `scripts/ci/security/test/run-secret-scan-tests.sh:209`, `scripts/ci/security/test/run-secret-scan-tests.sh:210` |
| LOW-002 | M4 | `scripts/ci/security/secret-scan.sh:48` | missed | A `[[rules]]` entry that reuses a default rule's id (e.g. a never-matching regex or entropy 99) switches that rule off, and the validator accepts it | `scripts/ci/security/secret-scan.sh:28`, `.gitleaks.toml:1`, `.gitleaks.toml:11` |
| LOW-003 | M3 | `scripts/hooks/commit-msg:17` | LOW-008 | In the editor flow, commit-msg strips comment lines even when `commit.cleanup` (`scissors`, `whitespace`, `verbatim`) or `--cleanup=` makes git keep them, so a term on such a line commits unscanned | `scripts/hooks/commit-msg:3`, `scripts/hooks/commit-msg:4`, `scripts/hooks/commit-msg:23`, `scripts/ci/test/run-hooks-tests.sh:133` |
| LOW-004 | M5 | `scripts/hooks/pre-commit:46` | LOW-011 | The locate hint fails when pasted in a subdirectory (root-relative paths) and finds nothing for a hit in a staged path name | `scripts/hooks/pre-commit:43`, `scripts/hooks/pre-commit:45`, `scripts/ci/test/run-hooks-tests.sh:68` |
| LOW-005 | M6 | `scripts/ci/test/run-hooks-tests.sh:117` | INFO-004 | The `~user` test still passes with either hook's 128 guard removed, since both print the same message and pre-commit exits first | `scripts/ci/test/run-hooks-tests.sh:126`, `scripts/ci/test/run-hooks-tests.sh:127`, `scripts/hooks/pre-commit:33`, `scripts/hooks/commit-msg:11` |
| LOW-006 | M7 | `scripts/ci/test/run-hooks-tests.sh:3` | LOW-010 | The suite header says the stub scanner is keyed on one term; it now has two | `scripts/ci/test/run-hooks-tests.sh:28` |

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| INFO-001 | M7 | `.gitleaks.toml:7` | LOW-002 | The accepted shape is a literal prefix in any file matching one path pattern, not "one exact value in one file": `$` is optional and the paths class allows `.` and `\S` | `.gitleaks.toml:3`, `.gitleaks.toml:6`, `.gitleaks.toml:8`, `scripts/ci/security/secret-scan.sh:24`, `scripts/ci/security/secret-scan.sh:26`, `scripts/ci/security/secret-scan.sh:73`, `scripts/ci/security/secret-scan.sh:77`, `scripts/ci/security/test/run-secret-scan-tests.sh:180` |
| INFO-002 | M6 | `scripts/ci/security/test/run-secret-scan-tests.sh:208` | LOW-002 | "a stopword is refused" replaces the regex, so the entry already fails "no exact value"; the case passes with the stopwords refusal deleted | none |
| INFO-003 | M2 | `scripts/ci/release/run-release.sh:113` | still-present | Round-2 INFO-001: a release squash whose message loses its `Base:` trailer is warned, not tagged, and the next stamp bumps its plugins again | `scripts/ci/release/version-stamp.js:92`, `scripts/ci/release/version-stamp.js:93`, `scripts/ci/release/run-release.sh:252` |
| INFO-004 | M3 | `scripts/hooks/commit-msg:21` | LOW-008 | Fails closed: an inherited `GIT_EDITOR=:` on an editor commit, or a multi-char `core.commentChar` / `core.commentString`, scans git's comment lines and blocks a term-removal commit | `scripts/hooks/commit-msg:3`, `scripts/hooks/commit-msg:20`, `scripts/hooks/commit-msg:21` |
| INFO-005 | M7 | `CONTRIBUTING.md:21` | LOW-006 | The CI-fails list omits a one-commit PR whose commit subject is not conventional (step 3 asks for conventional commits); the two "or" clauses read awkwardly | `CLAUDE.md:32`, `scripts/ci/check-title.sh:32` |
| INFO-006 | none | `scripts/hooks/commit-msg:1` | new | Convergence signal: severity flat at LOW/INFO, and the round-3 hook findings refine round-2 fixes | none |

### Action Items

#### Must Fix (blocks merge)

None.

#### Should Fix

None.

#### Consider

- [ ] LOW-001: fix `scripts/ci/security/secret-scan.sh:49` + 8 siblings (check the TOML structure, e.g. `tomllib`, instead of line spellings)
- [ ] LOW-002: fix `scripts/ci/security/secret-scan.sh:48` + 3 siblings (refuse `[[rules]]`, or require a repo-owned id prefix)
- [ ] LOW-003: fix `scripts/hooks/commit-msg:17` + 4 siblings
- [ ] LOW-004: fix `scripts/hooks/pre-commit:46` + 3 siblings
- [ ] LOW-005: fix `scripts/ci/test/run-hooks-tests.sh:117` + 4 siblings
- [ ] LOW-006: fix `scripts/ci/test/run-hooks-tests.sh:3` + 1 sibling
- [ ] INFO-001 … INFO-005: each at its location + the siblings listed above

---

## Review Round 4

> 🚫 PRIOR ROUND INVALIDATED — re-reviewing post-approval changes

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | Claude Code (`/code-reviewer` 2.14.1) for Cali LaFollett |
| **Reviewed SHA** | `c009230baec7b23c805dc1497506bacf1e50b06e` |
| **Date** | 2026-11-26 |
| **Round cap** | 4: raised from 3 by the owner after round 3 ("fix all of the legitimate issues") |
| **Fix cascade** | 7 / 10 in-scope findings introduced by a prior fix |
| **Ripple receipts** | 5 spot-checked, 0 disagree |

### Summary

Round 3 was approved at `e3dc826`, and its LOW and INFO findings were then fixed. All 12 of round 3's findings are closed; INFO-006, its convergence note, is replaced by INFO-004 below.

What the fixes did:
- `scripts/ci/security/check-allowlist.py` parses `.gitleaks.toml` as TOML. Every key spelling and `[[rules]]` is checked as the structure gitleaks reads.
- Paths and values must be `$`-anchored literals, so "one exact value in one exact file" holds.
- The hooks follow `commit.cleanup` and `core.commentString`, and they name where a hit is.

Round 4 found no CRITICAL, HIGH or MEDIUM. 7 of the 10 LOW and INFO findings are edge cases of round-3 fixes. Notable ones:
- CLAUDE.md:32 asks for the same type and `!` on a lone commit, but CI compares only the release levels (LOW-001).
- The value cases never test the literal or escape classes themselves, so a wildcard-admitting class would pass the suite (LOW-002).
- 3 hook mutants survive the 41 checks (LOW-006). The round-3 note that the `auto` bracket mutant is equivalent is refuted: git 2.54 picks `;` for a message whose first line starts with `#`.

CI was green on all 5 jobs at the reviewed SHA (run 45919419861). Ubuntu ran secret-scan 78/78 and hooks 41/41 with no SKIP. This is the last round under the 4-round cap.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-AWS-Infra | none | none — TEST BUDGET none. Read CI run 45919419861 at `c009230`: all 5 jobs green, 8 suites, secret-scan 78/78, and the gitleaks job passed check-allowlist.py on the runner's python3. Under M3/M4/M6: check-allowlist.py on 24 scratch configs, 7 of them also on real gitleaks 8.30.1; 4 value-class mutants (3 survive, LOW-002); python3 3.9.6 → exit 2 "needs Python 3.11+" |
| PE-Governance | none | none |
| PE-DevTools | lint-only | run-hooks-tests.sh 41/41 on git 2.54 and gitleaks 8.30.1; shellcheck 0.11.0 clean; all 3 files 100755; 8 mutants of the fix diff: 5 killed, 3 survive (LOW-006) |
| Primary | — | CI run 45919419861 at `c009230`: all 5 jobs green. Re-ran PE-DevTools' declined mutant run on copies in a fresh `mktemp -d` directory: baseline 41/41, and the 3 mutants survive, matching LOW-006 |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-AWS-Infra | 3 receipts spot-checked, 0 disagree; the `.gitleaks.toml`, release-trailer and title restatements agree; the unreceipted python3 3.11+ rule has 4 restatements, 2 of which omit it (INFO-002); value cases diffed against their path siblings (LOW-002); 5 round-3 findings re-checked | a trailer-less release squash traced through reconcile → stamp → force-push → auto-merge → wait (INFO-001); repo squash settings via gh api keep the `Base:` trailer on an unedited merge | 9 edge inputs to check-allowlist.py: empty, non-UTF-8, BOM, directory, `[[extend]]`, `commits`, `allowlists` as a table, `useDefault = 1` / `1.0` (gitleaks reads both as true) | 15 scratch configs, 7 on real gitleaks: key-case folding refused, the inline `allowlists` array honored by both, `UseDefault` refused, 40-char `.` and `\S` values refused; no accepted config clears more than one exact value in one file | python3 absent, 3.9.6, missing checker, unreadable, not TOML, decode error, signal exit: all fail closed | 53 shape cases read; 4 value-class mutants: `any \x escape`, `bare .` and `bare *` survive (LOW-002); 9 structural mutants killed | 9 claims: key-case folding, regexTarget, default-id override, exit codes, "no spelling gets past", `gh release create --target`, the unedited-squash claim hold; the warning's recovery timing (INFO-001) and "Requires bash + node" (INFO-002) do not |
| PE-Governance | 1 receipt spot-checked; the lone-commit rule has 4 restatements, and only CLAUDE.md:32's parenthetical is stricter than CI (LOW-001); hook, `.gitleaks.toml` and release hunks vs CLAUDE.md:27 / :31: no drift | lone-commit state across a force-push 1 ↔ many commits and a retitle: no gap | 7 one-commit shapes through line 32: 3 rejected by the parenthetical but passed by CI (LOW-001) | line 32 as a guard vs check-title.sh:24-38 and commitLevel: rejects 2 valid shapes, accepts 1 contrived one | a level mismatch names both levels; check-pr.sh makes no title claim | n/a — no test in the CLAUDE.md diff | line 32 vs check-title.sh:16-38 and version-stamp.js:69-83: the parenthetical is false for same-level shapes (LOW-001) |
| PE-DevTools | 3 receipts spot-checked; 4 unreceipted rules grepped, 1 disagrees (LOW-004); the quote-strip fix vs its `--name-only` sibling (LOW-005) | temp files removed on the hit, clean and early-exit paths; concurrent commits share nothing; amend and pathspec commits diff the right index | paths with a space, tab, backslash and quote (LOW-005); a subdirectory commit in a spaced repo path; 26 comment strings through BSD sed; `commit.cleanup=strip` × 4 `--cleanup=` flags (LOW-004); `auto` × 3 flows × 4 modes; whitespace-mode line numbers (INFO-003) | `core.commentChar` `auto` / `AUTO` / `Auto` end to end: the last two let a `#` subject through (LOW-003); `strip` vs a keep-flag; the `index()` prefix and `n in p` / `n in w` bounds | the locate fallback for a location-less scanner; `~user` 128 in each hook; the sed/stripspace pipeline cannot fail on the 26 strings | 8 mutants: 5 killed, 3 survive (LOW-006); cases that kill 2 of them written and run | 8 claims on git 2.54: the cleanup table, last-set-wins, `GIT_EDITOR=:`, invisible `--cleanup=` hold; "never less, except…" false (LOW-004); "line N of the message git will record" false in whitespace and scissors editor flows (INFO-003); "named unquoted" half true (LOW-005); the equivalent-mutant note refuted (LOW-006) |
| Primary | 5 receipted rules vs CONTRIBUTING.md, README and changelog.d/README: all agree | n/a — human docs hold no state | CONTRIBUTING.md:20-22 vs 1 / many commits, a non-conventional lone commit, and a lone commit at another level: INFO-005 closed | n/a — no guard in the human docs | n/a — human docs make no call | n/a — no test in the human docs | CONTRIBUTING's CI-fails list vs check-title.sh:32 / :34 and check-pr.sh; the hooks sentence vs pre-commit and commit-msg: agree |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 6 | 0 |
| ℹ️ INFO | 4 | 0 |

### In Scope Findings

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| LOW-001 | M7 | `CLAUDE.md:32` | missed | The rule's "(same type, `!` and `BREAKING CHANGE:` footer)" is stricter than CI, which compares only the release levels; a `chore:` commit under a `fix:` title passes CI, but the model would ask for an amend | `CONTRIBUTING.md:21`, `scripts/ci/check-title.sh:3`, `scripts/ci/check-title.sh:35`, `CLAUDE.md:48` |
| LOW-002 | M6 | `scripts/ci/security/test/run-secret-scan-tests.sh:208` | missed | Every refused value already fails on another character, so a LITERAL or ESCAPED class that admits `.`, `\S` or `*` passes the whole suite and accepts a 40-character wildcard value | `scripts/ci/security/test/run-secret-scan-tests.sh:200`, `scripts/ci/security/test/run-secret-scan-tests.sh:201`, `scripts/ci/security/check-allowlist.py:10`, `scripts/ci/security/check-allowlist.py:24`, `scripts/ci/security/check-allowlist.py:25`, `scripts/ci/security/check-allowlist.py:26`, `.gitleaks.toml:7` |
| LOW-003 | M4 | `scripts/hooks/commit-msg:34` | INFO-004 | git reads `core.commentChar` `AUTO` / `Auto` as auto, but the hook matches lowercase only, so it strips a `#` first line that git keeps and records | `scripts/hooks/commit-msg:11`, `scripts/ci/test/run-hooks-tests.sh:208` |
| LOW-004 | M7 | `scripts/hooks/commit-msg:12` | LOW-003 | The header's "never less, except…" list misses a keep-comments `--cleanup=` flag on `-m` under `commit.cleanup=strip`, which records a `#` line the hook dropped | `scripts/hooks/commit-msg:13`, `scripts/hooks/commit-msg:28` |
| LOW-005 | M3 | `scripts/hooks/pre-commit:49` | LOW-004 | A path with a space is named with git's trailing tab, a quoted path keeps its C escapes, and the staged-path list stays quoted | `scripts/hooks/pre-commit:44`, `scripts/hooks/pre-commit:56`, `scripts/hooks/pre-commit:9`, `scripts/ci/test/run-hooks-tests.sh:83` |
| LOW-006 | M6 | `scripts/ci/test/run-hooks-tests.sh:211` | INFO-004 | 3 fix mutants survive the 41 checks: the `auto` bracket reduced to `#`, commentChar/commentString `tail` → `head`, and an always-printed locate line | `scripts/hooks/commit-msg:34`, `scripts/hooks/commit-msg:32`, `scripts/hooks/pre-commit:58`, `scripts/ci/test/run-hooks-tests.sh:73`, `scripts/ci/test/run-hooks-tests.sh:198` |

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| INFO-001 | M2 | `scripts/ci/release/run-release.sh:115` | INFO-003 | The trailer-less release warning's recovery comes too late: the same run has already re-bumped the squash's plugins, armed auto-merge and may have merged | `scripts/ci/release/run-release.sh:155`, `scripts/ci/release/run-release.sh:239`, `scripts/ci/release/run-release.sh:253`, `scripts/ci/release/version-stamp.js:91`, `scripts/ci/release/version-stamp.js:147`, `.github/workflows/release.yml:9` |
| INFO-002 | M1 | `scripts/ci/run-shell-tests.sh:8` | LOW-001 | The suite headers don't name the new python3 3.11+ need, and on an older python3 every run case fails as "expected [0], got [2]" with no reason shown | `scripts/ci/security/test/run-secret-scan-tests.sh:7`, `scripts/ci/security/secret-scan.sh:27`, `scripts/ci/security/check-allowlist.py:21` |
| INFO-003 | M7 | `scripts/hooks/commit-msg:45` | LOW-003 | "line N of the message git will record" counts the edited file's blank lines in whitespace and scissors editor flows, where git collapses them | `scripts/ci/test/run-hooks-tests.sh:159` |
| INFO-004 | none | `scripts/hooks/commit-msg:1` | new | Convergence signal: severity flat at LOW/INFO, and the hook findings refine round-3 fixes | none |

### Action Items

#### Must Fix (blocks merge)

None.

#### Should Fix

None.

#### Consider

- [ ] LOW-001: fix `CLAUDE.md:32` + 4 siblings (drop the parenthetical; the table defines the bump)
- [ ] LOW-002: fix `scripts/ci/security/test/run-secret-scan-tests.sh:208` + 7 siblings (mirror the path cases on the value side)
- [ ] LOW-003: fix `scripts/hooks/commit-msg:34` + 2 siblings
- [ ] LOW-004: fix `scripts/hooks/commit-msg:12` + 2 siblings
- [ ] LOW-005: fix `scripts/hooks/pre-commit:49` + 4 siblings
- [ ] LOW-006: fix `scripts/ci/test/run-hooks-tests.sh:211` + 5 siblings
- [ ] INFO-001 … INFO-003: each at its location + the siblings listed above

---

## Review Round 5

> 🚫 PRIOR ROUND INVALIDATED — re-reviewing post-approval changes

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | Claude Code (`/code-reviewer` 2.14.1) for Cali LaFollett |
| **Reviewed SHA** | `a330382ec24cadba192370dceec0f6742fa366af` |
| **Date** | 2026-11-26 |
| **Round cap** | past the owner's cap of 4; the owner approved this round after round 4 |
| **Fix cascade** | 9 / 11 in-scope findings introduced by a prior fix |
| **Ripple receipts** | 5 supplied, all spot-checked, 0 disagree; 1 unreceipted rule is false (LOW-001) |

### Summary

Round 4 was approved at `c009230`, and its findings were then fixed. All 10 of round 4's findings are closed, and its convergence note (INFO-004) is replaced by INFO-007 below.

What the fixes did:
- A release-titled commit without its `Base:` trailer now leaves the release PR for a human: auto-merge is turned off, and the run exits before the wait.
- The allow-list suite has value cases for a bare dot, quantifier, alternation and escape classes. Its sed helper fails the suite on an edit that errors or changes nothing.
- commit-msg reads `auto` in any case, and tidies blank lines as git does.
- pre-commit scans and names paths without git's quotes or its trailing tab.
- CLAUDE.md:32 drops the stricter-than-CI parenthetical.

Round 5 found no CRITICAL, HIGH or MEDIUM. 9 of the 11 LOW and INFO findings are edge cases of round-4 fixes. Notable ones:
- check-pr.sh and the release plan read git's C-quoted `--name-only` paths literally. A PR whose only plugin change is a file with a non-ASCII, quote or backslash name skips the fragment gate and gets no bump (LOW-003). It is latent: no tracked path is quoted today. Reported by PE-DevTools and confirmed by PE-AWS-Infra.
- The suite header's "gitleaks v8.19+" is too low: `[[allowlists]]` needs v8.25 (LOW-001).
- 2 test gaps let a mutant through: one that holds every release PR (LOW-002), and a quoted path with a space (LOW-004).

Severity is falling (round 4: 6 LOW; round 5: 4 LOW), but each fix round still produces new edge cases. PE-DevTools recommends ending the hook rounds and keeping further git cleanup edge cases as documented misreads (INFO-007).

CI was green on all 5 jobs at the reviewed SHA (run 45922394995). Ubuntu ran secret-scan 84/84 and hooks 48/48 with no SKIP.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-AWS-Infra | none | none — TEST BUDGET none. Read CI run 45922394995 at `a330382`: all 5 jobs green; integration 65, engine 79, secret-scan 84, check-pr 16, title 17, gate 14, hooks 48; gitleaks 8.30.1 on both jobs. Under M2/M3/M6: 15 check-allowlist.py mutants (9 killed; of the 6 survivors only brackets admit a wildcard, INFO-004); 2 run-release.sh mutants (1 survives, LOW-002); 5 file names through check-pr.sh and the plan (3 escape, LOW-003) |
| PE-Governance | none | none; 8 one-commit shapes through check-title.sh against CLAUDE.md:32 |
| PE-DevTools | lint-only | run-hooks-tests.sh 48/48 on git 2.54, gitleaks 8.30.1 and BSD awk; shellcheck 0.11.0 clean; all 3 files 100755; 8 mutants on copies: 6 killed, 2 survive (LOW-004, INFO-005) |
| Primary | — | CI run 45922394995 at `a330382`: all 5 jobs green. Author mutants before review: 10 hook, 5 allow-list value-class and 1 release-hold mutant, all killed |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-AWS-Infra | 3 receipts spot-checked, 0 disagree, and the README.md:108 / release.yml:4 keeps hold; the unreceipted "gitleaks v8.19+" vs 3 restatements and gitleaks' README (LOW-001); run-release.sh:11-12 vs a same-pass tagged release (INFO-002); the hooks' `quotePath=false` read vs 3 CI path reads (LOW-003) | `HELD` traced through init, reconcile, BASE, the nothing-to-release exit, the hold and the wait-loop reconcile; 2 scenarios on a copy of the harness (INFO-002, INFO-003) | `HELD` with 0, 1 and 2 look-alikes, before and after a trailered release; `lit()` on `\|` and `&`; `with()` on a no-op and an unbalanced sed; 5 file names through check-pr.sh and the plan (LOW-003) | the hold's trigger vs check-title.sh's release-subject refusal; 15 checker mutants vs 66 shape cases; a 36-wide `[!-~]` value clears any PAT on real gitleaks under the bracket mutant, and the real checker refuses it (INFO-004) | a `--disable-auto` failure warns and exits 0; a re-bump PR is always new and never armed; dispatch or open_pr failure before the hold; python3 without tomllib exits 1 with a reason | 8 added cases read; 15 checker mutants: 9 killed, 6 survive, only brackets admit a wildcard (INFO-004); 2 release mutants: no-exit killed, hold-for-every survives (LOW-002); the bad-edits guard fires on both kinds of bad edit | gitleaks `[[allowlists]]` since v8.25.0 (LOW-001); `gh pr merge --disable-auto`; release-version on a `(#N)` suffix; the `lit()` and python3 headers hold; git's quoting under the default `core.quotePath` (LOW-003) |
| PE-Governance | 5 receipts spot-checked, 0 disagree; the check-title.sh:35 keep holds; CLAUDE.md does not restate the hold, python3 or path rules; repo-wide grep for the lone-commit rule: 11 hits, 0 disagree; PR #21 against the hard rules: check-pr.sh rc 0 | the lone-commit rule across a retitle and a 1 ↔ many force-push; the `HELD` path vs CLAUDE.md:31 | 8 one-commit shapes vs line 32; 1 shape passes a literal "plugin bump" reading but fails CI (INFO-001) | line 32 as a guard vs check-title.sh and commitLevel: rejects none that CI passes; :27 vs the hooks: 0 version or fragment checks | the mismatch error names both levels; check-pr.sh exits 0/1/2 with messages; the hold warns from the run itself | n/a — no test in the CLAUDE.md diff | line 32, :27, :31, :33, :37-41, the table and the Structure block vs the code: all hold |
| PE-DevTools | 2 receipts in its domain vs 10 restatements: all agree except commit-msg:10-11 under auto (INFO-006); the quoted-path pattern grepped repo-wide: 3 CI readers (LOW-003) | temp files unchanged on every path; the tidy stage holds no state; concurrent commits share nothing | 8 path shapes × 3 locales through `unq` and the `+++` rule; 5 cleanup modes × with/without `-v` line numbers: 10/10 match; auto / Auto / AUTO on both keys | the `[Aa][Uu][Tt][Oo]` glob vs 3 spellings × 2 keys: git and the hook agree on all 6; `unq` vs git's quoting of a quote, backslash, trailing backslash, control and non-ASCII characters | the stripspace stage fails only where git commit already dies; the locate fallback prints only when no location is named | 8 mutants: 6 killed; tab strip after `unq` (LOW-004) and `auto\|Auto` (INFO-005) survive | 9 claims hold on git 2.54, except "a hit's line number is its line in the recorded message" under auto (INFO-006) |
| Primary | 5 receipted rules vs CONTRIBUTING.md, README and changelog.d/README: all agree | n/a — human docs hold no state | n/a — no human doc in the fix diff | n/a — no guard in the human docs | n/a — human docs make no call | n/a — no test in the human docs | CONTRIBUTING.md:25-27 vs the hooks and README.md:104-110 vs the release hold: agree |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 4 | 0 |
| ℹ️ INFO | 7 | 0 |

### In Scope Findings

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| LOW-001 | M7 | `scripts/ci/run-shell-tests.sh:9` | INFO-002 | The header says gitleaks v8.19+, but `[[allowlists]]` (the only shape check-allowlist.py allows) needs v8.25, so the suite's allow-list case fails without a reason on 8.19-8.24 | `CONTRIBUTING.md:25`, `scripts/hooks/pre-commit:2`, `scripts/hooks/pre-commit:25`, `scripts/ci/security/test/run-secret-scan-tests.sh:8`, `scripts/ci/security/install-gitleaks.sh:6` |
| LOW-002 | M6 | `scripts/ci/release/test/run-release-integration-tests.sh:222` | INFO-001 | No case checks that a trailered release does not hold, so a mutant that holds every release-titled commit passes 65/65 | `scripts/ci/release/test/run-release-integration-tests.sh:266`, `scripts/ci/release/run-release.sh:119`, `scripts/ci/release/run-release.sh:258` |
| LOW-003 | M3 | `scripts/ci/check-pr.sh:26` | missed | check-pr.sh and the release plan read `--name-only` paths with the default `core.quotePath`, so a C-quoted name (non-ASCII, quote, backslash) escapes the `^plugins/` matches: no fragment required, no bump. Latent: 0 tracked paths are quoted | `scripts/ci/check-pr.sh:38`, `scripts/ci/check-pr.sh:49`, `scripts/ci/check-pr.sh:50`, `scripts/ci/check-pr.sh:51`, `scripts/ci/check-pr.sh:52`, `scripts/ci/release/run-release.sh:165`, `scripts/ci/release/version-stamp.js:30`, `scripts/ci/release/version-stamp.js:159`, `scripts/hooks/pre-commit:56` |
| LOW-004 | M6 | `scripts/ci/test/run-hooks-tests.sh:83` | LOW-005 | No fixture is a quoted path with a space, so moving the trailing-tab strip after `unq` passes 48/48 while the hook names `b/q\"x y.txt` | `scripts/hooks/pre-commit:61`, `scripts/ci/test/run-hooks-tests.sh:86`, `scripts/ci/test/run-hooks-tests.sh:91`, `scripts/ci/test/run-hooks-tests.sh:93` |

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| INFO-001 | M4 | `CLAUDE.md:32` | LOW-001 | "same plugin bump" reads as met in a PR that touches no plugin, but CI still compares the levels (`ci:` title, `feat:` commit → rc 1) | `CLAUDE.md:44`, `CONTRIBUTING.md:22`, `scripts/ci/check-title.sh:3` |
| INFO-002 | M2 | `scripts/ci/release/run-release.sh:119` | INFO-001 | The hold is decided over the reconcile pass, not the plan's range, so a trailered release tagged in the same pass still holds a correct release PR for one run | `scripts/ci/release/run-release.sh:11`, `scripts/ci/release/run-release.sh:12`, `scripts/ci/release/run-release.sh:118`, `scripts/ci/release/run-release.sh:162`, `scripts/ci/release/run-release.sh:258`, `scripts/ci/release/test/run-release-integration-tests.sh:222` |
| INFO-003 | M2 | `scripts/ci/release/run-release.sh:118` | INFO-001 | After the warning's recovery (tag by hand, re-run), the held PR stays open with the re-bump stamp, and nothing says to close it | `scripts/ci/release/run-release.sh:172`, `scripts/ci/release/run-release.sh:243`, `scripts/ci/release/run-release.sh:261` |
| INFO-004 | M6 | `scripts/ci/security/test/run-secret-scan-tests.sh:216` | LOW-002 | No value case fails on a lone bracket, so a LITERAL class that admits `[` `]` passes the suite | `scripts/ci/security/test/run-secret-scan-tests.sh:225`, `scripts/ci/security/check-allowlist.py:10`, `scripts/ci/security/check-allowlist.py:24` |
| INFO-005 | M6 | `scripts/ci/test/run-hooks-tests.sh:233` | LOW-003 | Only the `Auto` spelling is tested, so an `auto\|Auto` mutant survives and lets an `AUTO` `#` subject through | `scripts/hooks/commit-msg:38`, `scripts/hooks/commit-msg:13` |
| INFO-006 | M7 | `scripts/hooks/commit-msg:10` | INFO-003 | Under auto the hook keeps comment lines git drops, so "line N of the message git will record" can name a line git never records | `scripts/hooks/commit-msg:13`, `scripts/hooks/commit-msg:38`, `scripts/hooks/commit-msg:50`, `scripts/ci/test/run-hooks-tests.sh:243` |
| INFO-007 | none | `scripts/hooks/commit-msg:1` | new | Convergence signal: severity falling, and the hook findings are a closed set that refines rounds 2-4 | none |

### Action Items

#### Must Fix (blocks merge)

None.

#### Should Fix

None.

#### Consider

- [ ] LOW-001: fix `scripts/ci/run-shell-tests.sh:9` + 5 siblings (state v8.25+)
- [ ] LOW-002: fix `scripts/ci/release/test/run-release-integration-tests.sh:222` + 3 siblings (a plugin follow-up in case 7 that must arm auto-merge)
- [ ] LOW-003: fix `scripts/ci/check-pr.sh:26` + 9 siblings (read paths with `-z`, or `quotePath=false` and fail closed on a quoted line)
- [ ] LOW-004: fix `scripts/ci/test/run-hooks-tests.sh:83` + 4 siblings
- [ ] INFO-001 … INFO-006: each at its location + the siblings listed above

---

## Review Round 6

> 🚫 PRIOR ROUND INVALIDATED — re-reviewing post-approval changes

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Reviewer** | Claude Code (`/code-reviewer` 2.14.1) for Cali LaFollett |
| **Reviewed SHA** | `171a7872dd889a50b625b58465f3329bce3cbfc2` |
| **Date** | 2026-11-26 |
| **Round cap** | past the owner's cap of 4; the owner chose "fix all here + round 6" after round 5 |
| **Fix cascade** | 3 / 5 in-scope findings introduced by a prior fix |
| **Ripple receipts** | 5 supplied, all spot-checked; 1 restatement disagrees (INFO-002) |

### Summary

Round 5 was approved at `a330382`, and all 11 of its findings were then fixed:
- 10 are closed.
- INFO-006 is partly closed: the header now documents the auto caveat, but the printed hit message does not (INFO-002).
- The convergence note (INFO-007) is reissued as INFO-004.

What the fixes did:
- check-pr.sh and the release plan read paths with `-z`, so a plugin file git would quote still needs a fragment and still bumps its plugin.
- The release PR is held only for a trailer-less release title still in the plan's range, and the hold's warning names the tag to create and the PR to close.
- gitleaks v8.25+ is stated wherever a version is named.
- The hook and allow-list test gaps are closed.

Round 6 found no CRITICAL, HIGH or MEDIUM: 1 LOW and 4 INFO, down from 4 LOW and 7 INFO.
- LOW-001: inserting case 7b left case 8's fixture rolling main's marketplace version back from 1.0.3 to 1.0.2. Its check passes only because a minor bump of either gives 1.1.0.
- The INFO findings are an unpinned "latest wins" invariant, one wording caveat under the deprecated `core.commentChar=auto`, one stale comment, and the convergence note.

PE-Governance found nothing. PE-DevTools again recommends ending the hook rounds.

CI was green on all 5 jobs at the reviewed SHA (run 45927455908). Ubuntu ran secret-scan 90/90 and hooks 48/48 with no SKIP.

### Test Evidence

| PE | Budget | Pass 2 evidence |
| - | - | - |
| PE-AWS-Infra | none | none — TEST BUDGET none; CI run 45927455908 at `171a787` as reported: 5 jobs green, 8 suites, 0 failed. Under M2/M6, on copies of `scripts/ci/release`: 4 integration runs and 1 unit run; 4 mutants (3 killed, 1 survives, INFO-001); a probe of case 8's end state (LOW-001) |
| PE-Governance | none | none; 11 commit shapes through check-title.sh, check-pr.sh origin/main HEAD rc 0, squash settings via gh api |
| PE-DevTools | lint-only | run-hooks-tests.sh 48/48 on git 2.54, gitleaks 8.30.1 and BSD awk; shellcheck 0.11.0 clean; all 3 files 100755; 9 mutants on copies, all killed |
| Primary | — | CI run 45927455908 at `171a787`: all 5 jobs green. Author mutants before review, all killed: 12 hook, 6 value-class, 3 release-hold and path-read, 2 check-pr, 1 engine |

### Moves Coverage

| PE | M1 Ripple | M2 Lifecycle | M3 Inputs | M4 Attack the guard | M5 Failure path | M6 Falsify the test | M7 Fact check |
| - | - | - | - | - | - | - | - |
| PE-AWS-Infra | 4 receipts vs 19 restatements: 0 disagree; the README.md:108, release.yml:4, pre-commit:56 and check-title.sh:35 keeps hold; 14 git reads grepped, all 3 path-name reads use `-z`, 0 unconverted | `HELD` / `HELD_TAG` through init, reconcile, the BASE recompute, the is-ancestor clear, the nothing-to-release exit, the hold and the wait loop; the recovery with and without the close; 7b's end state into case 8 (LOW-001) | `HELD` with 0, 1 and 2 trailer-less titles around a tagged release; non-ASCII, quote, tab and newline names through `-z \| tr` and `parseLog`; `git log -z` bytes vs the unit fixtures | the is-ancestor clear under squash-only history; a wrong hand tag vs check-title.sh's release-subject refusal; quoted and newline-split fragment names; the 6 new value cases vs the checker | is-ancestor errors, the unchecked `tr` writes, a `git log -z` failure, a `--disable-auto` failure: none reaches a wrong release | 4 mutants: hold-for-every, no `-z` and split on `\n` killed; first-trailer-less-wins survives (INFO-001) | `gh release create --target` with a full SHA; `-z` writes names unquoted; BSD `tr` and `\0`; `[[allowlists]]` needs v8.25; 4 comments vs the code: hold |
| PE-Governance | 5 receipts spot-checked, 0 disagree; 5 live restatements of the lone-commit rule agree; no stale 8.19; PR #21 vs the hard rules: check-pr.sh rc 0, no fragment needed | the lone-commit rule across a retitle and a 1 ↔ many force-push; the scoped hold and its recovery vs CLAUDE.md:31 | 10 one-commit shapes and 1 multi-commit shape vs line 32 and row 48 | line 32 as a guard vs check-title.sh: no shape passes the rule but fails CI on level; :27 vs the hooks; :37 vs the `-z` fragment read | the mismatch error, check-pr.sh's exit 2, pre-commit's skip and its v8.25+ message | n/a — no test in the CLAUDE.md diff | squash settings, commitLevel, marketplaceLevel, plan() with `-z`, check-pr.sh:38-58 and the Structure block vs CLAUDE.md:27 and :31-48: all hold |
| PE-DevTools | 3 receipts in its domain spot-checked; gitleaks v8.25+ agrees in 6 places; the auto rule disagrees at commit-msg:50 (INFO-002); the pre-commit:56 keep holds | no new state; the 3 cleanup traps are unchanged; the new fixture lives in the suite's own temp dir | git's real header for `q"x y.txt` (quoted, trailing tab); auto / aUtO / AUTO on both keys | the `[Aa][Uu][Tt][Oo]` glob vs git on both keys; `unq` vs a quote, space and backslash together | no new failing call; the "failed to run" branch prints v8.25+ and refuses the commit | 9 mutants on copies, all killed | gitleaks v8.25.0 notes for `[[allowlists]]`; the 7 pre-commit flags in 8.30.1; git 2.54 reads auto in any case and deprecates it; install-gitleaks.sh:4's claim vs `.gitleaks.toml` (INFO-003) |
| Primary | 5 receipted rules vs CONTRIBUTING.md, README and changelog.d/README: agree | n/a — human docs hold no state | n/a — CONTRIBUTING.md:25 is the only human-doc hunk | n/a — no guard in the human docs | n/a — human docs make no call | n/a — no test in the human docs | CONTRIBUTING.md:25's v8.25+ vs pre-commit and the suite headers: agree |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 1 | 0 |
| ℹ️ INFO | 4 | 0 |

### In Scope Findings

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| LOW-001 | M6 | `scripts/ci/release/test/run-release-integration-tests.sh:248` | LOW-002 | Case 7b now tags v1.0.3 before case 8, but case 8 still writes marketplace 1.0.2, so its debut rolls main's version back; "marketplace minor" passes only by coincidence, and 7b reuses `(#5)` | `scripts/ci/release/test/run-release-integration-tests.sh:249`, `scripts/ci/release/test/run-release-integration-tests.sh:231` |

| ID | Move | Location | Introduced by | Finding | Siblings |
| - | - | - | - | - | - |
| INFO-001 | M6 | `scripts/ci/release/run-release.sh:120` | INFO-002 | After the range check, the hold depends on `HELD` being the latest trailer-less title; a first-wins mutant passes 70/70, and no comment says why the order matters | `scripts/ci/release/run-release.sh:167`, `scripts/ci/release/test/run-release-integration-tests.sh:229` |
| INFO-002 | M1 | `scripts/hooks/commit-msg:50` | still-present | Under auto, the printed "line N of the message git will record" can name a line git drops; only the header was qualified | `scripts/hooks/commit-msg:10`, `scripts/hooks/commit-msg:13`, `scripts/ci/test/run-hooks-tests.sh:169`, `scripts/ci/test/run-hooks-tests.sh:174`, `scripts/ci/test/run-hooks-tests.sh:243` |
| INFO-003 | M7 | `scripts/ci/security/install-gitleaks.sh:4` | LOW-001 | "(.gitleaks.toml uses [[allowlists]])" — the file holds no entries today; `[[allowlists]]` is the only entry shape it allows. Raised by PE-DevTools as outside its domain | `.gitleaks.toml:3`, `scripts/ci/security/check-allowlist.py:7` |
| INFO-004 | none | `scripts/hooks/commit-msg:1` | still-present | Convergence signal: severity falling (round 5: 4 LOW, round 6: 1 LOW, in a test fixture), and the hook themes are a closed set; git 2.54 deprecates `core.commentChar=auto` | none |

### Action Items

#### Must Fix (blocks merge)

None.

#### Should Fix

None.

#### Consider

- [ ] LOW-001: fix `scripts/ci/release/test/run-release-integration-tests.sh:248` + 2 siblings (write 1.0.3, renumber the debut `(#7)`)
- [ ] INFO-001 … INFO-003: each at its location + the siblings listed above

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
