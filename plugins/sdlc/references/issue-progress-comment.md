# Issue Progress Comment

Loaded on demand to write ONE section of an issue's progress comment. Each issue has one sdlc comment, whose body starts `<!-- sdlc:progress -->`; a post replaces its kind's section in place, or appends it, and edits that one comment. Never blocks the caller.

Inputs from the caller:

| Input | Meaning |
| - | - |
| `ticket_key` | `#42` or a story code (`LT-02`) |
| `comment_body` | the markdown section to write |
| `comment_kind` | `work-started` \| `plan-review` \| `ac-conformance` \| `bug-rca` \| `impl-summary` |
| `auto` | skip the preview/confirm gate when true (`--auto`) |
| `issue_number` | OPTIONAL; the issue a story code's file links. A `#N` key supplies its own |
| `session.gh_ok`, `session.repo` | bound by github-preflight.md |

## Comment layout

```markdown
<!-- sdlc:progress -->
### sdlc progress

<!-- sdlc:work-started -->
{comment_body}
<!-- /sdlc:work-started -->

<!-- sdlc:ac-conformance -->
{comment_body}
<!-- /sdlc:ac-conformance -->
```

Sections keep the order they were first written in; a later post of the same kind replaces that section only.

## Behavior

`{owner}/{repo}` in the `gh api` paths below is gh's own placeholder, filled from the checkout; leave it literal.

```text
post_comment(ticket_key, comment_body, comment_kind, auto, issue_number=null):
  n = issue_number if issue_number is not null
      else int(ticket_key[1:]) if ticket_key matches ^#[1-9][0-9]*$
      else null
  if n is null:
    log "no GitHub issue for {ticket_key}; progress comment skipped"; return
  if comment_body is empty:
    warn "nothing to post"; return
  if not session.gh_ok or session.repo is null:
    warn "gh unavailable; progress comment for #{n} skipped"; return

  ids = `gh api repos/{owner}/{repo}/issues/{n}/comments --paginate --jq '.[] | select(.body | startswith("<!-- sdlc:progress -->")) | .id'`
  if that exits non-zero:
    warn "cannot read #{n}'s comments; progress comment skipped"; return
  id      = first line of ids, else null                  # oldest marker comment
  old     = `gh api repos/{owner}/{repo}/issues/comments/{id} --jq .body` if id else "<!-- sdlc:progress -->\n### sdlc progress"
  section = "<!-- sdlc:{comment_kind} -->\n{comment_body}\n<!-- /sdlc:{comment_kind} -->"
  body    = old with the text from "<!-- sdlc:{comment_kind} -->" through "<!-- /sdlc:{comment_kind} -->" replaced by section
            if old holds both markers, else old + "\n\n" + section

  if not auto:
    preview: section, "#{n}", ("edit the progress comment" if id else "new progress comment")
    if not confirm(): return

  f = `mktemp`                                            # OS temp dir, never the worktree
  try:
    write body to f
    if id: `gh api -X PATCH repos/{owner}/{repo}/issues/comments/{id} -F body=@{f}`
    else:  `gh issue comment {n} --body-file {f}`
    if it exits non-zero:                                 # one attempt, never retried: a retried create can duplicate the comment
      warn "progress comment on #{n} failed ({first stderr line}); it may or may not have landed — check the issue"
  finally:
    `rm -f '{f}'`
```
