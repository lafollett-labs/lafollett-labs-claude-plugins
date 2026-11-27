# Dexter Horthy (HumanLayer) — Agentic Engineering Workflow

Notes scribed from a 58-minute podcast. Every claim carries a re-openable span.

```
Watch: xgkjtF89-44 00:00-20:00
```

Source: <https://www.youtube.com/watch?v=xgkjtF89-44> — David Ondrej with Dexter
Horthy (HumanLayer), who coined "context engineering".

The primary source is not the video. It is the document he screen-shares
throughout, visible only in the pixels and **named nowhere in the narration**:

| | |
| - | - |
| Repo | `advanced-context-engineering-for-coding-agents` |
| File | `wsff.md` — 707 lines (439 loc), 47.7 KB |
| Author | `dexhorthy` |

`Watch: xgkjtF89-44 00:15:55-00:19:41`

---

## 1. The four stages before the agent writes code

His pipeline, in order. Most people skip stage 3.

```
1. product        what user problem, and how do we measure it
2. architecture   services, endpoints, tables, query outlines
3. program design the SHAPE of code: types, method signatures,
                  program layout, call stacks          <- the skipped one
4. vertical slice build thin end-to-end, not layer by layer
```

`Watch: xgkjtF89-44 00:11:28-00:19:41`

On stage 3, from the document on screen:

> After architecture we do this thing that I think is criminally underemphasized
> in agentic coding: **program design**.

> But what I see working well is that before anyone (human or agent) writes the
> implementation, we go a level down from architecture into the **shape of
> code**: the types, the method signatures, the program layout, and the call
> stacks.

`Watch: xgkjtF89-44 00:16:58`

**Mermaid was tried and rejected for this layer** — a detail that survives only
in the frames:

> The first version of our program design skill sucked. It was hard to read, it
> was exhausting. We tried mermaid, which has its place, but what we **actually
> love** are light visualizations in pseudocode.

`Watch: xgkjtF89-44 00:16:58`

## 2. The three artifacts of program design

All three appear on screen; none is described in the narration.

**Call-stack trees**, in diff syntax so the change is the readable part:

```
entrypoint
  runCommand
+   handleCreateResource
+     ResourceClient.create(input)
+       POST /resources
+     renderResult
-   legacyCreateFlow
```

**Annotated file-tree diffs**:

```
src
└── resource
+   ├── resource-client.ts      # NEW - wraps API contract calls
+   ├── resource-client.test.ts # NEW - covers request/response mapping
~   └── resource-route.ts       # MODIFIED - wires create action into UI
```

**Types and method signatures** — scoped as "the stuff that's too internal for an
architecture doc but that an agent might still get wrong":

```ts
interface Item { id: ItemId; parentId: ItemId | null }
interface Cursor { position: ItemId; direction: 'up' | 'down' }
resolveTarget(items: Item[], cursor: Cursor) -> ItemId | null
```

The justification, and the sharpest line in the whole document:

> None of these take long to produce (the model drafts them, you argue with it),
> and every one of them is a decision you'd otherwise be making implicitly during
> code review — **at the most expensive possible time to change your mind**.

`Watch: xgkjtF89-44 00:17:04-00:19:15`

## 3. Declarative workflows as JSON state machines

A HumanLayer feature shown on screen at `00:14:08`, dropped into
`.humanlayer/workflows/` or `.agents/workflows/`. Steps carry a slash-command
prompt and named exits; exits are what a human picks to route the next step.

```json
{
  "id": "implementation-review",
  "title": "Implementation with Code Review",
  "start": "implementation",
  "steps": {
    "implementation": {
      "prompt": "/rpi:implement-outline",
      "exits": [
        { "title": "Review the code",        "to": "code-review" },
        { "title": "Create a pull request",  "to": "pull-request" }
      ]
    },
    "code-review": {
      "prompt": "/code-review",
      "exits": [
        { "title": "Revise the implementation", "to": "implementation" },
        { "title": "Create a pull request",     "to": "pull-request" }
      ]
    },
    "pull-request": { "prompt": "/rpi:describe-pr" }
  }
}
```

`Watch: xgkjtF89-44 00:14:08`

Their task board uses the same vocabulary as labels — `research`,
`research-questions`, `design-prd`, `design-tdd`, `implementation`,
`describe-pr` — with tasks keyed `[TICKET-123]` and a stage graph running
`design -> outline -> implement -> PR`.

`Watch: xgkjtF89-44 00:13:49`

## 4. Context-light planning is the whole point

Planning sessions stay cheap so decisions are made at maximum model
intelligence. Measured on screen: **43,107 / 353,400 tokens — 12%** of the window,
with architecture already decided.

> The deeper you are in the context window, the [worse it gets].

> Once the model has written thousands of lines of code […] it is harder to
> change, because you're deep in a context window […] and you're already kind of
> biased in one direction by what the model chose in the first place.

`Watch: xgkjtF89-44 00:18:04-00:18:45`

## 5. Vertical slices, not horizontal

Models default to horizontal — all the DB, then all the services, then all the
API, then the frontend — which leaves nothing testable until the end.

> at the end of it you're sitting at like the other side of thousands of lines of
> code and there was nothing to check along the way

`Watch: xgkjtF89-44 00:19:22-00:20:01`

## 6. Why he refuses to stop reading code

He ran a "light software factory" (review plans, not code) in July 2025 and it
failed hard: a desktop-app bug took weeks, users were angry, and the team had to
read months of unfamiliar generated code to find it.

> the odds of this happening to you if you stop reading the code are much higher
> than the odds of it not happening to you

Unshipped prototype worth stealing: **the agent quizzes you** while it works —
multiple-choice on current codebase state and what the new implementation
changes, with mermaid diagrams. Ondrej's framing: have the agent check "is the
human still in charge," and deliberately slow down when you lose the grip.

`Watch: xgkjtF89-44 00:08:37-00:10:56`

## 7. Back-pressure: give the agent a number

> If you can tell it a measurable output, the agent will move mountains for you.

LLM-as-judge is fine, but a real business metric (conversion, latency, resource
reduction) is categorically better. Same shape as auto-research: "make this CUDA
kernel faster until you hit 20% resource reduction."

Also: **write the launch blog post before building the feature** (an Amazon
practice he's adopted), plus plain-HTML mockups of every affected view, all
before a line of code.

`Watch: xgkjtF89-44 00:13:03-00:14:29`

---

## What we could take into this repo

| Idea | Where it lands |
| - | - |
| Program design as a distinct phase — call-stack trees, file-tree diffs, types/signatures before implementation | A `/program-design` skill; also an `issue-manager` story template section |
| Pseudocode over mermaid for plan visualisation | Matches this repo's existing governance rule; his measured rejection of mermaid is direct support |
| Declarative JSON workflow with named exits | `code-reviewer`'s multi-round loop is already a state machine written in prose — this is the schema form of it |
| "Decisions you'd otherwise make implicitly during code review" | The strongest available argument for `code-reviewer`'s Phase 4.5 spec coverage |
| Agent quizzes the human to check comprehension | Nothing here does this yet |
| Context-light planning, measured in tokens | Argues for keeping planning sessions in separate short-lived contexts |

## Note on method

Of the concrete artifacts above — the repo name, `wsff.md`, the call-stack tree,
the file-tree diff, the `Item`/`Cursor` signatures, the workflow JSON, the
`43,107/353,400` token count, the mermaid rejection — **none is spoken in the
narration**. All were read off the frames. The transcript says "call stack" and
"types and method signatures"; the pixels carry the actual syntax.

---

# Part 2 — Why models write slop (20:00–31:35)

`Watch: xgkjtF89-44 00:20:00-00:31:35`

This is the load-bearing argument. Everything in Part 1 is a *consequence* of it.

## The thesis

> if the model knew what good code looked like, then it would be able to write
> it in the first place. We're all using the same freaking models.

`Watch: xgkjtF89-44 00:30:44`

## How a benchmark task is actually graded

From `images/bench-task-wm-shadow.png` in his repo — on screen, never narrated in
this detail:

```
bug report + problem_statement  ─┐
codebase @ base_commit           ├─> agent ─> patch ─> grade in a sandbox ─> 1 or 0
  (snapshot right before          │                     (the agent never sees this)
   the human's fix)              ─┘
```

The grading step, verbatim from the diagram:

```
git checkout HEAD -- spec/        # throw away the agent's test edits
git apply test_patch.diff         # apply the human's test patch on top
bundle exec rspec                 # -> 12 examples, 0 failures

fixed it ✓ + broke nothing ✓  ->  1
anything else                 ->  0
```

`Watch: xgkjtF89-44 00:24:13`

The reward is binary. **Nothing in it measures design.** He walked the actual
dataset on screen — `SWE-bench_Multilingual` on HuggingFace, 300 test rows,
columns `repo / instance_id / base_commit / patch / test_patch` — to show golden
patches are typically 100–200 lines.

`Watch: xgkjtF89-44 00:23:19-00:23:41`

## The oracle argument — the sharpest idea in the video

RL needs an **oracle**: something that verifies a solution fast enough to run
millions of times.

| | Oracle? | Cost function resolves in |
| - | - | - |
| Correctness | tests | seconds |
| Maintainability | **none** | weeks to months |

> maintainability has no fast oracle […] basically the cost function of bad
> architecture is measured in weeks and months.

You cannot back-propagate a cost that only materialises months later. So slop
isn't a model defect to be patched — it is **structurally outside the reward
signal**, and will stay there until someone builds an oracle for it.

`Watch: xgkjtF89-44 00:25:56-00:26:38`

## Benchmarks disclose the whole problem up front

From `images/sota-changes-wm-shadow.png`:

> software is "discovering problems as you go"  →  [ a chain of features ]
>
> But even most modern benchmarks disclose the whole problem up front
>
> **whole problem known up front — no reason to optimize for "is this easy to
> change/adjust later"**

His proposed alternative: a roadmap of ~20 features fed one at a time, none known
in advance. Grade whether the codebase stays *changeable*, not whether one bug
got fixed.

`Watch: xgkjtF89-44 00:26:38-00:27:46`

## Three techniques worth stealing outright

From Cognition's newer benchmark, which he rates "better in the right direction":

1. **Test-validity check** — the genuinely novel one. Remove the model's patch and
   run the model's *own* tests against the pre-patch code. If they don't fail
   there, the model wrote tests that assert nothing.
2. **Functional-equivalence judge** — an LLM compares the model's solution to the
   golden one and asks whether it solved the problem, even if the shape differs
   and the literal tests fail.
3. **Quality judge against explicit rules** — a rules dataset ("in C++ you can
   never log like this, you have to log like this"), and the judge returns a
   thumbs up/down on rule adherence, not a vibe.

`Watch: xgkjtF89-44 00:27:46-00:29:20`

Ondrej's summary, which Dexter endorses:

> you want to extract words from the word taste, which is not helpful, into like
> numbers and tests and, you know, measurements.

## Vertical slices, concretely

His pre-AI habit, given as an explicit build order:

```
mock API endpoint -> stub frontend -> get frontend right
  -> wire it down -> migration -> business logic -> error handling
```

> I have never seen a model do this without human getting in the loop and like
> telling it what order to do the things.

Models go horizontal — all the DB, then all the services, then all the API — so
nothing is testable until the end. His framing: it is how you learn a new
language. Hello World, then mutate it toward the thing you want, checking at each
step, re-steering while it is still cheap.

`Watch: xgkjtF89-44 00:20:01-00:21:46`

## What this changes for this repo

| Insight | Consequence here |
| - | - |
| Maintainability has no fast oracle, so RL cannot reward it | This is the *reason* `code-reviewer` exists. It is a hand-built oracle for the thing training cannot score — worth stating in the plugin's own README as its rationale |
| Test-validity check (revert patch, tests must fail) | A concrete, deterministic, cheap check the PE agents could run on any PR that adds tests. Nothing in the repo does this today |
| Quality judge against an explicit rule list, thumbs up/down | Exactly the shape of the PE protocols — his evidence says keep the rules explicit and the verdict binary, not a vibe score |
| "Extract taste into numbers and tests" | The governance rules in `CLAUDE.md` already are this. His argument is outside support for keeping them mechanical |
| Benchmarks never test "is this easy to change next time" | Argues for `issue-manager` stories carrying a changeability criterion, not just acceptance criteria |
