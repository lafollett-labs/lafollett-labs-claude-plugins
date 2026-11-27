# issue-manager

> **Deprecated: use `sdlc:plan`** (`/plugin install sdlc`). It covers everything here,
> links stories to their epic as GitHub sub-issues, and keeps your existing
> `docs/epics/` folders and `.github-state.json` working.
>
> | issue-manager | sdlc:plan |
> | - | - |
> | `init --name "X"` | `/sdlc:plan init --name "X"` |
> | `create --docs-path <dir>` | `/sdlc:plan create --docs-path <dir>` (children become sub-issues) |
> | `update --docs-path <dir>` | `/sdlc:plan update --docs-path <dir>` |
> | `import --epic <N>` | `/sdlc:plan import --epic <N>` |
> | `status --docs-path <dir>` | `/sdlc:plan status --docs-path <dir>` |
> | quality checklist review | `/sdlc:plan validate --file <f>` or `--issue <N>` |
> | ADR → epic | `/sdlc:plan init --name "X" --from <adr>` |
>
> Run `create` once on a folder issue-manager made to turn its children into sub-issues.

Create and manage GitHub Issues that define **what** and **why**, never **how**.
Author locally in markdown, push to GitHub, edit and push again without creating
duplicates.

```
/plugin install issue-manager
```

Needs `gh` authenticated and `node` on PATH.

## Skills

| Skill | |
| - | - |
| `/issue-manager:issue-manager` | create, import, update, and quality-check issues |

## Usage

```text
You: /issue-manager:issue-manager
You: create an epic for the billing migration with stories
You: import epic 582 so we can rework it
You: are these issues too implementation-heavy?
You: turn ADR-0007 into an epic
```

Everything lands in your repo, not the plugin directory:

```
docs/epics/004-slack-integration/
  00-Epic-Slack-Integration.md
  01-Story-Post-Digest-To-Channel.md
  02-Task-Rotate-Bot-Token.md
  .github-state.json           # filename -> issue number
```

### The two flows

**New work** — scaffold, write, push:

```
init --name "Slack Integration"        # creates the epic folder
                                        # you edit the markdown
create --docs-path docs/epics/004-...  # creates Issues, links children to the Epic
```

**Existing work** — pull down, rework, push back:

```
import --epic 582                      # Epic + children into local markdown
                                        # you rework it
update --docs-path docs/epics/582-...  # pushes edits by mapped issue number
status --docs-path docs/epics/582-...  # local vs GitHub sync state
```

## Tips

**The templates are the point.** Epic, Story, Task and Bug each carry a
quality gate: acceptance criteria must be observable outcomes, stories must be
INVEST, and code snippets, file paths, and library choices do not belong in an
issue unless they are an Epic-level architectural constraint.

**"The system should…" not "add a method that…".** The implementing engineer
decides the approach. An issue that specifies the implementation has pre-made a
decision the person with the most context has not made yet.

**`create` is idempotent.** It skips anything `.github-state.json` already maps,
so a partially-failed run is safe to re-run. Use `update` — not `create` — once
issues exist.

**Import before reworking anything already on GitHub.** Editing in the web UI
loses the local markdown as the source of truth, and the next `update` will
fight you.

**It stops after creating the Epic.** No branches, no implementation. Dispatching
the work is a separate decision from describing it.

**Epic folders are ordinal-prefixed** (`004-slack-integration`) and files are
`##-Type-Title.md` with `00` reserved for the Epic. The script reads that
convention — renaming files by hand breaks the mapping.
