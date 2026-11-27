# Reviewers

Loaded by `sdlc:pull-request` Phase 4. Binds `session.reviewers` (GitHub logins, or `org/team` slugs) and `session.reviewers_source`.

## Resolve

```text
LOGIN = ^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$          # a GitHub user
TEAM  = ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$               # an org/team slug

candidates = session.settings.pullRequest.reviewers
session.reviewers_source = "settings"

if candidates is empty:
  owners_file = first existing of .github/CODEOWNERS, CODEOWNERS, docs/CODEOWNERS   # GitHub's own lookup order
  if owners_file:
    changed = `git diff --name-only 'origin/{session.base_branch}...HEAD'`
    for each path in changed:
      the LAST line of owners_file whose pattern matches path wins (gitignore-style patterns; blank and # lines skipped)
      candidates += that line's owners
    session.reviewers_source = "CODEOWNERS ({owners_file})"

candidates = unique(c with a leading "@" removed for c in candidates)   # an email owner has no GitHub login: drop it
candidates = [c for c in candidates if lower(c) != lower(session.author)]   # GitHub refuses the author as a reviewer
for c in candidates not matching LOGIN or TEAM:
  ⚠️ Warning — ignoring reviewer '{c}' (not a GitHub login or org/team)
session.reviewers = candidates matching LOGIN or TEAM
```

## Confirm

```text
if session.reviewers is empty:
  if session.auto:
    🤖 Auto-resolved — no reviewers from settings or CODEOWNERS; opening the PR without reviewers
    continue to Phase 5
  🟡 Waiting on you — no reviewers
  AskUserQuestion → "No reviewers from settings or CODEOWNERS for {session.branch} — who should review?"; options:
    (none) "Open the PR without reviewers"
    (abort) "Abort"
  free-text "Other" reply → comma-separated logins or org/team slugs; run them through the filters above, then re-confirm
  match user_response:
    case none:  continue to Phase 5
    case abort: exit

else:
  if session.auto:
    🤖 Auto-resolved — reviewers accepted (auto, from {session.reviewers_source}): {csv of session.reviewers}
    continue to Phase 5
  🟡 Waiting on you — reviewer confirmation
    Assignee:  @{session.author}
    Reviewers: {csv of session.reviewers}   (from {session.reviewers_source})
  AskUserQuestion → "Request review from these reviewers on {session.branch}?"; options:
    (yes) "Proceed (recommended)"
    (abort) "Abort"
  free-text "Other" reply → a replacement comma-separated list; run it through the filters above, then re-confirm
  match user_response:
    case yes:   continue to Phase 5
    case abort: exit
```
