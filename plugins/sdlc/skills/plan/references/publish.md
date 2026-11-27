# Publish Pipeline — prepare before, verify after

Loaded by `create`, `create-standalone` and `update`. gh-issues.js runs both steps through `bin/publish-body.js`; this file maps what they print to what to tell the user.

## prepare — before the first GitHub write

Every target file is prepared before any write: a Story, Task or Bug with no `## Test Plan` gets one appended (append-only; existing bytes and line endings kept), then every file is linted. A file that ends inside an unclosed code fence gets no Test Plan. A file that is not valid UTF-8 stops the run untouched.

| Printed | Meaning |
| - | - |
| `ℹ️ Test Plan written into: <files>` | those files changed on disk; commit them with the rest |
| `⚠️ <file>:<line> [<section>] second "## Test Plan" heading — keep one` | delete one of the two sections |
| `⚠️ <file>:<line> [<section>] code fence never closes …` | close the fence at that line |
| `🟡 Waiting on you — …` (exit 3) | nothing was published; `run_gi` asks the user |

## publish and verify — after each GitHub write

The file's H1 (minus an `Epic:|Story:|Task:|Bug:` label) is the title; the lines after it are the body, sent with `--body-file -`. After each write the issue body is read back and compared with the file, ignoring line endings and trailing whitespace.

| Printed | Meaning |
| - | - |
| `⚠️ #N: the stored body differs from <file> at body line L — sent "…", stored "…"` | GitHub holds something else; fix the file, then `update` |
| `⚠️ #N: readback check skipped (…)` | the readback failed; compare the issue with the file by hand |
| `; K readback finding(s) — fix the file, then run update` | suffix on the summary line |

## gh calls

| Step | Call |
| - | - |
| repo | `gh repo view --json nameWithOwner,url` |
| labels | `gh label list --json name --limit 1000`; missing → `gh label create <l> --color <hex> --description <d>` |
| create | `gh issue create --title <t> --label <type> [--label status:todo] --body-file -` |
| update | `gh issue edit <N> --title <t> --body-file -` |
| readback | `gh issue view <N> --json body` |
| link | `gh api repos/{o}/{r}/issues/<N>` → `.id`; `gh api -X POST repos/{o}/{r}/issues/<epic>/sub_issues -F sub_issue_id=<id>` |
| list children | `gh api 'repos/{o}/{r}/issues/<epic>/sub_issues?per_page=100' --paginate --slurp` |
| parent | `gh api repos/{o}/{r}/issues/<N>/parent` (404 "No parent issue found" = none) |
