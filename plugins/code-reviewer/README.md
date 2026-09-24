# code-reviewer

Code reviews that dispatch a principal engineer for the stack you actually
touched, then consolidate what they found. Five PE sub-agents ship with the
plugin; anything they do not cover falls back to a generic three-pass review.

```
/plugin install code-reviewer
```

Needs `gh` on PATH for PR reviews. Nothing else.

## Skills

| Skill | |
| - | - |
| `/code-reviewer:init-project` | scan the repo, write a Stack Map into `CLAUDE.md` — run once per repo |
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
| `pe-vue` | Vue 3 / Nuxt 3 / TypeScript / Tailwind / Storybook |
| `pe-aws-infra` | AWS CDK / Cloudflare CDKTF / Terraform / Docker / GitHub Actions |
| `pe-governance` | agent definitions, skills, `CLAUDE.md`, `AGENTS.md` — markdown whose audience is the model |
| `pe-devtools` | local dev tooling, reviewed on a single-operator threat model |

A diff spanning several stacks dispatches every matching PE in parallel, and
findings are de-duplicated and cross-verified — a handler claiming an env var
the CDK stack never sets gets flagged by the pair, not by either alone.

## Tips

**Run `init-project` before your first review, once.** Without a Stack Map the
reviewer falls back to file-extension matching and generic test commands. It is
a one-time cost that pays for itself immediately.

**`pe-devtools` exists to stop over-hardening.** Point a production-grade
reviewer at a local bash helper and you get a page of multi-tenant attack
findings for a script only you will ever run. This one asks "would this fail in
normal operator use?" instead. Scripts that genuinely *are* CI primitives should
stay with `pe-aws-infra`.

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
