# Code Review — chore/transfer-org-urls

| Field | Value |
| - | - |
| **PR** | [#5](https://github.com/lafollett-labs/lafollettlabs-claude-plugins/pull/5) |
| **Author** | clafollett |
| **Reviewer** | Cali LaFollett |
| **Review Round** | 1 |
| **Reviewed SHA** | `3c32430` |
| **Target → Source** | `main` → `chore/transfer-org-urls` |
| **Approach** | Generic three-pass — no `.code-reviewer.yml`, no Stack Map, and the diff (JSON metadata + README + CHANGELOG) matches no PE file pattern |

## Verdict — ✅ APPROVED

| Severity | In scope | Out of scope |
| - | - | - |
| 🔴 CRITICAL | 0 | 0 |
| 🟠 HIGH | 0 | 0 |
| 🟡 MEDIUM | 0 | 0 |
| 🟢 LOW | 0 | 0 |
| ℹ️ INFO | 2 | 1 |

## Pass 1 — Architecture

Nothing structural moves. Every `source` in `marketplace.json` is a repo-relative
path (`./plugins/<name>`), so plugin resolution never went through the owner
string — the transfer could not have broken installs, and this diff cannot fix
or break them either. `owner.name` is already `LaFollett Labs LLC` and is
untouched.

The diff is a pure string substitution across 7 files, 11 lines. No collateral:
the only surviving `clafollett` reference in the entire repo is the PR #3 link in
`docs/code-reviews/`, which is deliberate.

## Pass 2 — Quality + Tests

No CI workflows exist in this repo, so there is no suite to run. Two checks stood
in:

```
$ claude plugin validate .
Validating marketplace manifest: .claude-plugin/marketplace.json
⚠ Found 1 warning:
  ❯ metadata.license: Unknown field 'license'. Claude Code ignores it at load time.
✔ Validation passed with warnings

$ python3 -c "import json; json.load(open(f))"   # ×6 manifests
all parse
```

The one warning is pre-existing on `main` and untouched by this diff — see
INFO-002.

## Pass 3 — Security

Supply chain is the only surface a marketplace URL rewrite touches, so it got the
full "would this survive a pentest" treatment rather than a shrug.

**Hypothesis raised and killed:** after a transfer, GitHub frees the old
`owner/name` for reuse, and re-creating it breaks the redirect. Anyone who ran
`/plugin marketplace add clafollett/lafollettlabs-claude-plugins` would then be
pulling from whatever sits at that path. That is a genuine attack against public
plugin marketplaces.

It does not apply here. `clafollett` is a **personal user account** owned by the
same person who owns the org:

```
$ gh api users/clafollett --jq '.type + " / " + .login'
User / clafollett
```

Only the account owner can create repositories under `clafollett/*`, so no third
party can occupy the retired path. The redirect is also live today:

```
$ git ls-remote https://github.com/clafollett/lafollettlabs-claude-plugins.git HEAD
b88df646179a31fa72d5c3817c5d5160771c09f6	HEAD
```

Residual exposure is limited to the `clafollett` account being renamed or
deleted, which would break every redirect at once. Recorded as INFO-001, not a
blocker.

## Findings

### ℹ️ INFO-001 — redirect durability depends on the personal account surviving
- **Location:** `.claude-plugin/marketplace.json`, `README.md:80`
- **In scope:** true
- Existing installs still reference `clafollett/...` and work only through
  GitHub's redirect. That redirect dies if the `clafollett` account is renamed or
  deleted. No action needed while the account exists; worth knowing before any
  future account rename.

### ℹ️ INFO-002 — pre-existing `metadata.license` validation warning
- **Location:** `.claude-plugin/marketplace.json:10`
- **In scope:** false (present on `main`, untouched by this diff)
- `claude plugin validate` reports `Unknown field 'license'`. Claude Code ignores
  it at load time. Harmless; fix in a separate chore if the warning is noise.

### ℹ️ INFO-003 — repo name is now redundant under the org
- **In scope:** false
- `lafollett-labs/lafollettlabs-claude-plugins` repeats the owner. `claude-plugins`
  would read better. A rename carries its own redirect considerations and is a
  separate decision — deliberately not bundled here.

## Resolved during review

The repo maintains a rigorous Keep-a-Changelog history, and the PR originally
shipped without an entry. Added in `3c32430` under `### Changed`, with no version
bumps since nothing behavioral moved.

---

Generated with Claude Code
