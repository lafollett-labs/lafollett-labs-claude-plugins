# Nudge Flow

Loaded by `sdlc:pull-request` when Mode Detection selects the nudge path. Reminds reviewers about an idle PR: a thread reply on the original Slack announcement when Slack is enabled, else a PR comment that mentions the requested reviewers. Shares no state with the author path.

## Contents

- Step 1 — Verify the nudge is warranted
- Step 2 — Ping

## Step 1 — Verify the nudge is warranted

```text
# The nudge path skips Phase 1, so bind what it reads here.
if `gh auth status` fails:
  ❌ Error — gh not installed or not authenticated
  STOP — `gh auth login`
run settings.md's load_settings()                       # binds session.settings

p = `gh pr view {session.pr_number} --json state,url,title,comments,reviews,reviewRequests,updatedAt`
session.pr_url        = p.url
session.pr_title      = p.title
session.pr_activity   = len(p.comments) + len(p.reviews)
session.pr_updated_at = parse(p.updatedAt)
session.mentions      = ["@" + r.login for user requests in p.reviewRequests]
                        + ["@" + r.slug for team requests in p.reviewRequests]   # gh returns a team's slug as org/team

match (p.state, session.pr_activity, age(session.pr_updated_at)):
  case state != "OPEN":
    🛑 PR #{session.pr_number} is `{p.state}`; nudge does not apply
    STOP

  case (_, activity > 0, _):
    🟡 Waiting on you — existing activity
    AskUserQuestion → "PR #{session.pr_number} has {session.pr_activity} comment(s)/review(s) — nudge anyway?"; options:
      (no) "Don't nudge (recommended)"
      (yes) "Nudge anyway"
    if no: exit

  case (_, 0, age < 24h):
    🟡 Waiting on you — too soon
    AskUserQuestion → "Last activity on PR #{session.pr_number} {humanize(age)} ago — likely too soon. Nudge anyway?"; options:
      (no) "Don't nudge (recommended)"
      (yes) "Nudge anyway"
    if no: exit

  default: proceed
```

## Step 2 — Ping

```text
last_activity_relative = humanize(now - session.pr_updated_at)        # "3 days ago", "yesterday"
channel = resolve_channel()                                            # slack-templates.md § Channel Resolution

if channel is null:                                                    # Slack off (or its channel unusable): comment on the PR
  body = "**Nudge** — still open with no review activity since {last_activity_relative}."
         + (" " + join(session.mentions, " ") if session.mentions else "")
  AskUserQuestion → "Comment on PR #{session.pr_number}{" mentioning " + csv(session.mentions) if session.mentions else ""}?"; options:
    (yes) "Post the comment (recommended)"
    (no) "Skip — exit"
  if no: exit
  write body to a temp file <f>; `gh pr comment {session.pr_number} --body-file <f>`
  ✅ Done — nudge posted as a PR comment
    - PR:      #{session.pr_number} {session.pr_url}
    - Idle:    {last_activity_relative}
    - Mention: {csv(session.mentions) or "no requested reviewers — consider adding some"}
  exit

render the Nudge template with {pr_number} = session.pr_number, {title} = session.pr_title,
  {pr_url} = session.pr_url, {last_activity_relative}

if channel.id is null:                                                 # no Slack tool
  print the template file's Fallback copy-paste block (threaded-post wording)
  ✅ Done — nudge prepared (manual paste); exit

# Find the original announcement: most specific query first, each sorted by timestamp, then verified.
repo_name  = basename of `gh repo view --json nameWithOwner --jq .nameWithOwner`
queries    = ["\"{session.pr_url}\" in:#{channel.name}", "{repo_name} #{session.pr_number} in:#{channel.name}"]
candidates = dedupe(flatten(
  mcp__plugin_slack_slack__slack_search_public(query = q, sort = "timestamp", sort_dir = "desc") for q in queries),
  key = m.message_ts)
verified   = [m for m in candidates
              if session.pr_url in m.text or (repo_name in m.text and "#{session.pr_number}" in m.text)]

if verified is non-empty:
  session.parent_message_ts = min(verified, key = m.message_ts).message_ts   # the earliest match is the announcement
else:
  ⚠️ original PR Announcement not found in #{channel.name}
  AskUserQuestion → "Original PR Announcement not found in #{channel.name} — how to proceed?"; options:
    (a) "Top-level nudge (no thread parent)"
    (b) "Abort"
  match user_response:
    case (a): session.parent_message_ts = null
    case (b): exit

AskUserQuestion → "Nudge PR #{session.pr_number} in #{channel.name}?"; options:
  (yes) "Post nudge (recommended)"
  (no) "Skip — exit"
if no: exit

mcp__plugin_slack_slack__slack_send_message(
  channel_id      = channel.id,
  thread_ts       = session.parent_message_ts,      # null → top-level
  reply_broadcast = false,
  message         = rendered Nudge body
)

✅ Done — nudge posted
  - PR:      #{session.pr_number} {session.pr_url}
  - Idle:    {last_activity_relative}
  - Thread:  {"thread reply on " + session.parent_message_ts if non-null else "top-level (original announcement not found)"}
```
