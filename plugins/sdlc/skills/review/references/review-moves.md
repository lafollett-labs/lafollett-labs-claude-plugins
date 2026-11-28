# Review Moves

Loaded by SKILL.md at Phase 3 and inlined into every PE dispatch beside the PE PROTOCOL. Seven moves, applied by every PE after its five passes. A **unit** is anything the diff adds or changes in the PE's files: a function, branch, rule, config key, schema field, doc claim, test or guard. Apply each move whose trigger matches a unit, starting from the agent's stack heuristics. Moves decide where to look; the PE PROTOCOL's Calibration Anchor, REPORTING BAR and Severity Definitions still decide whether and how hard to flag.

## Contents

- Procedures
- Output

| Move | Trigger — a unit that is or contains | Catches |
| - | - | - |
| M1 Ripple | a contract, value, name, rule or fact, or a fix | contract drift, stale docs, incomplete fixes |
| M2 Lifecycle | state, I/O, retries, async work, or a multi-step flow | lost, stale or doubled state; races |
| M3 Inputs | a branch, parser, loop, limit or aggregate | edge inputs, boundaries |
| M4 Attack the guard | a check, validator, filter, allow/deny list, regex, glob, permission, redaction or reviewer rule | overbroad and bypassable guards |
| M5 Failure path | a call that can fail | swallowed or misread errors |
| M6 Falsify the test | an added or changed test | tests that cannot fail |
| M7 Fact check | a claim about a platform, library, spec, maths, tool or worked number, or about what code does (comments, names, messages, docs) | false facts |

## Procedures

```text
M1 Ripple:
  for each unit:
    list its producers, consumers, restatements (docs, comments, schemas, examples, error messages,
      allowed-value lists, tests, routing tables) and siblings that do the same job
    grep each by name and by literal value; each must agree with the unit under every mode,
      scope and config variant the contract defines
    diff each sibling against the canonical one; a guard, step or transform it lacks is a finding
  for each hard rule in the repo's instruction files and CONTRIBUTING:
    apply it literally to every touched path; an exception the rule does not state is a violation
  if the unit is a fix:
    grep for every other instance of the pattern it fixes; each unfixed instance is a finding, in_scope: true

M2 Lifecycle:
  for each piece of state the unit reads or writes:
    trace it through every entry point, early return, retry, restart, reset, scope change, rollback,
      interruption, partial failure, and both deploy orders (old code + new data, new code + old data)
    list what is lost, left stale, never cleared, applied twice, or keyed by an identity that can recur
  for each gap between a check and its use, including across blocking I/O and awaits:
    interleave a second actor (concurrent request, second tab, retry, cancel, timeout, next turn) in both orders
  if the unit replaces a library or framework mechanism:
    list the behaviours it provided implicitly (reuse, ownership, cleanup, retries); confirm each survives

M3 Inputs:
  for each branch, parser, loop or aggregate, drive it with:
    empty, null or missing, zero, one, many, duplicate, malformed, wrong type (every falsey value,
    a string where a map is expected), unusual-but-legal shapes, combinations of flags rather than
    each alone, at the limit, limit + 1, the last element, the first item past an early exit
  for each switch over a producer's values: cover every value the producer can emit; the default arm fails closed
  for each identifier: place it in every sink it reaches (URL path, filename, shell, regex, SQL);
    check that sink's reserved characters
  for each walk or dispatcher: every entry type it can meet is handled or refused, never skipped
  for each numeric limit: compute the worst case against it; push each numeric field past its type's range

M4 Attack the guard:
  for each guard, including one a fix just added:
    construct a valid input it rejects AND an invalid input it accepts (alternate spelling, case, syntax,
      encoding, nesting, placement, source); run the guard on both, never assert coverage
    canonicalise each input exactly as the sink will (path resolution, symlinks, globs, URL decoding,
      Unicode, the downstream interpreter's full grammar) before checking
    check that it covers the root of a walk as well as each entry, the final state after every copy,
      merge or patch, both directions of a containment test, and every branch past each early return
    read its literal scope, not its intent: what else the predicate matches, and whether a waiver
      relaxes only what it names
    for a permission: expand wildcards and inherited grants to the concrete resources and jobs they reach
    for a redaction or sanitisation contract: enumerate every sink that writes or emits the data

M5 Failure path:
  for each call that can fail (I/O, network, subprocess, parse, auth, quota):
    fail it each way: error, timeout, empty, malformed, partial, non-zero exit beside a stale output
    state what the caller and the user then see: status, headers, exit code, message, retry, cleanup
    a failure swallowed, read as success or as a different outcome, consuming stale or partial output,
      or leaking a resource is a finding

M6 Falsify the test:
  for each added or changed test:
    name the defect that would make it fail; invert, remove or bypass the behaviour under test
    if it still passes (it matches a generic token, keys on a prefix, accepts any error): finding
    check that its fixtures produce the condition its name claims (clocks, IDs, cache state)
  for each new guard or error path: re-check existing tests that accept any error

M7 Fact check:
  for each claim:
    verify it against the primary source (official docs, spec, source, --help) or run it in the target environment
    recompute every worked number
    read each comment, name, message and summary sentence as a literal claim; check it against the code,
      config or test it describes, under every mode it covers
    if unverifiable: a verification_receipts[] entry with claim: indeterminate, never a finding
```

## Output

Each finding carries `move:`, and the YAML block carries `moves_coverage`:

```yaml
findings:
  - id: "HIGH-001"
    move: M4                 # M1..M7 whose trigger the finding falls under, or none
    # ...the finding keys in the PE PROTOCOL's Output Format
moves_coverage:              # M1..M7, each exactly once
  - move: M1
    status: applied          # applied | n/a
    checked: "2 changed contracts → 9 consumers, 3 doc restatements; 1 fix → 4 sibling sites grepped"
    note: ""
  - move: M6
    status: n/a
    checked: ""
    note: "no test added or changed"
  # ...M2–M5 and M7, one entry each
```

`checked` names what was examined, with a count; it is required when `status: applied`, and a copied example or a `<...>` placeholder does not count. `note` says why no unit triggered the move; it is required when `status: n/a`. `findings.js validate` re-dispatches a PE once whose `moves_coverage` is missing, short of a move, or has an entry without its `checked` or `note`; a gap left after that is recorded in the review.
