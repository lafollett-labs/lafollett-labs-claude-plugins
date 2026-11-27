# TDD and Commits

Loaded by Phase 4 on the Standard path, before the first test is written.

## Contents

- TDD discipline
- Test quality contract
- Code comments
- Commit discipline
- Scope expansion

## TDD discipline

```text
for each behavior in plan:
  red:    write failing test FIRST — never write implementation before this exists
  green:  write minimum code to pass — only after red exists AND is verified failing
  blue:   refactor for clarity without changing behavior
  verify: run test suite after each red/green cycle

NEVER batch tests and implementation in one pass — that defeats the design
  pressure of test-first.
```

## Test quality contract

```text
every test must satisfy:
  proves:    a specific input produces a specific output (or observable side effect)
  isolates:  test asserts on THIS unit's outputs given controlled inputs
             it does NOT assert on what dependencies receive, store, or compute internally
             (e.g., assert on what the service returns when the repository returns a known
              value — NOT on the SQL the repository emitted)
  survives:  if implementation is swapped (different code, same behavior) → still passes
             if behavior breaks → fails

write tests for:
  - observable outcomes from the consumer's perspective
  - error conditions and boundary cases
  - contracts between components (what goes in, what comes out)
  - story acceptance criteria — each AC should map to one or more tests

do NOT write tests for:
  - private methods or internal data structures
  - implementation details that could change without affecting behavior
  - third-party libraries or frameworks already tested upstream
  - lower-level library code that is tested at its own layer
  - "constructor sets the property" / "getter returns the value" style busywork
  - behavior already proven by a test elsewhere — do not duplicate coverage

self-check before writing each test:
  state the input → expected output contract in ONE sentence
  if unable:
    the test is probably busywork — STOP and reconsider what behavior to prove
  if the sentence describes internal mechanics instead of consumer-visible behavior:
    rewrite the test to exercise the contract from the outside

unit vs integration boundary:
  unit test:        isolates the unit; controls dependency inputs; asserts only on
                    THIS unit's outputs (per the `isolates` contract above)
  integration test: deliberately exercises real dependencies across a boundary;
                    asserts on the consumer-visible outcome of the full path
  pick the lowest layer that proves the behavior — do NOT write an integration
    test when a unit test would prove the same contract
```

## Code comments

Express intent in code first: names, small functions, and tests carry the why. In the blue step, prefer extracting a well-named method over explaining a block. Write a comment only for a non-obvious constraint the code cannot show (an external-bug workaround, a framework gotcha, a surprising invariant), and keep it to one line. Keep ticket keys, change narration, and "guarded by <test>" pointers out of code comments; the commit, PR, and `git blame` carry that history.

## Commit discipline

```text
commit message subject: "<type>[(scope)][!]: <description>"   # Conventional Commits; the ticket key is not required

examples (the key lives in the branch: feat/42-add-title-search for #42, feat/LT-02-add-title-search for LT-02):
  feat(search): add search by title
  test(search): cover title search with no matches
  refactor(search): extract the title query builder

before each commit, check the subject:
  r = node "${CLAUDE_PLUGIN_ROOT}/bin/git-conventions.js" commits <<'SUBJECT'
  {subject}
  SUBJECT
  if not r.ok: reword the subject per r.offenders[0].error; never commit an offender

commit message body (when the commit implements one or more ticket ACs):
  add a footer line listing the AC indices implemented by this commit:
    "AC: 1, 3"
  bare numbers: "#1" in a commit message links issue #1 on GitHub
  AC indices match those in the Phase 3 AC → behavior map; downstream AC
  coverage tracking parses these footers.

PR title composition is owned by `sdlc:pull-request` — /implement does NOT
  constrain the first commit's wording.
```

## Scope expansion

```text
expansion check compares CURRENT work against session.ticket_acs (the original
ticket ACs from Phase 1), NOT just the approved plan — silent growth across
plan revisions is caught here.

if implementation requires work outside the ticket ACs:
  🛑 Hard stop — scope expansion detected
  surface the growth to the user in the question context:
    - the ticket ACs (session.ticket_acs)
    - what the approved plan covered
    - what the work now requires (in plain English)
  AskUserQuestion → "Work exceeds the ticket ACs — how to proceed?"; options:
    (a) "Approve expansion — re-plan to include it"
    (b) "Re-plan — rescope the approach"
    (c) "Defer — open a follow-up issue for the extra work (sdlc:plan create-standalone)"
  do NOT silently expand
```
