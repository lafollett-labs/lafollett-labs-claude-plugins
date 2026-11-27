# Issue Status + Slack Announcement

Loaded by `sdlc:pull-request` for Phases 8 and 9. Reads `session.intent_gate`, `session.slack_on`, `session.slack_caveat`, and `session.slack_copilot_line`.

## Phase 8 — Issue Status

```text
if session.issue_number is null:
  ⚠️ Warning — no GitHub issue for this branch ({"story " + session.ticket_key + " links none" if session.ticket_key else "no ticket key"}); label and progress comment skipped
  exit Phase 8
if session.pr_url is null: exit Phase 8

if session.intent_gate == "(b) manual":
  🟡 Waiting on you — mark the issue in review?
  AskUserQuestion → "Label #{session.issue_number} status:in-review and update its progress comment?"; options:
    (yes) "Update now (recommended)"
    (no) "Skip — exit Phase 8"
  if no: exit Phase 8

session.status_move = set_status(session.ticket_key, session.issue_number, "in-review")   # issue-status-labels.md; never blocks

body  = "### 📦 Pull request opened — #{session.pr_number}\n\n"
body += "**Pull request:** {session.pr_url}\n\n"
body += "**Changes:**\n{session.summary_bullets}\n\n"
body += "**Files:** {session.file_stats.files} changed (+{session.file_stats.added} / −{session.file_stats.removed})\n"
if session.pr_test_plan is non-empty:                    # null when Phase 5 fell back to the generic bullet
  body += "\n**Testing strategy:**\n{session.pr_test_plan}\n"
if session.slack_caveat is not null:
  body += "\n" + (each line of session.slack_caveat as a "> {line}" blockquote)

post_comment(session.ticket_key, body, "impl-summary", session.auto, session.issue_number)   # issue-progress-comment.md; never blocks
```

---

## Phase 9 — Slack Announcement

Runs once, after Phase 7 settles, so reviewers are pinged on the settled head.

```text
if not session.slack_on: exit Phase 9                      # slack.enabled is false, or --no-slack
channel = resolve_channel()                                # slack-templates.md § Channel Resolution
if channel is null: exit Phase 9

render the PR Announcement template per its Variable Reference, with:
  {pr_number} = session.pr_number · {title} = session.pr_title · {pr_url} = session.pr_url
  {branch} = session.branch · {base_branch} = session.base_branch
  {files_changed}, {added}, {removed} = session.file_stats
  {copilot_line} = session.slack_copilot_line              # omit the line when null
  {caveat_line}  = session.slack_caveat                    # omit the line when null

if channel.id is null:                                     # no Slack tool
  print the template file's Fallback copy-paste block; exit Phase 9

if session.intent_gate == "(b) manual":
  🟡 Waiting on you — post to #{channel.name}?
  AskUserQuestion → "Post the PR Announcement to #{channel.name}?"; options:
    (yes) "Post now (recommended)"
    (no) "Skip the announcement"
  if no: exit Phase 9

mcp__plugin_slack_slack__slack_send_message(channel_id = channel.id, message = rendered PR Announcement)
session.slack_message_ts = response.message_ts
report: "PR Announcement posted to #{channel.name} (ts={session.slack_message_ts}) — nudges thread on this post."
```
