# Code Review: 42

**Verdict:** 🚫 BLOCKED

| | |
| - | - |
| **Branch** | `feat/42-login-lockout` |
| **PR** | — |
| **Author** | @— |
| **Engineer Reviewer** | @octocat |
| **Agent Reviewers** | `pe-go` — opus (STANDARD), `pe-vue` — opus (STANDARD) |
| **SDLC Version** | @SDLC_VERSION@ |
| **Review Round** | 1 |
| **Reviewed SHA** | `1a2b3c4` |
| **Gate Status** | OPEN — need 2 more consecutive clean round(s) |
| **Tier** | STANDARD (classifier) · model-by-review-tier: off (default) |
| **Routing** | classifier globs — no judgment re-route |
| **Verdict** | 🚫 BLOCKED |
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

🤖 Generated with [Claude Code](https://claude.com/claude-code)
