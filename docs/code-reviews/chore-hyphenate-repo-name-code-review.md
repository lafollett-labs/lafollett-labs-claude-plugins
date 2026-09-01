# Code Review — chore/hyphenate-repo-name

| Field | Value |
| - | - |
| **PR** | [#6](https://github.com/lafollett-labs/lafollett-labs-claude-plugins/pull/6) |
| **Author** | clafollett |
| **Reviewer** | Cali LaFollett |
| **Review Round** | 1 |
| **Reviewed SHA** | `HEAD of chore/hyphenate-repo-name` |
| **Target → Source** | `main` → `chore/hyphenate-repo-name` |
| **Approach** | Generic three-pass — no `.code-reviewer.yml`, no Stack Map, and the diff (JSON metadata + README + CHANGELOG) matches no PE file pattern |

## Verdict — ✅ APPROVED

| Severity | In scope | Out of scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 1 | 2 |

## Pass 1 — Architecture

The rename resolves a real inconsistency rather than a cosmetic one. The org
already carries a meaningful pattern:

| Repo | Prefixed | Kind |
| - | - | - |
| `lafollett-labs-llc` | yes | company scope |
| `lafollett-labs-workspace` | yes | company scope |
| `lafollett-labs-claude-plugins` | yes (this PR) | company scope |
| `riff` | no | standalone product |
| `lldb` | no | standalone product |

This repo was the sole outlier, and only on the hyphen. Dropping the prefix
entirely — the alternative considered — would have fixed a stutter by breaking a
pattern the other two company-scope repos already honour.

**The load-bearing decision in this PR is what it does NOT change.**
`marketplace.json`'s `"name"` is not a display label; it is the key the plugin
runtime installs and caches under. Ground truth from the live registry:

```
$ python3 -c "…installed_plugins.json…"
code-reviewer@lafollettlabs-claude-plugins  -> cache/lafollettlabs-claude-plugins/code-reviewer/2.9.0
issue-manager@lafollettlabs-claude-plugins  -> cache/lafollettlabs-claude-plugins/issue-manager/1.0.3
session-analyzer@lafollettlabs-claude-plugins -> …/session-analyzer/1.0.1
context-handoff@lafollettlabs-claude-plugins  -> …/context-handoff/1.1.3
ux-designer@lafollettlabs-claude-plugins      -> …/ux-designer/1.1.3
```

Two skills dereference that exact key at runtime —
`plugins/issue-manager/skills/issue-manager/SKILL.md:43` and
`plugins/session-analyzer/skills/session-analyzer/SKILL.md:37`. Renaming the
identifier alongside the repo would have re-keyed the registry out from under
them. Correctly left alone; repo name and package identifier are permitted to
diverge.

## Pass 2 — Quality + Tests

```
$ claude plugin validate .
✔ Validation passed with warnings
  ❯ metadata.license: Unknown field 'license'.   # pre-existing, see INFO-002
```

`metadata.version` stays `1.19.1` and no plugin version moves — correct, since
nothing behavioural changed. The CHANGELOG's prior `[Unreleased]` entry was
rewritten rather than appended to, so the section describes the end state
instead of contradicting itself across two entries about the same URLs.

## Pass 3 — Security

The redirect chain is now two hops deep — transfer, then rename. Chained
redirects are the kind of thing that is assumed to work and occasionally does
not, so it was measured rather than asserted:

```
clafollett/lafollettlabs-claude-plugins        7796f79…  HEAD
lafollett-labs/lafollettlabs-claude-plugins    7796f79…  HEAD
lafollett-labs/lafollett-labs-claude-plugins   7796f79…  HEAD
```

All three resolve to the same commit. Anyone who added the marketplace at either
older path keeps working.

Two paths are now freed. `clafollett/*` is a personal account and
`lafollett-labs/*` is an org, both controlled by the same owner, so neither
freed path can be occupied by a third party to hijack an existing
`/plugin marketplace add`.

## Findings

### ℹ️ INFO-001 — repo name and marketplace identifier now diverge
- **Location:** `.claude-plugin/marketplace.json:2`
- **In scope:** true
- Deliberate, and documented in the CHANGELOG. If the identifier is ever
  aligned, the migration is: change `name`, update both SKILL.md keys in the
  same commit, and re-add the marketplace on every machine. The silent-failure
  mode below is what makes that a poor trade today.

### ℹ️ INFO-002 — plugin-cache resolution fails silently
- **Location:** `plugins/issue-manager/skills/issue-manager/SKILL.md:43`, `plugins/session-analyzer/skills/session-analyzer/SKILL.md:37`
- **In scope:** false (pre-existing)
- A missing registry key yields `{}`, the `KeyError` is swallowed by
  `2>/dev/null`, and the `find ~/.claude/skills` fallback only matches manual
  installs. The variable ends up empty and the skill proceeds with an empty
  script path rather than reporting that it could not resolve one. Worth an
  issue: make the fallback loud, or derive the key instead of hardcoding it.

### ℹ️ INFO-003 — pre-existing `metadata.license` validation warning
- **Location:** `.claude-plugin/marketplace.json:10`
- **In scope:** false
- Unchanged from #5. `claude plugin validate` reports `Unknown field 'license'`;
  Claude Code ignores it at load time.

---

Generated with Claude Code
