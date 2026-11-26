# Code Review: feat-github-actions-release

**Verdict:** ✅ APPROVED (round 3)

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

**Locked to SHA:** `e3dc826e76eb67948271c7bada426ee5555c8084` (round 3)
**Status:** ✅ Mergeable IF the branch head is `e3dc826e76eb67948271c7bada426ee5555c8084` plus only this review doc. Any other commit after it invalidates this round and requires re-review (`/code-reviewer` again before merge).

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

🤖 Generated with [Claude Code](https://claude.com/claude-code)
