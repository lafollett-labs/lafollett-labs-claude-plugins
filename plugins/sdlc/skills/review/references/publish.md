# Publish

Loaded by SKILL.md at Phase 7, after the round is persisted. Runs Steps 3–6: commit and push a Gate 1 review doc, the issue's progress comment (`post_comment` from issue-progress-comment.md), the PR comment and verdict, the optional Slack verdict (`resolve_channel` and the templates from slack-templates.md), and the stash restore — SKILL.md loads both alongside this file. `same_code` and `restore_stash()` are SKILL.md § Shared routines. Every `gh` call runs from `{session.review_root}`.

## Contents

- Step 3 — Commit the Gate 1 review doc
- Step 3.5 — AC-conformance progress comment (once per reviewed code)
- Step 3.6 — Bug RCA progress comment (Bug tickets only; once per reviewed code)
- Step 4 — PR comment + verdict (PR Reviews only)
- Step 5 — Slack post (optional, PR Reviews only)
- Step 6 — Stash restore

## Step 3 — Commit the Gate 1 review doc

A Gate 2 round never commits or pushes to the author's branch: its record is Step 4's comment and review, and its doc stays local.

```text
review_branch = `git -C "{session.review_root}" rev-parse --abbrev-ref HEAD`    # the worktree's branch in worktree mode
default_branch = `git -C "{session.review_root}" symbolic-ref --quiet --short refs/remotes/origin/HEAD` minus "origin/", else "main"
session.review_committed = false; session.pushed_sha = null
skip = "Gate 2 never commits to the author's branch" if session.gate == "Gate 2"
       else "pasted code has no branch" if review_type == "Ad-hoc"
       else "HEAD is detached" if review_branch == "HEAD"
       else "{review_branch} is the default branch" if review_branch == default_branch
       else null

if skip:
  📝 Review written to {output_path} — not committed ({skip})
elif session.auto:                                  # unattended: commit + push the review doc without prompting
  🤖 Auto-resolved — committing + pushing the review doc to {review_branch} (auto)
  user_response = yes
else:
  AskUserQuestion → "Review written to {output_path}. Verdict: {session.verdict}. Gate: {session.gate_status}. Commit and push it to {review_branch}?"; options:
    (yes) "Commit + push the review doc to {review_branch}"
    (no) "Leave it uncommitted on disk; skip the progress comment and the review-file link"

if not skip and user_response == yes:
  paths = ["{output_path}"] + (["{session.ledger_path}"] if session.ledger_path and exists(session.ledger_path) else [])
  git -C "{session.review_root}" add -- {paths quoted}
  commit = `git -C "{session.review_root}" commit -m "docs: {session.name} code-review" -- {paths quoted}`   # only the review paths, never other staged changes; an ordinary commit — CI runs on it
  if commit exits non-zero:
    ⚠️ commit failed — {stderr}; the review stays uncommitted at {output_path}
  elif session.pr and session.pr.isCrossRepository:   # the branch lives on the author's fork
    ⚠️ committed on {review_branch}, not pushed — push it to your fork's {session.pr.headRefName}, e.g. `git push <fork remote> HEAD:{session.pr.headRefName}`
  elif `git -C "{session.review_root}" push origin "{review_branch}"` exits non-zero:
    ⚠️ push failed — review doc committed locally on {review_branch} but NOT pushed; resolve (e.g. `git -C "{session.review_root}" pull --ff-only`, then re-push) before any teardown
  else:
    session.review_committed = true
    session.pushed_sha = `git -C "{session.review_root}" rev-parse HEAD`

review_file_url = "https://github.com/{session.repo}/blob/{session.pushed_sha}/{output_path relative to review_root}" if session.review_committed and session.repo else null
```

## Step 3.5 — AC-conformance progress comment (once per reviewed code)

Writes the Phase 5.5 result (`session.ac_results`) as the `ac-conformance` section of the issue's progress comment — once per reviewed code, never once per round. Reuses Phase 5.5 output verbatim; runs no new analysis.

```text
# Bound before either step's guards: Step 3.6 dedupes on them even when Step 3.5 skips.
session.rounds_now = (stdout of `node "${CLAUDE_PLUGIN_ROOT}/skills/review/bin/review-file.js" parse --file "{output_path}"`).rounds if session.review_committed else []
prior_same = [r for r in session.rounds_now[:-1] if same_code(r.reviewed_sha, session.head_sha)]   # once-per-code dedupe: the on-disk review file is the only signal that survives fresh invocations

if session.ticket_key is null OR session.ac_results is empty OR not session.review_committed:
  skip Step 3.5                 # no ticket / no Phase 5.5 output / review not durably recorded → no comment, no error
if prior_same is non-empty:
  skip Step 3.5                 # this code was already handled in an earlier round (a declined preview included)

glyph(status): "satisfied" → ✅ | "not-satisfied" → ❌ | "not-verifiable" → ⚠️
md_cell(x):    re.sub(r"[\r\n]+", " ", x).replace("|", "\|")   # AC text and evidence are untrusted free text

body = "### Acceptance-Criteria Conformance — `{session.head_sha}`\n"
       + a markdown table `| AC | Verdict | Evidence |`, one row per r in session.ac_results:
           | #{r.index} {md_cell(one-line r.ac)} | {glyph(r.status)} | {md_cell(r.evidence)} |

post_comment(session.ticket_key, body, "ac-conformance", session.auto, session.issue_number)
```

## Step 3.6 — Bug RCA progress comment (Bug tickets only; once per reviewed code)

Writes a root-cause analysis for **Bug** tickets as the `bug-rca` section, built from the consolidated in-scope `is_pattern` findings and Phase 4's bug-shape grep output (each finding's `locations[]`).

```text
if session.ticket_type != "Bug" OR session.ticket_key is null OR not session.review_committed:
  skip Step 3.6
bug_findings = [f for f in consolidated if f.in_scope and f.is_pattern]
if bug_findings is empty:
  skip Step 3.6
if prior_same is non-empty:
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
session.pr_comment_url = null

if session.auto:
  🤖 Auto-resolved — posting the summary comment on PR #{session.pr.number}
  user_response = yes
else:
  AskUserQuestion → "Post a summary comment on PR #{session.pr.number}?"; options:
    (yes) "Post summary comment + apply the verdict"
    (no) "Skip PR comment + verdict" + (" — this round then exists only in {output_path}" if session.gate == "Gate 2" else "")

if user_response == yes:
  tmp = `mktemp -d`                    # OS temp dir, never the worktree
  write to "{tmp}/review-comment.md":
    verdict line + gate status
    "CI: {session.ci.state} — {session.ci.reason}" (Gate 2 only)
    "{session.gate1_skip_note}" if session.gate1_skip_note
    in-scope counts by severity        # in-scope basis matches the Slack {issues_list}
    "[Review file]({review_file_url})" if review_file_url else "Gate 2 review — this comment is the round's record" if session.gate == "Gate 2" else "Review file not pushed — see {output_path} on the reviewer's machine"
    key in-scope findings (one line each, CRITICAL/HIGH/MEDIUM only)
    action items (Must Fix)
  out = `gh pr comment {session.pr.number} --body-file "{tmp}/review-comment.md"`
  if exit != 0:
    ⚠️ PR comment not posted — {stderr}; the verdict below carries the summary itself
  else:
    session.pr_comment_url = the first https URL containing "#issuecomment-" in out, else session.pr.url

  if lower(session.pr.author.login) == lower(session.reviewer_username):
    ℹ️ Own PR — the verdict stands as the comment; GitHub has no self-review approval
  else:
    write to "{tmp}/review-verdict.md": "{session.verdict} — full summary: {session.pr_comment_url}" if session.pr_comment_url else the contents of "{tmp}/review-comment.md"
    match session.verdict:
      case "✅ APPROVED" if session.ci_hold:   # Gate 2 CI hold (references/ci-gate.md): never approve over unfinished or unread checks
        ⏳ PR approval withheld — {session.gate_status}; {CI_NEXT[session.ci.state]}
          # CI_NEXT: pending → "re-run Gate 2 once the checks finish"
          #          incomplete → "re-run the cancelled checks, then re-run Gate 2"
          #          unreadable → "fix the gh error, then re-run Gate 2"
          #          any other state (a gate2 status error) → "fix the gate2 error, then re-run Gate 2"
      case "✅ APPROVED":
        git -C "{session.review_root}" fetch --quiet origin "refs/pull/{session.pr.number}/head"
        head_now = `gh pr view {session.pr.number} --json headRefOid --jq .headRefOid`
        if not same_code(head_now, session.head_sha):
          ⚠️ PR head {head_now} changed code since the review — not approving unreviewed code: {session.pr.url}
        else:
          `gh pr review {session.pr.number} --approve --body-file "{tmp}/review-verdict.md"`
      case "⚠️ CHANGES REQUESTED" | "🚫 BLOCKED":
        `gh pr review {session.pr.number} --request-changes --body-file "{tmp}/review-verdict.md"`
    if the gh pr review call exited non-zero (e.g. HTTP 422):
      ⚠️ verdict not applied — {stderr}; set it in the PR UI: {session.pr.url}; continue
  rm -f "{tmp}/review-comment.md" "{tmp}/review-verdict.md"; rmdir "{tmp}"
```

## Step 5 — Slack post (optional, PR Reviews only)

```text
if review_type != "PR Review" or not session.settings.slack.enabled: skip Step 5
channel = resolve_channel()                    # null → slack disabled, no channel, or channel not found
if channel is null: skip Step 5

message = the slack-templates.md "Review Verdict" template — Approved, or Changes Requested / Blocked — with
  pr_number = session.pr.number, title = session.pr.title, pr_url = session.pr.url,
  issues_list per its Variable table, pr_comment_url = session.pr_comment_url or session.pr.url,
  review_file_url = review_file_url from Step 3, else session.pr_comment_url, else session.pr.url
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

Always run `restore_stash()`, whatever the Step 3/4/5 answers.
