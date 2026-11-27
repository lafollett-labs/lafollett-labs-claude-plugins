# Publish

Loaded by SKILL.md at Phase 7, after the round is persisted. Runs Steps 3–6: commit and push the review doc, the issue's progress comment (`post_comment` from issue-progress-comment.md), the PR comment and verdict, the optional Slack verdict (`resolve_channel` and the templates from slack-templates.md), and the stash restore — SKILL.md loads both alongside this file. Every `gh` call runs from `{session.review_root}`.

## Contents

- Step 3 — Confirm + commit
- Step 3.5 — AC-conformance progress comment (once per reviewed-SHA)
- Step 3.6 — Bug RCA progress comment (Bug tickets only; once per reviewed-SHA)
- Step 4 — PR comment + verdict (PR Reviews only)
- Step 5 — Slack post (optional, PR Reviews only)
- Step 6 — Stash restore

## Step 3 — Confirm + commit

```text
# review_branch is the reviewed branch — the worktree's branch in worktree mode, else the primary's
# current branch. All git ops run via `-C {session.review_root}`.
review_branch = `git -C "{session.review_root}" rev-parse --abbrev-ref HEAD`
session.review_committed = false
session.pushed_sha = null

if session.auto:                                    # unattended: commit + push the review doc without prompting
  🤖 Auto-resolved — committing + pushing review doc to {review_branch} (auto)
  user_response = "yes"
else:
  AskUserQuestion → "Review written to {output_path}. Verdict: {session.verdict}. Gate: {session.gate_status}. Ready to commit and push to {review_branch}?"; options:
    (yes) "Commit + push the review doc to {review_branch}"
    (no) "Leave it uncommitted on disk; skip the progress comment and the review-file link"

match user_response:
  case yes:
    git -C "{session.review_root}" add "{output_path}"
    if exists(session.ledger_path): git -C "{session.review_root}" add "{session.ledger_path}"
    git -C "{session.review_root}" commit -m "docs: {session.name} code-review"      # an ordinary commit — CI runs on it
    push = `git -C "{session.review_root}" push` if session.pr and session.pr.isCrossRepository   # gh's configured fork remote
           else `git -C "{session.review_root}" push origin "{review_branch}"`
    if push exits non-zero:                                                          # e.g. a fork PR without maintainer edits
      ⚠️ push failed — review doc committed locally on {review_branch} but NOT pushed.
      session.review_committed = false   # keep the worktree; SKILL.md Phase 7 will NOT offer worktree removal
      tell user to resolve (e.g. `git -C "{session.review_root}" pull --ff-only`, then re-push) before any teardown
    else:
      session.review_committed = true
      session.pushed_sha = `git -C "{session.review_root}" rev-parse HEAD`
  case no:
    skip commit + push; file remains on disk uncommitted
```

Commit to the reviewed branch (the PR's head branch for PR reviews, the feature branch for branch reviews). Never commit review files to `main` directly. In worktree mode the commit lands on the branch inside the worktree.

```text
review_file_url = "https://github.com/{session.repo}/blob/{session.pushed_sha}/{output_path relative to review_root}" if session.review_committed and session.repo else null
```

## Step 3.5 — AC-conformance progress comment (once per reviewed-SHA)

Writes the Phase 5.5 result (`session.ac_results`) as the `ac-conformance` section of the issue's progress comment — settled SHA only, never once per round. Reuses Phase 5.5 output verbatim; runs no new analysis.

```text
# Bound before either step's guards: Step 3.6 dedupes on it even when Step 3.5 skips.
session.rounds_now = (stdout of `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" parse --file "{output_path}"`).rounds if session.review_committed else []

if session.ticket_key is null OR session.ac_results is empty OR not session.review_committed:
  skip Step 3.5                 # no ticket / no Phase 5.5 output / review not durably recorded → no comment, no error

# Once-per-SHA dedupe: the on-disk review file is the only signal that survives fresh review invocations.
prior_sha_rounds = [r for r in session.rounds_now[:-1] if r.reviewed_sha is a prefix of session.head_sha or the reverse]
if prior_sha_rounds is non-empty:
  skip Step 3.5                 # this SHA already handled in an earlier round (a declined preview included)

glyph(status): "satisfied" → ✅ | "not-satisfied" → ❌ | "not-verifiable" → ⚠️
md_cell(x):    re.sub(r"[\r\n]+", " ", x).replace("|", "\|")   # AC text and evidence are untrusted free text

body = "### Acceptance-Criteria Conformance — `{session.head_sha}`\n"
       + a markdown table `| AC | Verdict | Evidence |`, one row per r in session.ac_results:
           | #{r.index} {md_cell(one-line r.ac)} | {glyph(r.status)} | {md_cell(r.evidence)} |

post_comment(session.ticket_key, body, "ac-conformance", session.auto, session.issue_number)
```

## Step 3.6 — Bug RCA progress comment (Bug tickets only; once per reviewed-SHA)

Writes a root-cause analysis for **Bug** tickets as the `bug-rca` section, built from the consolidated in-scope `is_pattern` findings and Phase 4's bug-shape grep output (each finding's `locations[]`).

```text
if session.ticket_type != "Bug" OR session.ticket_key is null OR not session.review_committed:
  skip Step 3.6
bug_findings = [f for f in consolidated if f.in_scope and f.is_pattern]
if bug_findings is empty:
  skip Step 3.6
prior_sha_rounds = [r for r in session.rounds_now[:-1] if r.reviewed_sha is a prefix of session.head_sha or the reverse]
if prior_sha_rounds is non-empty:
  skip Step 3.6

md_line(x): re.sub(r"[\r\n]+", " ", x)
body = "### Bug Root-Cause Analysis — `{session.head_sha}`\n"
for f in bug_findings:
  sites = dedupe([f.location] + (f.locations or []))       # primary + Phase-4 bug-shape grep sites
  body += "\n#### [{f.severity}] {f.title}\n"
  body += "- **Root cause:** {md_line(f.description)}\n"
  body += "- **Occurrence sites:** {', '.join(sites)}\n"
  body += "- **Fix:** {md_line(f.recommendation)}\n"

post_comment(session.ticket_key, body, "bug-rca", session.auto, session.issue_number)
```

## Step 4 — PR comment + verdict (PR Reviews only)

```text
if review_type != "PR Review": skip Step 4

if session.auto:
  🤖 Auto-resolved — posting the summary comment on PR #{session.pr.number}
  user_response = yes
else:
  AskUserQuestion → "Post a summary comment on PR #{session.pr.number}?"; options:
    (yes) "Post summary comment + apply the verdict"
    (no) "Skip PR comment + verdict"

match user_response:
  case yes:
    tmp = `mktemp -d`                    # OS temp dir, never the worktree
    write to "{tmp}/review-comment.md":
      verdict line + gate status
      "CI: {session.ci.state} — {session.ci.reason}" (Gate 2 only)
      in-scope counts by severity        # in-scope basis matches the Slack {issues_list}
      "[Review file]({review_file_url})" if review_file_url else "Review file not pushed — see {output_path} on the reviewer's machine"
      key in-scope findings (one line each, CRITICAL/HIGH/MEDIUM only)
      action items (Must Fix)
    out = `gh pr comment {session.pr.number} --body-file "{tmp}/review-comment.md"`
    session.pr_comment_url = the first https URL containing "#issuecomment-" in out, else session.pr.url

    if session.pr.author.login == session.reviewer_username:
      ℹ️ Own PR — the verdict stands as the comment; GitHub has no self-review approval
    else:
      write "{session.verdict} — full summary: {session.pr_comment_url}" to "{tmp}/review-verdict.md"
      match session.verdict:
        case "✅ APPROVED" if session.ci_hold:   # Gate 2 CI hold (references/ci-gate.md): never approve over unfinished or unread checks
          ⏳ PR approval withheld — {session.gate_status}; {CI_NEXT[session.ci.state]}
            # CI_NEXT: pending → "re-run Gate 2 once the checks finish"
            #          incomplete → "re-run the cancelled checks, then re-run Gate 2"
            #          unreadable → "fix the gh error, then re-run Gate 2"
            #          any other state (a gate2 status error) → "fix the gate2 error, then re-run Gate 2"
        case "✅ APPROVED":
          expected = session.pushed_sha or session.head_sha
          head_now = `gh pr view {session.pr.number} --json headRefOid --jq .headRefOid`
          if head_now != expected:
            ⚠️ PR head advanced to {head_now} since review — not approving unreviewed code: {session.pr.url}
          else:
            `gh pr review {session.pr.number} --approve --body-file "{tmp}/review-verdict.md"`
        case "⚠️ CHANGES REQUESTED" | "🚫 BLOCKED":
          `gh pr review {session.pr.number} --request-changes --body-file "{tmp}/review-verdict.md"`
      if the gh pr review call exited non-zero (e.g. HTTP 422):
        ⚠️ verdict not applied — {stderr}; set it in the PR UI: {session.pr.url}; continue

  case no:
    skip PR comment + verdict
    session.pr_comment_url = session.pr.url
```

## Step 5 — Slack post (optional, PR Reviews only)

```text
if review_type != "PR Review" or not session.settings.slack.enabled: skip Step 5
channel = resolve_channel()                    # null → slack disabled, no channel, or channel not found
if channel is null: skip Step 5

message = the slack-templates.md "Review Verdict" template — Approved, or Changes Requested / Blocked — with
  pr_number = session.pr.number, title = session.pr.title, pr_url = session.pr.url,
  issues_list per its Variable table, pr_comment_url = session.pr_comment_url,
  review_file_url = review_file_url from Step 3, else session.pr.url
if channel.id is null:
  print message in the slack-templates.md § Fallback copy-paste block; skip Step 5

# Thread under the PR Announcement: newest-first search, trusted only when the text holds the PR URL.
candidates = mcp__plugin_slack_slack__slack_search_public(query="\"{session.pr.url}\" in:#{channel.name}", sort="timestamp", sort_dir="desc")
verified   = [m for m in candidates if session.pr.url in m.text]
parent_ts  = min(verified, key=m.message_ts).message_ts if verified else null   # oldest verified = the announcement; none → top-level

if session.auto:
  🤖 Auto-resolved — posting the review verdict to #{channel.name} ({"thread" if parent_ts else "top-level: no announcement found"})
  user_response = yes
else:
  AskUserQuestion → "Post the review verdict to #{channel.name}?"; options:
    (yes) "Post it"
    (no) "Skip Slack post"
if yes:
  mcp__plugin_slack_slack__slack_send_message(channel_id = channel.id, thread_ts = parent_ts, reply_broadcast = false, message = message)
  report the posted message_ts; on failure ⚠️ report and continue
```

## Step 6 — Stash restore

```text
if session.stash_ref:
  git stash pop
  if pop fails (conflicts):
    git stash apply
    tell user: "Stash {session.stash_ref} could not be popped cleanly. It is still in your stash list — resolve conflicts and run `git stash drop` manually."
```

Always run Step 6, regardless of Step 3/4/5 answers.
