# code-reviewer

Code reviews that dispatch a principal engineer for the stack you actually
touched, then consolidate what they found. Seven PE sub-agents ship with the
plugin; anything they do not cover falls back to a generic review.
Every PE and the generic review apply the same seven **review moves**, and each
reports what it checked for every move.

```
/plugin install code-reviewer
```

Needs `gh` on PATH for PR reviews. Branch reviews, including story coverage
against local `docs/epics/` stories, work without it.

## Skills

| Skill | |
| - | - |
| `/code-reviewer:init-project` | scan the repo, write a Stack Map into `AGENTS.md` or `CLAUDE.md` — run once per repo |
| `/code-reviewer:code-reviewer` | run the review |

## Usage

Bootstrap the repo first. The Stack Map is what tells the reviewer which paths
belong to which stack, and which test commands to run:

```text
You: /code-reviewer:init-project
```

Then review whatever you have:

```text
You: review my branch                 → git diff main...HEAD
You: review PR #17                    → checks out the source branch, diffs against target
You: review staged changes            → git diff --cached
You: review src/services/             → whole files, no diff context
You: /code-reviewer:code-reviewer     → asks what to review
```

Reports land in `./docs/code-reviews/<name>-code-review.md` and are committed to
the working branch — never to `main`.

## The PE sub-agents

| Agent | Domain |
| - | - |
| `pe-go` | Go / PostgreSQL / AWS Lambda |
| `pe-vue` | Vue 3 on Nuxt 3 or a Vite SPA/PWA / TypeScript / Tailwind / Storybook — service workers, offline, storage durability, WASM consumption |
| `pe-rust` | Rust workspaces / unsafe + FFI / WebAssembly via wasm-bindgen |
| `pe-aws-infra` | AWS CDK / Cloudflare CDKTF / Terraform / Docker / GitHub Actions |
| `pe-governance` | agent definitions, skills, `CLAUDE.md`, `AGENTS.md` — markdown whose audience is the model |
| `pe-devtools` | local dev tooling, reviewed on a single-operator threat model |
| `pe-audio` | real-time audio and DSP — a *domain* PE dispatched beside `pe-rust` or `pe-vue` on audio paths |

A diff spanning several stacks dispatches every matching PE (suite-running PEs
at most `max_parallel_pes` at a time, default 2), and
findings are de-duplicated and cross-verified — a handler claiming an env var
the CDK stack never sets gets flagged by the pair, not by either alone, and a
Rust export whose TypeScript call site still passes a `number` where it now
takes a `bigint` gets flagged by `pe-rust` and `pe-vue` together.

## Tips

**Run `init-project` before your first review, once.** Without a Stack Map the
reviewer falls back to file-extension matching and generic test commands. It is
a one-time cost that pays for itself immediately.

**`pe-devtools` exists to stop over-hardening.** Point a production-grade
reviewer at a local bash helper and you get a page of multi-tenant attack
findings for a script only you will ever run. This one asks "would this fail in
normal operator use?" instead. Scripts that genuinely *are* CI primitives should
stay with `pe-aws-infra`.

**`pe-audio` rides along; it does not replace.** It runs on files under
`audio/`, `dsp/`, `pitch/` or named `*worklet*`, plus any path a Stack Map row
assigns to `pe-audio`. The Rust or Vue PE still reviews the same files and runs
the tests; `pe-audio` runs none, so it costs no test budget.

**Spec coverage follows any linked issue with acceptance criteria**, not only
stories. A task or bug links when it carries an `Acceptance Criteria` checklist.

**Story coverage works without GitHub.** Name the branch after a local story
code (`feat/LT-02-live-tuner`) whose file under `docs/epics/` carries a
`**Code:** LT-02` line, and the review checks every acceptance criterion. With
no PR, put the `- [x] AC-N — … — evidence: …` checklist in a commit message
under an `Acceptance Criteria:` line.

**Every review shows its work.** Each PE applies seven language-agnostic moves:
ripple a change to every consumer, sibling and restatement; trace state through
the lifecycle; drive edge inputs; attack every guard; fail every dependency;
falsify every test; fact-check every claim. The report's Moves Coverage table
records what each PE checked per move. A PE that returns no coverage counts as
missing, so the review cannot be approved. Files no PE fits, such as docs, specs
or backend code under a frontend PE's paths, get the moves from the generic
review.

**Fix the rule, not the line.** Every finding lists its siblings: the other
places that state the same rule or repeat the same defect. A round that requests changes prints a
pre-flight. Fix each blocking finding and its siblings, re-check every rule your
fix touched, commit, and pass one `RIPPLE RECEIPTS` line per rule
(`<rule> → N restatements checked @ <sha>`) with the next `/code-reviewer` run. From round 2, each finding says
which earlier fix caused it, and the report's fix cascade shows whether the
rounds are converging or churning.

**CRITICAL / HIGH / MEDIUM block. LOW and INFO are awareness only** — they do
not gate the merge, so do not treat a clean-except-LOW report as blocked.

**Re-reviewing the same SHA is refused.** A round with no new commits adds no
signal. Push the fixes first, then run round 2 — findings append to the existing
file with a new round header rather than overwriting it.

**Three rounds is the cap.** If it is still blocked at round 3, the change wants
a conversation, not a fourth review.

**Run it yourself on delegated work.** The value is centralized review — every
change through one gate — not each author reviewing their own branch.

## Deeper

- [Review engine: scope discipline, verdict logic, PR flow](./skills/code-reviewer/README.md)
- [Stack Map bootstrapper](./skills/init-project/README.md)
