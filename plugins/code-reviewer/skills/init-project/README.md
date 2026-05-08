# init-project

Initializes the `/code-reviewer` skill in a project by writing a Stack Map into `CLAUDE.md` (or `.code-reviewer.yml`). Detects languages, frameworks, and test commands so the parent reviewer knows which built-in PE sub-agent to dispatch per path.

The five built-in PE sub-agents — `pe-go`, `pe-vue`, `pe-aws-infra`, `pe-governance`, `pe-devtools` — ship with the plugin as proper agents. **This skill does NOT generate per-project PE files.**

## What It Does

1. **Detects stacks** — Go, Vue, React, CDK, Terraform, Rust, Python, Java, C#, Docker, CI/CD
2. **Maps directories** — which paths belong to which stack
3. **Finds test commands** — reads `package.json` scripts, `Makefile` targets, or uses stack defaults
4. **Writes Stack Map to `CLAUDE.md`** — single source of truth for path → stack → PE → test command
5. **Optionally writes `.code-reviewer.yml`** — machine-readable equivalent for the parent skill

## Usage

```text
You: /init-project
Claude: [Scans repo, writes Stack Map to CLAUDE.md, prints summary]
```

## Output

- Stack Map appended to `CLAUDE.md` (or `.code-reviewer.yml` if preferred)
- Summary of detected stacks and which built-in PE will review each (or `Generic` for fallback)

## Supported Stacks

Go, Vue/Nuxt, React, Svelte, Angular, Astro, Next.js, AWS CDK, CDKTF,
Terraform, Rust, Python, Java, C#/.NET, Docker, GitHub Actions, GitLab CI.

Unsupported stacks fall back to generic three-pass review without
stack-specific test commands.

---

*Part of [code-reviewer plugin](../../README.md)*
