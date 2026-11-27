# Slack Message Templates

Every Slack post `sdlc:review`, `sdlc:pull-request` and `sdlc:deliver` make. Slack is opt-in: with `session.settings.slack.enabled` false (references/settings.md) every Slack step is a no-op, posts nothing and prints no copy-paste block.

**Every post is a brief pointer**: a status plus a link to where the detail already lives (the PR, its diff, the PR comment, the code-review file). Never restate the PR title as a summary, enumerate findings, recap changes, or add commentary. A post these templates do not cover follows the same rule; there is no freeform automated post. Posts carry no `@`-mentions or team tags.

## Contents

- Message Format
- Channel Resolution
- PR Announcement
- Review Verdict
- Author Review-Loop Reply
- Nudge
- Fallback — Manual Copy-paste Block

## Message Format

```text
templates: standard markdown        # **bold**, _italic_, `code`, [text](url), ~~strike~~
tool:      mcp__plugin_slack_slack__slack_send_message   # converts standard markdown to Slack mrkdwn at send time
```

### Link formatting (required)

- Always use bounded links, `[label](url)`; never post a bare URL.
- Never put a URL directly against an `:emoji:` shortcode or any other non-whitespace token: a bare URL's auto-link absorbs the trailing characters, across line breaks too.

```text
❌ :link: https://github.com/octo-org/octo-repo/pull/57        (bare URL; a :ticket: on the next line joins the href)
✅ [PR #57](https://github.com/octo-org/octo-repo/pull/57) · [#42](https://github.com/octo-org/octo-repo/issues/42)
```

## Channel Resolution

`resolve_channel()` is the only way a post site picks its channel. Post sites pass `channel.id` as `channel_id`; search sites pass `channel.name` as `in:#{channel.name}`.

```text
resolve_channel():                      # → {id, name}, or null = skip every Slack step
  if not session.settings.slack.enabled: return null
  name = trim(session.settings.slack.channel) without a leading "#"
  if name == "":
    ⚠️ Warning — slack.enabled is true but slack.channel is empty; Slack steps are skipped
    return null
  session.slack_ok = (mcp__plugin_slack_slack__slack_send_message is in the available tool list)
  if not session.slack_ok: return {id: null, name}          # Fallback copy-paste block only
  hit = the result of mcp__plugin_slack_slack__slack_search_channels(query = name) whose name == name
  if hit is null:
    ⚠️ Warning — Slack channel #{name} not found; Slack steps are skipped
    return null
  return {id: hit.id, name}
```

When the user asks to post somewhere else for one run:

| Destination | Resolve | `channel_id` | Threading |
| - | - | - | - |
| another channel | `mcp__plugin_slack_slack__slack_search_channels` → `id` | channel id | top-level post |
| a DM | `mcp__plugin_slack_slack__slack_search_users` → `id` | the user's id (Slack opens the IM) | none |
| several DMs | each user as above, one message per user | each user's id | none |

## PR Announcement

**Context:** posted once the PR is open and any Copilot review has settled, so reviewers start on the final head.

**Posted as:** top-level message in `#{channel.name}`. Capture `message_ts`: the Review Verdict, Author Review-Loop Reply and Nudge thread onto it.

```text
**New PR** — #{pr_number} [{title}]({pr_url})
Branch `{branch}` → `{base_branch}` · {files_changed} files, +{added}/-{removed}
{copilot_line}
{caveat_line}
```

`{copilot_line}` and `{caveat_line}` are omitted entirely (no blank line) when unset.

| Variable | Source |
| - | - |
| `{pr_number}`, `{title}`, `{pr_url}` | `gh pr view --json number,title,url` |
| `{branch}`, `{base_branch}` | `gh pr view --json headRefName,baseRefName` |
| `{files_changed}`, `{added}`, `{removed}` | `gh pr view --json changedFiles,additions,deletions` |
| `{copilot_line}` | Optional: `Copilot: {rounds} round(s) · {fixed} fixed`, plus ` · {open} open` when Copilot threads stay unresolved; from `sdlc:pull-request`'s Copilot step. Omitted when Copilot did not review. |
| `{caveat_line}` | Optional runtime risk flags, one per line: `⚠️ No Gate 1 self-review lock — author override: {reason}`, `⚠️ Review was at {short_sha}; HEAD has moved since.`, or a CI caveat from the CI gate (`⚠️ CI FAILED …` on a red head, `⚠️ CI has not validated this PR head …` when no check ran). |

## Review Verdict

**Context:** posted by the reviewer (or the agent acting for them) after a review completes: the verdict, severity counts, and links to the PR comment and the code-review file.

**Posted as:** thread reply on the PR Announcement (`thread_ts` = its `message_ts`), `reply_broadcast: false`; top-level when no announcement is found.

### Changes Requested / Blocked

```text
**{verdict_emoji} {verdict}** — PR #{pr_number} [{title}]({pr_url})
Issues:
{issues_list}
See the [PR comment]({pr_comment_url}) for a summary, with full details in the [code-review file]({review_file_url}).
```

### Approved

```text
**✅ APPROVED** — PR #{pr_number} [{title}]({pr_url})
No blocking findings — LGTM.
Details: [PR comment]({pr_comment_url}) · [code-review file]({review_file_url})
```

| Variable | Source |
| - | - |
| `{verdict_emoji}`, `{verdict}` | `✅ APPROVED` · `⚠️ CHANGES REQUESTED` · `🚫 BLOCKED` |
| `{pr_number}`, `{title}`, `{pr_url}` | as PR Announcement |
| `{issues_list}` | One bullet per non-zero in-scope gating severity, highest first: `- {SEVERITY} — {count}` (e.g. `- HIGH — 2`). Zero counts are omitted; no per-finding lines. |
| `{pr_comment_url}` | the URL `gh pr comment` printed for the verdict comment (`…#issuecomment-…`); else `{pr_url}` |
| `{review_file_url}` | `https://github.com/{session.repo}/blob/{head_branch}/docs/code-reviews/{key_slug}-code-review.md` |

## Author Review-Loop Reply

**Context:** posted by the PR author (or the agent acting for them) after pushing fixes for a reviewer's findings, only when a PR Announcement thread exists.

**Posted as:** thread reply on the PR Announcement, `reply_broadcast: false`.

```text
Addressed {finding_ref} in `{fix_sha}` — ready for re-review.
```

| Variable | Source |
| - | - |
| `{finding_ref}` | the addressed finding ids from the code-review file (e.g. `MEDIUM-001, HIGH-002`); else the literal `review findings` |
| `{fix_sha}` | `git rev-parse --short HEAD` |

## Nudge

**Context:** posted when a PR has had no review activity for an extended period.

**Posted as:** thread reply on the PR Announcement, `reply_broadcast: false`.

```text
**Nudge** — PR #{pr_number} [{title}]({pr_url}) still open with no review activity since {last_activity_relative}.
```

| Variable | Source |
| - | - |
| `{pr_number}`, `{title}`, `{pr_url}` | as PR Announcement |
| `{last_activity_relative}` | human-readable age, e.g. `3 days ago`, `yesterday` |

## Fallback — Manual Copy-paste Block

When `channel.id` is null (no Slack tool), the user pastes the message into Slack, which renders Slack mrkdwn. Transform the rendered template first:

```text
**bold**       → *bold*
[text](url)    → <url|text>
- list item    → • list item
~~strike~~     → ~strike~
_italic_       → _italic_       # unchanged
`code`         → `code`         # unchanged
```

Then print it in this fence, with `{channel.name}` rendered:

```text
─── Copy-paste into #{channel.name} ─────────────────

{rendered message — Slack mrkdwn}

─────────────────────────────────────────────────────
```

Tell the user: `Slack tools not available. Paste the block above into #{channel.name}.` For a threaded post add: `Post it as a reply to the PR #{pr_number} announcement if you can find it, or as a new top-level message.`
