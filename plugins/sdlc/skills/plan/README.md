# sdlc:plan

Write Epics, Stories, Tasks and Bugs as Markdown in your repo, publish them as GitHub issues, and keep the two in sync. An epic's children become its GitHub sub-issues. Issues say **what** and **why**, never **how**: the templates and the quality check keep implementation detail out.

Replaces the `issue-manager` plugin. Needs `gh` (authenticated) and `node` on `PATH`.

## Usage

```text
/sdlc:plan init --name "Book Search"                       # scaffold docs/epics/004-book-search/
/sdlc:plan init --name "Book Search" --from docs/adr/0007.md  # draft the epic and its stories from an ADR
/sdlc:plan create --docs-path docs/epics/004-book-search   # publish, link sub-issues, write state + README
/sdlc:plan update --docs-path docs/epics/004-book-search   # push edited files to the same issues
/sdlc:plan import --epic 41                                # pull an epic and its sub-issues down to Markdown
/sdlc:plan status --docs-path docs/epics/004-book-search   # live status rollup
/sdlc:plan reparent --key 42 --parent 7                    # move #42 under epic #7 (omit --parent to clear)
/sdlc:plan create-standalone --file docs/epics/standalone/Rotate-Key.md --type task
/sdlc:plan bdd --type story --file docs/epics/004-book-search/01-Story-Search-By-Title.md
/sdlc:plan validate --file docs/epics/004-book-search/01-Story-Search-By-Title.md
/sdlc:plan validate --issue 42                             # is this issue too implementation-heavy?
```

## What lands in your repo

```text
docs/epics/004-book-search/
  00-Epic-Book-Search.md
  01-Story-Search-By-Title.md
  02-Task-Rotate-Signing-Key.md
  .github-state.json      # file name → issue number
  README.md               # generated rollup with links
```

## Tips

- **The file is the issue.** Its first heading is the title, the rest is the body. Edit the file and run `update`; edits made on GitHub are overwritten unless you `import` first.
- **`create` is safe to re-run.** It skips what `.github-state.json` already maps, links any child that lost its sub-issue link, and resumes after a failure.
- **Stories get a Test Plan.** Before publishing, a Story, Task or Bug without a `## Test Plan` gets one built from its scenarios; `sdlc:pull-request` copies it into the PR.
- **New issues start at `status:todo`.** `sdlc:implement` and `sdlc:pull-request` move them on.
- **It stops after publishing.** No branches, no code: that is `sdlc:implement`'s job.

## Moving from issue-manager

| issue-manager | sdlc:plan |
| - | - |
| `init --name "X"` | `init --name "X"` |
| `create --docs-path <dir>` | `create --docs-path <dir>` (children become sub-issues) |
| `update --docs-path <dir> [--file <f>]` | `update --docs-path <dir> [--file <f>]` |
| `import --epic 582` | `import --epic 582` (also reads the old "Part of Epic" links) |
| `status --docs-path <dir>` | `status --docs-path <dir>` (live GitHub status) |
| quality checklist review | `validate --file <f>` or `validate --issue <N>` |
| ADR → epic | `init --name "X" --from <adr>` |

Existing `docs/epics/` folders and their `.github-state.json` keep working. Run `create` once on a folder issue-manager made to turn its children into sub-issues.

---

*Part of the [sdlc plugin](../../README.md)*
