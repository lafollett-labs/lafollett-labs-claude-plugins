# Issue Conventions — Intent Over Implementation

Loaded when writing, validating or reviewing an Epic, Story, Task or Bug. An issue says WHAT the system should do and WHY; the engineer who implements it decides HOW. `bin/validate-story.js` is the source of truth for what a story must contain; the rest of this file is judged by reading.

## Templates

| Type | Template (`bdd` copies it) | Use for |
| - | - | - |
| Epic | `assets/bdd-epic-template.md` | a business goal spanning several stories |
| Story | `assets/bdd-story-template.md` | a capability a user can observe |
| Task | `assets/bdd-task-template.md` | technical work with no user-facing behaviour (What / Why) |
| Bug | `assets/bdd-bug-template.md` | a defect, with steps to reproduce |

## Story layout (validate-story.js)

Acceptance criteria are Markdown, not `.feature` files: each scenario is a `### Scenario:` heading under `## Acceptance Criteria`, with its Given/When/Then lines as plain text below it.

| Check | Fails when | Severity |
| - | - | - |
| Title | no `# ` heading line | error |
| User story | no `## User Story`, or the three lines are not consecutive `As a …` / `I want …` / `So that …` | error |
| Business value | no `## Business Value`, or its first line is under 20 characters | error |
| Acceptance criteria | no `## Acceptance Criteria` | error |
| Scenarios | fewer than two `### Scenario:` headings (happy path plus an error or edge case) | error |
| Given/When/Then | any scenario lacks a `Given`, a `When`, or a `Then` | error |
| Definition of Done | no `## Definition of Done`, or fewer than three `- [ ]` items in the file | error |
| Implementation detail | an HTTP verb + `/api/` path, a `SELECT … FROM`, a database/table/column "should have/contain", or a quoted click/button/element/CSS/XPath target | warning |
| Effort estimate | no `## Effort Estimate` | warning |

The validator counts every line after the last `### Scenario:` toward that scenario, so a `Given` / `When` / `Then` word in a later section can hide a missing step: give each scenario its own Given, When and Then lines.

## Scenario language

Write scenarios in the words the users and the business use, never in implementation terms.

| Use | Avoid |
| - | - |
| member, librarian, book, loan, hold (the domain's own nouns) | entity, record, DTO, repository |
| what the user observes ("the member is told the hold is ready") | how the system stores it (rows, tables, endpoints) |

```gherkin
Given a member has a hold on "The Lighthouse"
When a copy is returned
Then the member is told the hold is ready
```

## Quality checklist

| Applies to | Check |
| - | - |
| all | describes WHAT and WHY, not HOW |
| all | no code snippets or pseudocode |
| all | no file paths, unless an Epic-level architectural constraint |
| all | no library or framework prescriptions; the engineer picks the tools |
| all | domain language, not technical jargon |
| all | acceptance criteria are observable from outside the system |
| Epic | Current State → Target State describes the transformation |
| Epic | business value says who benefits and why |
| Epic | Out of Scope names what is excluded |
| Epic | Story Breakdown lists every child; `### Phase …` subheadings make the order explicit (what runs in parallel, what is sequential) |
| Epic | architecture holds strategic constraints only, each citing the ADR that made it |
| Story | INVEST: Independent, Negotiable, Valuable, Estimable, Small (one cycle), Testable |
| Story, Task | Key Rules are specific and testable ("an empty search shows no results, not an error"), never vague ("should be fast") |
| Story, Task | no hidden coupling: when one story changes another's deliverable, merge them or state the contract between them |
| Story, Task | Technical Notes, if any: at most three hints (a pattern to follow, a gotcha), no libraries, no file paths |
| Bug | steps reproduce it; expected and actual behaviour both stated |

## Anti-patterns (reject)

| Pattern | Why it is wrong |
| - | - |
| "Create a function called …", "add a method that …" | prescribes the implementation |
| "Use the X library to …" (Technical Notes included) | prescribes the tool |
| "In `path/to/file` …", "write to `<dir>/<id>.json`" | prescribes file layout or formats |
| "The database query should …", "add a column called …" | internal detail; a schema decision belongs in an ADR |
| "Should be fast / clean / good" | not measurable |
| a `How:` section | the whole HOW is the engineer's; describe observable behaviour instead |
| a language or platform choice with no ADR cited | a choice must cite the decision that made it |
| "Follow the same architecture as X — a file with Y, tool Z" | prescribes layout; say "follow established conventions (reference: X)" |

## Test Plan harvesting

`create`, `create-standalone` and `update` append a `## Test Plan` from the scenario titles, so a scenario title is also a test-plan line: write it as the behaviour to verify ("Member is told a hold is ready"), not a step. With no `### Scenario:` headings, the unordered (`-` / `*` / `+`) bullets under `## Acceptance Criteria` are used instead; numbered lists are never harvested.
