# Code Review: 42

**Verdict:** ✅ APPROVED

| | |
| - | - |
| **Branch** | `feat/42-login-lockout` |
| **PR** | — |
| **Author** | @— |
| **Engineer Reviewer** | @octocat |
| **Agent Reviewers** | `pe-go` — opus (STANDARD), `pe-vue` — opus (STANDARD) |
| **Review Round** | 1 |
| **Reviewed SHA** | `1a2b3c4` |
| **Gate Status** | OPEN — need 2 more consecutive clean round(s) |
| **Tier** | STANDARD (classifier) · model-by-review-tier: off (default) |
| **Routing** | classifier globs — no judgment re-route |
| **Title** | Lock an account after repeated failed logins |
| **Files Changed** | 3 |
| **Lines Changed** | +120 / -8 |
| **Date** | 2026-10-11 |

---

## Summary

Adds a failed-login counter that locks the account. One gating issue: the username is concatenated into a SQL query.

---

## Acceptance-Criteria Conformance

| AC | Verdict | Evidence |
| - | - | - |
| #1 Lock the account after five failed attempts | ✅ satisfied | `internal/auth/limiter.go:40` |
| #2 The lockout clears after 15 minutes | ⚠️ not-verifiable | the clock is injected by the caller, outside the diff |

---

## Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 1 | 0 |
| 🟡 MEDIUM | 0 | 1 |
| 🟢 LOW | 1 | 0 |
| ℹ️ INFO | 0 | 0 |

---

## In Scope Findings

### 🟠 HIGH-001: Username concatenated into a SQL query

**Domains:** [pe-go] · **Category:** security
**Location:** `internal/auth/store.go:14`
**Also at:** `internal/auth/store.go:31`

The username is appended to the query string, so a crafted username runs arbitrary SQL.

**Recommendation:** Pass the username to QueryRowContext as a bind parameter.

---

### 🟢 LOW-001: Magic attempt limit

**Domains:** [pe-go] · **Category:** maintainability
**Location:** `internal/auth/limiter.go:22`

The limit 5 is inlined.

**Recommendation:** Move it to a named constant.

---

## Advisory Findings

- [LOW] LOW-001: Magic attempt limit — `internal/auth/limiter.go:22`

---

## Out of Scope

| Severity | Issue | Location |
| - | - | - |
| 🟡 MEDIUM | Attempts table has no username index | `db/migrations/001_attempts.sql:3` |

---

## Action Items

### Must Fix (blocks merge)

- [ ] HIGH-001: Username concatenated into a SQL query — `internal/auth/store.go:14`

### Should Fix

- None

### Consider

- [ ] LOW-001: Magic attempt limit — `internal/auth/limiter.go:22`

---

## Verification Receipts

- **[positive] Store closes its rows** at `internal/auth/store.go:18` — defer rows.Close() follows the query.

---

## Files Reviewed

| File | Findings |
| - | - |
| `internal/auth/limiter.go` | 1 |
| `internal/auth/store.go` | 1 |
| `web/src/components/LoginForm.vue` | 0 |

---

## Review Round 2

| | |
| - | - |
| **Engineer Reviewer** | @octocat |
| **Agent Reviewers** | `pe-go` — opus (STANDARD), `pe-vue` — opus (STANDARD) |
| **Reviewed SHA** | `5d6e7f8` |
| **Gate Status** | OPEN — need 1 more consecutive clean round(s) |
| **Tier** | STANDARD (classifier) · model-by-review-tier: off (default) |
| **Routing** | classifier globs — no judgment re-route |
| **Verdict** | ✅ APPROVED |
| **Date** | 2026-10-12 |

### Summary

The query now binds the username. No gating findings remain.

### Acceptance-Criteria Conformance

| AC | Verdict | Evidence |
| - | - | - |
| #1 Lock the account after five failed attempts | ✅ satisfied | `internal/auth/limiter.go:40` |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 0 | 0 |

### In Scope Findings

None.

### Action Items

#### Must Fix (blocks merge)

- None

#### Should Fix

- None

#### Consider

- None

---

## Review Round 3  🔁 CONFIRMATION ROUND — same SHA, fresh dispatch; a 2nd clean round locks Gate 1

| | |
| - | - |
| **Engineer Reviewer** | @octocat |
| **Agent Reviewers** | `pe-go` — opus (STANDARD), `pe-vue` — opus (STANDARD) |
| **Reviewed SHA** | `5d6e7f8` |
| **Gate Status** | LOCKED — ready for Gate 2 (PR peer review) |
| **Tier** | STANDARD (classifier) · model-by-review-tier: off (default) |
| **Routing** | classifier globs — no judgment re-route |
| **Verdict** | ✅ APPROVED |
| **Date** | 2026-10-12 |

### Summary

The query now binds the username. No gating findings remain.

### Acceptance-Criteria Conformance

| AC | Verdict | Evidence |
| - | - | - |
| #1 Lock the account after five failed attempts | ✅ satisfied | `internal/auth/limiter.go:40` |

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 0 | 0 |

### In Scope Findings

None.

### Action Items

#### Must Fix (blocks merge)

- None

#### Should Fix

- None

#### Consider

- None

---

## Review Round 4  🔁 CONFIRMATION ROUND — same SHA, fresh dispatch; a 2nd clean round locks Gate 1

| | |
| - | - |
| **Engineer Reviewer** | @hubot |
| **Agent Reviewers** | `pe-go` — opus (DEEP), `pe-vue` — opus (STANDARD)  — escalated, see § Tier Escalations |
| **SDLC Version** | @SDLC_VERSION@ |
| **Reviewed SHA** | `5d6e7f8` |
| **Gate Status** | MERGEABLE — all Gate 2 reviewers approved on current HEAD |
| **Tier** | STANDARD (classifier) → escalated, see § Tier Escalations · model-by-review-tier: on (CLI flag) · DEEP guard: engineer confirmed |
| **Routing** | web/src/components/LoginForm.vue → pe-vue (content: lockout message) |
| **Convergence Notes** | peer round recorded; Gate 1 streak unaffected |
| **Verdict** | ✅ APPROVED |
| **Date** | 2026-10-13 |

### Summary

Peer review on the PR. The bound query holds; one advisory note on logging.

### Acceptance-Criteria Conformance

AC conformance skipped: Gate 2 peer round (author-owned)

### Findings Overview

| Severity | In Scope | Out of Scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 1 | 0 |

### In Scope Findings

#### ℹ️ INFO-001: Username is logged at debug

**Domains:** [pe-go] · **Category:** general
**Location:** `internal/auth/limiter.go:31`

Usernames reach debug logs.

**Recommendation:** Log the username length instead of the username.

### Advisory Findings

- [INFO] INFO-001: Username is logged at debug — `internal/auth/limiter.go:31`

### Action Items

#### Must Fix (blocks merge)

- None

#### Should Fix

- None

#### Consider

- [ ] INFO-001: Username is logged at debug — `internal/auth/limiter.go:31`

### Dismissed Findings

- **Missing index hint** — the planner already picks the index scan (severity MEDIUM dropped)

### Rebuttals

- **Attempt limit constant** — engineer evidence: constant added in 5d6e7f8 — PE outcome: RESOLVED_AS_FALSE_POSITIVE

### Tier Escalations

- **pe-go**: STANDARD → DEEP — the limiter is shared by the API and the worker

### Verification Receipts

- **[indeterminate] Worker passes trusted input** at `internal/auth/store.go` — The issue says the worker passes usernames from the session table. (missing source: the worker service)
- pe-go: 'Username is logged at debug' — category missing/invalid, recorded as general

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)
